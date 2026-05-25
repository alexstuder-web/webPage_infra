# Prod-Rollout Runbook — Brewing Stack

Dieser Runbook deckt zwei Szenarien ab:

- **A — Frischer VPS** (keine DB-Daten, alles from scratch)
- **B — Bestehende DB migrieren** (Daten vorhanden, Migrationen nachziehen)

**Scope:** Single-VPS-Deployment mit `docker compose -p webpage_infra`. Der Runbook
setzt voraus, dass `bootstrap.sh` bereits gelaufen ist und `supabase-db` läuft.

---

## Migrations-Liste (vollständig, geordnet)

Die Reihenfolge ist nicht verhandelbar. `rapt/004` setzt einen `auth.users`-Lookup
voraus, der erst durch `aibrewgenius/002` existiert.

| # | Datei | Pfad |
|---|-------|------|
| 1 | `001_init_schema.sql` | `brew_assistent-new/db_scripts/full/` |
| 2 | `002_auth.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 3 | `003_vault.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 4 | `004_proxy_role.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 5 | `005_fix_proxy_role_grants.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 6 | `006_retire_aibrewgenius_rapt.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 7 | `007_harden_brewfather_search_path.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 8 | `008_drop_aibrewgenius_rapt_columns.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 9 | `009_drop_aibrewgenius_rapt_shims.sql` | `brew_assistent-new/db_scripts/migrations/` |
| 10 | `001_init_rapt_schema.sql` | `RAPT_Brewing_Dashboard-new/db_scripts/` |
| 11 | `002_user_profiles.sql` | `RAPT_Brewing_Dashboard-new/db_scripts/` |
| 12 | `003_device_activity_view.sql` | `RAPT_Brewing_Dashboard-new/db_scripts/` |
| 13 | `004_rapt_user_vault.sql` | `RAPT_Brewing_Dashboard-new/db_scripts/` |
| 14 | `005_rapt_telemetry_owner.sql` | `RAPT_Brewing_Dashboard-new/db_scripts/` |

---

## Voraussetzungen

Folgende Punkte müssen erfüllt sein, bevor Schritt 1 beginnt:

- [ ] VPS provisioniert (Ubuntu 22.04 / 24.04), SSH-Zugang vorhanden
- [ ] `bootstrap.sh` erfolgreich gelaufen (Docker, User `alex`, cron)
- [ ] `.env.gpg` entschlüsselt → `.env` liegt in `~/webPage_infra/`
- [ ] `/etc/brewing/gpg.pass` geseedet (von `bootstrap.sh` beim ersten Lauf angelegt)
- [ ] `supabase-db` Container läuft (`docker ps | grep supabase-db`)
- [ ] `zz-set-role-passwords.sh` automatisch gelaufen beim ersten DB-Start
  (setzt `supabase_admin`-, `proxy_sync`- und weitere Passwörter aus `.env`)

**App-Repos verfügbar machen** — eine von zwei Varianten wählen:

**Variante 1 — App-Repos auf dem VPS klonen** (empfohlen für Erstssetup):
```bash
cd ~
git clone https://github.com/alexstuder-web/brew_assistent-new.git
git clone https://github.com/alexstuder-web/RAPT_Brewing_Dashboard-new.git
```

**Variante 2 — Apply vom Dev-Rechner via DB-TCP-Tunnel** (keine Repo-Klone auf VPS nötig):
```bash
# DB-TCP-Tunnel starten (siehe docker-compose.tunnel-tcp.yml)
# Dann auf dem Dev-Rechner:
export PGHOST=db-tcp.alexstuder.cloud
export PGPORT=15432
export PGUSER=supabase_admin
export PGDATABASE=postgres
# PGPASSWORD via read -rs eingeben — landet NICHT in der Shell-History.
# Alternative: PGPASSFILE=~/.pgpass (PostgreSQL-Passwort-Datei, chmod 600).
read -rs -p "supabase_admin Passwort: " PGPASSWORD; echo
export PGPASSWORD
export EXTERNAL_PSQL=1
cd ~/webPage_infra
./scripts/apply-db-migrations.sh --yes
unset PGPASSWORD
```

---

## Schritt 0 — Dry-Run (Pflicht vor jedem Apply)

Vor dem eigentlichen Apply immer erst die Dateiliste prüfen:

```bash
cd ~/webPage_infra
./scripts/apply-db-migrations.sh --dry-run
```

Erwartete Ausgabe: 14 Migrations-Dateien mit korrekten Pfaden und Zeilenzahlen.
Wenn Dateien fehlen: App-Repos klonen (Variante 1) oder Pfade mit `-a` / `-r` setzen.

---

## Schritt 1 — Pre-Migration-Backup (nur Szenario B)

*Szenario A (frische DB, keine Daten): Schritt 1 überspringen.*

Bei bestehenden Daten immer zuerst einen Backup anlegen:

```bash
cd ~/webPage_infra
./scripts/backup.sh --label pre-migration
```

`--label pre-migration` markiert den Dump als rotation-exempt (wird von der
automatischen Retention-Bereinigung nicht gelöscht). Der Dump landet lokal in
`backups/supabase/` und wird zu R2 hochgeladen (falls R2-Creds in `.env` gesetzt).

Backup verifizieren:
```bash
ls -lh ~/webPage_infra/backups/supabase/ | grep pre-migration
```

---

## Schritt 2 — Migrationen anwenden

**Vor dem Apply:** brew-proxy stoppen, falls er läuft.
`rapt/005_rapt_telemetry_owner.sql` setzt `lock_timeout='5s'` und nimmt einen
Table-Lock auf `telemetry_*`. Eine aktive brew-proxy-Verbindung kann diesen Lock
halten und den Apply abbrechen. Sicherer Ablauf:

```bash
docker stop brew-proxy 2>/dev/null || true
```

```bash
cd ~/webPage_infra
./scripts/apply-db-migrations.sh
```

Das Script:
- prüft alle 14 SQL-Dateien vor dem Start (kein partieller Apply bei fehlenden Dateien)
- fragt interaktiv nach Bestätigung (TTY), da 001_init_schema.sql destruktiv ist;
  bei Nicht-TTY (Pipe/CI) ist `--yes` zwingend erforderlich, sonst Abbruch
- wendet jede Datei mit `ON_ERROR_STOP=1` an — Abbruch bei erstem Fehler
- loggt jede Datei mit klarem Start/Ende

**Nach dem Apply:** brew-proxy wieder starten:

```bash
docker start brew-proxy
```

**Alternative Pfade** (falls App-Repos nicht in `../` liegen):
```bash
./scripts/apply-db-migrations.sh \
  -a /pfad/zu/brew_assistent-new/db_scripts \
  -r /pfad/zu/RAPT_Brewing_Dashboard-new/db_scripts
```

**Wenn eine Migration fehlschlägt:**
1. Fehlerausgabe lesen — psql gibt die SQL-Zeile und den Postgres-Fehler aus
2. Wenn die Fehler-Migration eine Transaktion enthält (BEGIN/COMMIT): alles vor
   dem Fehler wurde zurückgerollt — die Migration kann nach dem Fix wiederholt werden
3. Wenn keine Transaktion: partiellen Zustand prüfen und ggf. manuell aufräumen
4. Szenario B: bei unklarem Zustand Backup (Schritt 1) einspielen (`restore.sh all`)

**Hinweis Datenmigrations-Schritte bei frischer DB:**
- `002_auth.sql` legt den Bootstrap-User `alex@alexstuder.ch` an (UUID) und
  migriert die `'self_hosted_profile'`-Row. Auf einer frischen DB gibt es keine
  Bestandsdaten → der Migration-Schritt läuft als No-op durch.
- `rapt/005_rapt_telemetry_owner.sql` enthält eine Datenmigration
  (`owner IS NULL → Alex-UUID`). Auf einer frischen DB existieren keine Rows → No-op.

---

## Schritt 3 — App-Code deployen

**Reihenfolge ist entscheidend:** App-Code-Deploy MUSS nach den Migrationen
erfolgen. Ein frisch deployeter Container erwartet die rapt-RPCs, die erst durch
`rapt/005_rapt_telemetry_owner.sql` existieren. Umgekehrt → Startup-Fehler.

```bash
# Watchtower-gesteuert (Normalfall):
# git push → GitHub Actions baut Image → Docker Hub → Watchtower pullt + restartet

# Manueller Restart (falls Container laufen und Image bereits aktuell ist):
cd ~/webPage_infra
docker compose -p webpage_infra pull
docker compose -p webpage_infra up -d
```

**proxy_sync-Credentials prüfen:**
Der `brew-proxy`-Container verbindet sich via `DATABASE_URL` mit `proxy_sync` als
DB-User. Das Passwort wird von `zz-set-role-passwords.sh` beim ersten DB-Start
gesetzt und muss mit `PROXY_SYNC_PASSWORD` in `.env` übereinstimmen.

Prüfen:
```bash
grep PROXY_SYNC_PASSWORD ~/webPage_infra/.env
# und:
docker logs brew-proxy 2>&1 | tail -20
```

Wenn der Container Verbindungsfehler zeigt:
```bash
# Passwort in DB explizit setzen.
# Achtung: Passwort NICHT in -c "..." schreiben (ps aux sichtbar).
# \set-Variablen-Pattern hält das Secret aus dem argv.
_pg_pw="$(grep '^POSTGRES_PASSWORD='    ~/webPage_infra/.env | head -1)"; _pg_pw="${_pg_pw#*=}"
_sync_pw="$(grep '^PROXY_SYNC_PASSWORD=' ~/webPage_infra/.env | head -1)"; _sync_pw="${_sync_pw#*=}"
printf "ALTER ROLE proxy_sync PASSWORD :'pw';\n" \
  | docker exec -i -e PGPASSWORD="$_pg_pw" \
      supabase-db \
      psql -U supabase_admin -d postgres \
      -v "pw=${_sync_pw}"
unset _pg_pw _sync_pw
docker restart brew-proxy
```

---

## Schritt 4 — Mandatory Live-Verifikation (Gates)

Alle drei Gates müssen grün sein, bevor der Rollout als abgeschlossen gilt.

### Gate A — Hypertable-Restore-Test (TimescaleDB)

Ziel: beweisen, dass TimescaleDB-Chunks korrekt verknüpft sind (rapt-Telemetrie-Queries
liefern Daten). Lokal war dieser Test nicht vollständig beweisbar (keine Prod-Hypertable-Daten).

```bash
# 1. Backup anlegen
cd ~/webPage_infra
./scripts/backup.sh --label hypertable-gate

# 2. Restore in einen isolierten Test-Stack (NIEMALS gegen den Live-Stack)
#    Isolierter Stack mit anderem Projekt-Namen:
mkdir -p /tmp/brewing-test
cp ~/webPage_infra/.env /tmp/brewing-test/.env
cp ~/webPage_infra/docker-compose.yml /tmp/brewing-test/
cd /tmp/brewing-test
docker compose -p brewing-test up -d supabase-db

# 3. Restore (jüngsten Dump aus R2)
DB_CONTAINER=brewing-test-supabase-db-1 \
  ~/webPage_infra/scripts/restore.sh all latest --yes

# 4. Counts prüfen — müssen > 0 sein wenn Telemetrie-Daten vorhanden
docker exec -e PGPASSWORD="$(grep '^POSTGRES_PASSWORD=' /tmp/brewing-test/.env | cut -d= -f2-)" \
  brewing-test-supabase-db-1 \
  psql -U supabase_admin -d postgres \
  -c "SELECT count(*) FROM rapt.telemetry_controllers; SELECT count(*) FROM rapt.telemetry_hydrometers;"

# ERWARTUNG: count > 0 (zeigt funktionierende TimescaleDB pre/post_restore-Hooks)
# 0 nach Restore = defekte Chunk-Verknüpfung → restore.sh Hooks prüfen

# 5. Aufräumen (Volumes + /tmp-Verzeichnis mit .env-Kopie)
docker compose -p brewing-test down -v
rm -rf /tmp/brewing-test
```

### Gate B — SSO cross-subdomain

Ziel: Login in einer App → andere App ohne zweiten Login eingeloggt.
Cookie `sb-session` muss `Domain=.alexstuder.cloud; Secure; SameSite=Lax` tragen.

```
1. Browser öffnen (Inkognito / ohne Cookies)
2. https://brew.alexstuder.cloud aufrufen → Login mit alex@alexstuder.ch
3. Cookie in DevTools prüfen: Application → Cookies → sb-session
   → Domain muss ".alexstuder.cloud" sein (nicht "brew.alexstuder.cloud")
4. https://rapt.alexstuder.cloud in neuem Tab öffnen
   → KEIN zweiter Login-Dialog erwartet (Session wird übernommen)
5. Beide Apps zeigen denselben User in der Profil-Anzeige
```

Schlägt Gate B fehl:
- Supabase JWT-Cookies prüfen: `SUPABASE_COOKIE_DOMAIN` in `.env` (muss `.alexstuder.cloud`)
- Cloudflare-Tunnel-Routing prüfen: beide Subdomains müssen auf denselben Supabase-Stack zeigen

### Gate C — Tenant-Isolation-Smoke

Ziel: zweiter User sieht keine Daten des ersten.

```
1. Zweiten Test-Account anlegen (z.B. test2@example.com via Supabase Auth-UI
   oder: curl -X POST .../auth/v1/signup)
2. Als test2 einloggen
3. brew_assistent: Rezeptliste muss leer sein (nicht Alex' Rezepte)
4. RAPT-Dashboard: Geräte/Sessions-Liste muss leer sein
5. Als alex einloggen → Daten weiterhin vorhanden
```

Schlägt Gate C fehl: RLS-Policies prüfen. Alle aibrewgenius- und rapt-Tabellen
müssen RLS aktiviert haben und Policies mit `auth.uid() = owner` enthalten.

```bash
# RLS-Status aller Tabellen prüfen:
docker exec -e PGPASSWORD="$(grep '^POSTGRES_PASSWORD=' ~/webPage_infra/.env | cut -d= -f2-)" \
  supabase-db \
  psql -U supabase_admin -d postgres \
  -c "SELECT schemaname, tablename, rowsecurity FROM pg_tables
      WHERE schemaname IN ('aibrewgenius','rapt') ORDER BY 1,2;"
# rowsecurity muss für alle Tabellen 't' sein
```

---

## Fehlerbehebung

### supabase-db startet, aber Passwörter passen nicht

`zz-set-role-passwords.sh` läuft nur beim **ersten** Container-Start
(docker-entrypoint-initdb.d). Bei einer bereits initialisierten DB (Volume vorhanden)
läuft das Script nicht erneut. Passwörter manuell setzen:

```bash
# Selektiv extrahieren — kein 'source .env' (würde alle Secrets in den Shell-Scope laden).
# Passwort via \set-Variable, NICHT in -c "..." (wäre in ps aux sichtbar).
_pg_pw="$(grep '^POSTGRES_PASSWORD='    ~/webPage_infra/.env | head -1)"; _pg_pw="${_pg_pw#*=}"
_sync_pw="$(grep '^PROXY_SYNC_PASSWORD=' ~/webPage_infra/.env | head -1)"; _sync_pw="${_sync_pw#*=}"
printf "ALTER ROLE proxy_sync PASSWORD :'pw';\n" \
  | docker exec -i -e PGPASSWORD="$_pg_pw" \
      supabase-db \
      psql -U supabase_admin -d postgres \
      -v "pw=${_sync_pw}"
unset _pg_pw _sync_pw
```

### Migrations-Abbruch bei rapt/005 (lock_timeout)

`rapt/005_rapt_telemetry_owner.sql` setzt `lock_timeout='5s'` für Prod. Bei
laufenden Verbindungen (brew-proxy aktiv) kann der Lock-Timeout ausgelöst werden.
Lösung: brew-proxy vor dem Apply stoppen, danach neu starten.

```bash
docker stop brew-proxy
./scripts/apply-db-migrations.sh -r /pfad/zu/RAPT_Brewing_Dashboard-new/db_scripts
# (nur rapt-Migrations wenn aibrewgenius bereits angewendet)
docker start brew-proxy
```

Für einen teilweisen Apply (nur die verbleibenden Dateien) muss das Script manuell
adaptiert werden — ein automatischer "ab-Datei"-Parameter existiert noch nicht (siehe
unten: Bekannte Lücken).

---

## Bekannte Lücken / Künftige Verbesserungen

- **Kein Versions-Tracking:** Es gibt keine Tabelle (à la Flyway `flyway_schema_history`),
  die festhält, welche Migrationen bereits angewendet wurden. Auf einer teilweise
  migrierten DB muss manuell geprüft werden, welche Dateien noch fehlen. Künftig:
  eine `schema_migrations`-Tabelle einführen und `apply-db-migrations.sh` um einen
  Skip-already-applied-Mechanismus erweitern.
- **Kein "ab-Datei"-Parameter:** `apply-db-migrations.sh` beginnt immer bei Datei 1
  (001_init_schema, destruktiv). Für einen teil-Apply müssen die Dateien manuell
  via `docker exec ... psql < <file>` angewendet werden.
- **001_init_schema ist destruktiv:** `DROP SCHEMA IF EXISTS aibrewgenius CASCADE`
  macht Datenverlust auf re-run. Langfristig sollte 001 in idempotente Teilschritte
  aufgeteilt werden.
