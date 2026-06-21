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
            grep -E '^#( |--)' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Neznámý přepínač: $arg" >&2; exit 1 ;;
    esac
done

avail_kb() { df --output=avail / | tail -n1 | tr -d ' '; }
human()    { numfmt --to=iec --suffix=B $(( ${1:-0} * 1024 )) 2>/dev/null || echo "${1:-0} KB"; }

# Pole pro souhrn po sekcích: "Sekce|uvolněno_KB"
declare -a SUMMARY=()

# Spustí příkaz, nebo ho v dry-run jen vypíše. Vrátí uvolněné místo na / do
# globální proměnné FREED_KB (v reálném běhu měřeno přes rozdíl df).
run_section() {
    local label="$1"; shift
    echo "------------------------------------------------"
    echo "### ${label} ###"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] provedlo by se:"
        printf '   %s\n' "$*"
        FREED_KB=0
        return 0
    fi
    local before after
    before=$(avail_kb)
    "$@" || true
    after=$(avail_kb)
    FREED_KB=$(( after - before )); (( FREED_KB < 0 )) && FREED_KB=0
    SUMMARY+=("${label}|${FREED_KB}")
    echo "   → uvolněno: $(human "$FREED_KB")"
}

echo "--- 🗑️  Analýza a čištění diskového prostoru ---"
[[ $DRY_RUN -eq 1 ]] && echo "    (DRY-RUN: nic se nemaže)"

# Předem si vyžádáme sudo, ať heslo nepadne uprostřed běhu
if [[ $DRY_RUN -eq 0 ]]; then sudo -v; fi

total_before=$(avail_kb)

# --- Analýza: kde se místo bere -------------------------------------------
echo "### Využití disku: ###"
df -h | grep -E '^Filesystem|/dev/'

echo "------------------------------------------------"
echo "### 5 největších adresářů v /var: ###"
{ sudo du -sch /var/* 2>/dev/null | sort -rh | head -n 5; } || true

echo "------------------------------------------------"
echo "### 5 největších adresářů v \$HOME (často skutečný viník): ###"
{ du -xh "$HOME" 2>/dev/null | sort -rh | head -n 5; } || true

# --- Čištění ---------------------------------------------------------------

# APT: zastaralé .deb + osiřelé závislosti a staré kernely (největší výhra)
run_section "APT autoclean + autoremove" \
    bash -c "sudo apt-get autoclean -y && sudo apt-get autoremove -y --purge"

# Cache miniatur
run_section "Cache miniatur (~/.cache/thumbnails)" \
    bash -c "rm -rf ~/.cache/thumbnails/* 2>/dev/null || true"

# Dočasné soubory starší než 3 dny (mtime spolehlivější než atime)
run_section "Dočasné soubory v /tmp starší 3 dny" \
    bash -c "sudo find /tmp -type f -mtime +3 -delete 2>/dev/null || true"

# systemd journal — necháme posledních 7 dní
if command -v journalctl >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "------------------------------------------------"
        echo "### systemd journal ###"
        echo -n "[dry-run] aktuální velikost journalu: "
        journalctl --disk-usage 2>/dev/null || echo "?"
    else
        run_section "systemd journal (ponechat 7 dní)" \
            bash -c "sudo journalctl --vacuum-time=7d"
    fi
fi

# Docker — bývá to klidně desítky GB
if command -v docker >/dev/null 2>&1; then
    echo "------------------------------------------------"
    echo "### Docker ###"
    docker system df 2>/dev/null || echo "   (docker démon neběží?)"

    # Bez --docker-volumes se volumes záměrně NEMAŽOU (mohou držet data DB/apps)
    prune_args="-f"
    [[ $DOCKER_VOLUMES -eq 1 ]] && prune_args="-f --volumes"

    if [[ $DOCKER_VOLUMES -eq 1 ]]; then
        echo "   ⚠️  --docker-volumes aktivní: uvolní i nepoužívané volumes (může smazat data)"
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        reclaimed=$(docker system prune $prune_args 2>/dev/null | grep -i "Total reclaimed" || true)
        echo "   ${reclaimed:-→ nic k uvolnění}"
        [[ -n "$reclaimed" ]] && SUMMARY+=("Docker prune|-1")  # -1 = viz výpis docker
    else
        echo "   [dry-run] provedlo by se: docker system prune $prune_args"
    fi
fi

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
        before=$(avail_kb)
        while read -r name rev; do
            [[ -n "$name" ]] && sudo snap remove "$name" --revision="$rev" || true
        done <<< "$old_snaps"
        after=$(avail_kb)
        SUMMARY+=("Snap staré revize|$(( after - before ))")
    fi
fi

# --- Souhrn ----------------------------------------------------------------
echo "================================================"
echo "### Využití disku (po): ###"
df -h | grep -E '^Filesystem|/dev/'

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
    echo "✅ Hotovo. Celkem uvolněno na / přibližně $(human $(( total_after - total_before )))."
else
    echo "------------------------------------------------"
    echo "✅ Dry-run dokončen. Spusť bez --dry-run pro reálný úklid."
fi
