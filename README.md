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
- **Dočasné soubory** — soubory ve `/tmp` nezměněné ani nečtené 3 dny (`mtime` i `atime`);
  vynechá skryté položky v kořeni `/tmp` (zámky X serveru apod.), privátní `/tmp`
  služeb a snapů a nepřechází na jiné souborové systémy
- **systemd journal** — `journalctl --vacuum-time=7d` (ponechá posledních 7 dní)
- **Docker** — `docker system prune` (zastavené kontejnery, nepoužívané sítě, dangling
  images a build cache; otagované nepoužívané images **nemaže**)
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
| `--dry-run`, `-n` | Jen ukáže, co by se uklidilo (balíky z `autoremove`, počet a velikost souborů v `/tmp`, velikost journalu, staré revize snapů), nic nemaže |
| `--docker-volumes` | Uvolní i nepoužívané Docker volumes — **⚠️ může smazat data** (DB, aplikace), proto je mimo výchozí úklid |
| `--help`, `-h` | Nápověda |

### Poznámky

- Vyžaduje `sudo` (úklid `/var`, `/tmp`, journalu); o heslo si řekne jednou na začátku.
  `--dry-run` heslo nevyžaduje – bez platného `sudo` jen počítá s tím, co je čitelné.
- Docker a Snap sekce se spustí jen pokud jsou nástroje nainstalované. Bez členství
  ve skupině `docker` se Docker volá přes `sudo`.
- Uvolněné místo se u každé sekce měří na souborovém systému, kde leží její data
  (u journalu jako úbytek jeho velikosti); celkový součet na konci je měřený na `/`.
- Doporučení: nejdřív spustit s `--dry-run`.
