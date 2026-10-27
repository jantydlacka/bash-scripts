#!/bin/bash
set -euo pipefail

# --- jt-system-disk-cleanup.sh ----------------------------------------------
# Analýza a bezpečný úklid místa na disku.
# Použití:
#   jt-system-disk-cleanup.sh [--dry-run|-n] [--docker-volumes] [--help|-h]
#     --dry-run / -n     jen ukáže, co by se uklidilo, nic nemaže
#     --docker-volumes   uvolní i nepoužívané Docker volumes (POZOR: může
#                        smazat data – necháno mimo výchozí úklid)
# ----------------------------------------------------------------------------

DRY_RUN=0
DOCKER_VOLUMES=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --docker-volumes) DOCKER_VOLUMES=1 ;;
        -h|--help)
            # Vypíše jen hlavičku mezi prvními dvěma řádky "# ---"
            awk '/^# ---/ { if (++n == 2) exit; next } n == 1 { sub(/^# ?/, ""); print }' "$0"
            exit 0 ;;
        *) echo "Neznámý přepínač: $arg" >&2; exit 1 ;;
    esac
done

# Volné místo na souborovém systému cesty; neexistující cesta se měří
# na nejbližším existujícím nadřazeném adresáři
avail_kb() {
    local path="${1:-/}"
    while [[ ! -e "$path" ]]; do path=$(dirname "$path"); done
    df --output=avail "$path" | tail -n1 | tr -d ' '
}
# Velikost journalu se záporným znaménkem, aby šla měřit jako "volné místo"
# (bez Storage=persistent leží v /run/log/journal na tmpfs, ne ve /var/log)
journal_free_kb() {
    local kb
    kb=$({ sudo du -sck /var/log/journal /run/log/journal 2>/dev/null || true; } | tail -n1 | cut -f1)
    echo $(( -${kb:-0} ))
}
delta_kb() { local d=$(( $2 - $1 )); echo $(( d < 0 ? 0 : d )); }
# "--" kvůli záporným hodnotám, které by numfmt jinak četl jako přepínač
human()    { numfmt --to=iec --suffix=B -- $(( ${1:-0} * 1024 )) 2>/dev/null || echo "${1:-0} KB"; }
# Hlavička df je lokalizovaná, proto se nefiltruje podle textu
show_df()  { df -h | awk 'NR == 1 || /\/dev\//'; }

# Pole pro souhrn po sekcích: "Sekce|uvolněno_KB"
declare -a SUMMARY=()

# Spustí příkaz, nebo ho v dry-run jen vypíše. Uvolněné místo je rozdíl hodnoty
# "$measure $target" před a po (avail_kb + cesta, nebo journal_free_kb).
run_section() {
    local label="$1" measure="$2" target="$3"; shift 3
    echo "------------------------------------------------"
    echo "### ${label} ###"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] provedlo by se:"
        printf '   %s\n' "$*"
        return 0
    fi
    local before after freed
    before=$("$measure" "$target")
    "$@" || true
    after=$("$measure" "$target")
    freed=$(delta_kb "$before" "$after")
    SUMMARY+=("${label}|${freed}")
    echo "   → uvolněno: $(human "$freed")"
}

echo "--- 🗑️  Analýza a čištění diskového prostoru ---"
[[ $DRY_RUN -eq 1 ]] && echo "    (DRY-RUN: nic se nemaže)"

# Předem si vyžádáme sudo, ať heslo nepadne uprostřed běhu (dry-run ho nechce)
if [[ $DRY_RUN -eq 0 ]]; then sudo -v; fi

total_before=$(avail_kb)

# --- Analýza: kde se místo bere -------------------------------------------
echo "### Využití disku: ###"
show_df

echo "------------------------------------------------"
echo "### 5 největších adresářů v /var: ###"
du_cmd=(sudo du)
if [[ $DRY_RUN -eq 1 ]] && ! sudo -n true 2>/dev/null; then
    du_cmd=(du)
    echo "   (bez sudo – nečitelné adresáře nezapočteny)"
fi
{ "${du_cmd[@]}" -sh /var/* 2>/dev/null | sort -rh | head -n 5; } || true

echo "------------------------------------------------"
echo "### 5 největších adresářů v \$HOME (často skutečný viník): ###"
{ du -xh --max-depth=1 "$HOME" 2>/dev/null | awk -F'\t' -v home="$HOME" '$2 != home' \
    | sort -rh | head -n 5; } || true

# --- Čištění ---------------------------------------------------------------

# APT: zastaralé .deb + osiřelé závislosti a staré kernely (největší výhra)
if [[ $DRY_RUN -eq 1 ]]; then
    echo "------------------------------------------------"
    echo "### APT autoclean + autoremove ###"
    echo "[dry-run] autoremove by odstranil:"
    { apt-get -s autoremove --purge 2>/dev/null || true; } \
        | awk '/^Purg /{ print "   " $2; n++ } END { if (!n) print "   nic" }'
else
    run_section "APT autoclean + autoremove" avail_kb / \
        bash -c "sudo apt-get autoclean -y && sudo apt-get autoremove -y --purge"
fi

# Cache miniatur
run_section "Cache miniatur (~/.cache/thumbnails)" avail_kb "$HOME/.cache/thumbnails" \
    bash -c "rm -rf ~/.cache/thumbnails/* 2>/dev/null || true"

# Dočasné soubory nepoužité 3 dny (mtime i atime, v minutách – "-mtime +3" by
# znamenalo až 4 celé dny). Vynechává skryté položky v kořeni /tmp (zámky
# X serveru, .ICE-unix…) a privátní /tmp služeb a snapů.
TMP_AGE_MIN=$(( 3 * 24 * 60 ))
TMP_FIND=(/tmp -xdev -type f -mmin +"$TMP_AGE_MIN" -amin +"$TMP_AGE_MIN"
          ! -path '/tmp/.*' ! -path '/tmp/systemd-private-*' ! -path '/tmp/snap-private-tmp/*')
clean_tmp() { sudo find "${TMP_FIND[@]}" -delete 2>/dev/null || true; }
if [[ $DRY_RUN -eq 1 ]]; then
    echo "------------------------------------------------"
    echo "### Dočasné soubory v /tmp starší 3 dny ###"
    read -r tmp_count tmp_kb < <({ find "${TMP_FIND[@]}" -printf '%s\n' 2>/dev/null || true; } \
        | awk '{ n++; s += $1 } END { printf "%d %d\n", n, s / 1024 }')
    echo "[dry-run] smazalo by se ${tmp_count} souborů, $(human "$tmp_kb")" \
         "(bez sudo – nečitelné adresáře nezapočteny)"
else
    run_section "Dočasné soubory v /tmp starší 3 dny" avail_kb /tmp clean_tmp
fi

# systemd journal — necháme posledních 7 dní
if command -v journalctl >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "------------------------------------------------"
        echo "### systemd journal ###"
        echo -n "[dry-run] aktuální velikost journalu: "
        journalctl --disk-usage 2>/dev/null || echo "?"
    else
        run_section "systemd journal (ponechat 7 dní)" journal_free_kb "" \
            bash -c "sudo journalctl --vacuum-time=7d"
    fi
fi

# Docker — bývá to klidně desítky GB
docker_section() {
    echo "------------------------------------------------"
    echo "### Docker ###"
    # sudo jen při odmítnutém přístupu k socketu, a to na tentýž endpoint (-H):
    # sudo zahodí DOCKER_HOST/kontext a mířil by na jiného démona.
    # Timeout kvůli zaseklému démonu.
    local docker_cmd=(docker) probe rc=0 endpoint
    probe=$(timeout 10 docker version 2>&1 >/dev/null) || rc=$?
    if (( rc == 124 )); then
        echo "   ⚠️  docker neodpovídá do 10 s – sekce přeskočena"
        return 0
    elif (( rc != 0 )); then
        endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
        if ! grep -qi 'permission denied' <<< "$probe" || [[ -z "$endpoint" ]]; then
            echo "   ⚠️  docker není dostupný – sekce přeskočena:"
            sed 's/^/   /' <<< "$probe"
            return 0
        fi
        docker_cmd=(sudo docker -H "$endpoint")
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "   (bez sudo odmítnut přístup k ${endpoint}, ostrý běh použije sudo – v dry-run se o heslo neříká)"
        elif ! timeout 10 "${docker_cmd[@]}" version >/dev/null 2>&1; then
            echo "   ⚠️  ${docker_cmd[*]} neodpovídá do 10 s – sekce přeskočena"
            return 0
        fi
    fi
    if [[ $DRY_RUN -eq 0 || ${docker_cmd[0]} == docker ]]; then
        "${docker_cmd[@]}" system df || echo "   (docker system df selhal)"
    fi

    # Bez --docker-volumes se volumes záměrně NEMAŽOU (mohou držet data DB/apps)
    local prune_args=(-f)
    if [[ $DOCKER_VOLUMES -eq 1 ]]; then
        prune_args+=(--volumes)
        echo "   ⚠️  --docker-volumes aktivní: uvolní i nepoužívané volumes (může smazat data)"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "   [dry-run] provedlo by se: ${docker_cmd[*]} system prune ${prune_args[*]}"
        return 0
    fi
    local prune_out reclaimed
    if ! prune_out=$("${docker_cmd[@]}" system prune "${prune_args[@]}" 2>&1); then
        echo "   ⚠️  docker system prune selhal:"
        sed 's/^/   /' <<< "$prune_out"
        return 0
    fi
    # Docker vypisuje "Total reclaimed space" vždy, i s 0B
    reclaimed=$(grep -i "Total reclaimed" <<< "$prune_out" || true)
    if [[ -z "$reclaimed" || "$reclaimed" =~ [[:space:]]0B$ ]]; then
        echo "   → nic k uvolnění"
    else
        echo "   $reclaimed"
        SUMMARY+=("Docker prune|-1")  # -1 = viz výpis docker
    fi
}
if command -v docker >/dev/null 2>&1; then docker_section; fi

# Snap — staré (disabled) revize, drží 2–3 kopie každého balíku
if command -v snap >/dev/null 2>&1; then
    old_snaps=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}')
    echo "------------------------------------------------"
    echo "### Snap (staré revize) ###"
    if [[ -z "$old_snaps" ]]; then
        echo "   žádné staré revize"
    elif [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] odstranilo by se:"
        echo "$old_snaps" | sed 's/^/   /'
    else
        before=$(avail_kb /var/lib/snapd)
        while read -r name rev; do
            if [[ -n "$name" ]]; then
                sudo snap remove "$name" --revision="$rev" || true
            fi
        done <<< "$old_snaps"
        after=$(avail_kb /var/lib/snapd)
        SUMMARY+=("Snap staré revize|$(delta_kb "$before" "$after")")
    fi
fi

# --- Souhrn ----------------------------------------------------------------
echo "================================================"
echo "### Využití disku (po): ###"
show_df

if [[ $DRY_RUN -eq 0 ]]; then
    echo "------------------------------------------------"
    echo "### Uvolněno po sekcích: ###"
    for row in "${SUMMARY[@]}"; do
        label="${row%|*}"; kb="${row#*|}"
        if [[ "$kb" == "-1" ]]; then
            printf '   %-38s %s\n' "$label" "viz výpis Dockeru výše"
        else
            printf '   %-38s %s\n' "$label" "$(human "$kb")"
        fi
    done
    total_after=$(avail_kb)
    echo "------------------------------------------------"
    echo "✅ Hotovo. Celkem uvolněno na / přibližně $(human "$(delta_kb "$total_before" "$total_after")")."
else
    echo "------------------------------------------------"
    echo "✅ Dry-run dokončen. Spusť bez --dry-run pro reálný úklid."
fi
