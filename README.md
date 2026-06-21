# bash-scripts

Kolekce pomocných Bash skriptů pro správu Linux systému.

## `jt-system-disk-cleanup.sh`

Analýza a **bezpečný úklid místa na disku**. Nejdřív ukáže, kde se místo bere,
pak postupně uvolní cache a dočasné soubory a na konci vypíše, kolik se uvolnilo.

### Co dělá

- **Analýza** — využití disků (`df`), 5 největších adresářů ve `/var` a ve `$HOME`
- **APT** — `apt-get autoclean` + `autoremove --purge` (zastaralé balíčky, osiřelé
  závislosti, staré kernely)
- **Cache miniatur** — `~/.cache/thumbnails`
- **Dočasné soubory** — soubory ve `/tmp` starší 3 dny (podle `mtime`)
- **systemd journal** — `journalctl --vacuum-time=7d` (ponechá posledních 7 dní)
- **Docker** — `docker system prune` (nepoužívané images, kontejnery, build cache)
- **Snap** — odstranění starých (disabled) revizí
- **Souhrn** — kolik místa se uvolnilo po jednotlivých sekcích i celkem

### Použití

```bash
./jt-system-disk-cleanup.sh                       # ostrý úklid (Docker volumes ponechá)
./jt-system-disk-cleanup.sh --dry-run             # náhled, nic nemaže
./jt-system-disk-cleanup.sh --docker-volumes      # úklid včetně nepoužívaných Docker volumes
./jt-system-disk-cleanup.sh --dry-run --docker-volumes
./jt-system-disk-cleanup.sh --help
```

### Přepínače

| Přepínač | Popis |
|---|---|
| `--dry-run`, `-n` | Jen ukáže, co by se uklidilo, nic nemaže |
| `--docker-volumes` | Uvolní i nepoužívané Docker volumes — **⚠️ může smazat data** (DB, aplikace), proto je mimo výchozí úklid |
| `--help`, `-h` | Nápověda |

### Poznámky

- Vyžaduje `sudo` (úklid `/var`, `/tmp`, journalu); o heslo si řekne jednou na začátku.
- Docker a Snap sekce se spustí jen pokud jsou nástroje nainstalované.
- Doporučení: nejdřív spustit s `--dry-run`.
