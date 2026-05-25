# Prod-Rollout Runbook — Brewing Stack

Dieser Runbook deckt zwei Szenarien ab:

- **A — Frischer VPS** (keine DB-Daten, alles from scratch)
- **B — Bestehende DB migrieren** (Daten vorhanden, Migrationen nachziehen)

**Scope:** Single-VPS-Deployment mit `docker compose -p webpage_infra`. Der Runbook
setzt voraus, dass `bootstrap.sh` bereits gelaufen ist und `supabase-db` läuft.

---

## Schema-Baseline (Szenario A: frische DB)

Für frische Deploys gibt es eine konsolidierte Baseline-Datei:

```
webPage_infra/db_scripts/baseline_schema.sql
```

Diese eine Datei reproduziert den getesteten End-Zustand aller 14 historischen
Migrationen (aibrewgenius 001–009 + rapt 001–005) auf einer frischen
`supabase/postgres:15.8.1.060`-Instanz. Die korrekte Cross-Schema-Reihenfolge
(aibrewgenius vor rapt) ist im Baseline bereits eingebaut.

Die Migrations-Files in den App-Repos bleiben als historische Dokumentation erhalten
und können via `apply-db-migrations.sh` zum Nachvollziehen der Änderungshistorie oder
zur Neuerzeugung des Baseline verwendet werden. Für den Prod-Deploy werden sie nicht
mehr benötigt.

**Nach dem Launch:** Neue Schema-Änderungen laufen als neue Migrations-Dateien auf dem
Baseline — der Baseline selbst wird nicht mehr editiert.

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

**Baseline-Datei verfügbar machen** — eine von zwei Varianten wählen:

Die Baseline-Datei `db_scripts/baseline_schema.sql` liegt im `webPage_infra`-Repo
und ist damit bei einem Repo-Klon automatisch vorhanden. App-Repos müssen für den
Baseline-Apply nicht mehr geklont werden.

**Variante 1 — Apply direkt auf dem VPS** (empfohlen):
```bash
# webPage_infra ist bereits geklont (Bootstrap-Schritt)
cd ~/webPage_infra
./scripts/apply-baseline.sh
```

**Variante 2 — Apply vom Dev-Rechner via DB-TCP-Tunnel** (VPS-Zugriff nicht nötig):
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
EXTERNAL_PSQL=1 ./scripts/apply-baseline.sh --yes
unset PGPASSWORD
```

---

## Schritt 0 — Dry-Run (Pflicht vor jedem Apply)

Vor dem eigentlichen Apply immer erst den Plan prüfen:

```bash
cd ~/webPage_infra
./scripts/apply-baseline.sh --dry-run
```

Erwartete Ausgabe: Baseline-Datei gefunden mit Pfad und Zeilenzahl, Ziel-Container
und Warnung zu DROP SCHEMA. Wenn die Datei fehlt: `webPage_infra`-Repo aktuell ziehen
(`git pull`).

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

## Schritt 2 — DB-Init via Baseline (Szenario A: frische DB)

*Szenario B (Daten vorhanden): Schritt 2 überspringen — Baseline nicht auf einer
bereits migrierten DB anwenden. Stattdessen neue Migrations-Dateien manuell via
`docker exec ... psql` anwenden.*

**Hintergrund:** Auf einer frischen Prod-DB gibt es keine Bestandsdaten, die durch
Migrations-Wiedergabe geschützt werden müssten. Der konsolidierte Baseline ist der
direkte, getestete End-Zustand — er ist schneller, einfacher, und erfordert keine
App-Repo-Klone auf dem Ziel-Server. Die einzelnen Migrations-Files in den App-Repos
bleiben als historische Dokumentation erhalten; `apply-db-migrations.sh` ist ihr
Regenerations-Tool.

**Vor dem Apply:** brew-proxy stoppen, falls er läuft.
Der Baseline enthält einen Table-Lock auf `telemetry_*` (rapt-Teil). Eine aktive
brew-proxy-Verbindung kann diesen Lock halten und den Apply abbrechen.

```bash
docker stop brew-proxy 2>/dev/null || true
```

```bash
cd ~/webPage_infra
./scripts/apply-baseline.sh
```

Das Script:
- prüft `db_scripts/baseline_schema.sql` und den Ziel-Container vor dem Start
- fragt interaktiv nach Bestätigung (TTY), da der Baseline DROP SCHEMA ... CASCADE
  enthält; bei Nicht-TTY (Pipe/CI) ist `--yes` zwingend erforderlich, sonst Abbruch
- wendet die Datei mit `ON_ERROR_STOP=1` an — Abbruch bei erstem Fehler
- schreibt kein Passwort in argv oder Logs (PGPASSWORD via `-e` an docker exec)

**Nach dem Apply:** brew-proxy wieder starten:

```bash
docker start brew-proxy
```

**Wenn der Apply fehlschlägt:**
1. Fehlerausgabe lesen — psql gibt die SQL-Zeile und den Postgres-Fehler aus
2. Der Baseline läuft in einer expliziten Transaktion (BEGIN/COMMIT am Anfang/Ende):
   bei Fehler wird alles zurückgerollt — die DB bleibt sauber, nach dem Fix einfach
   nochmals starten
3. Bei unklarem Zustand: Volume löschen, supabase-db neu starten (frische Init),
   dann erneut anwenden

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

### Baseline-Abbruch wegen Lock-Timeout (rapt-Teil)

Der rapt-Teil des Baseline setzt `lock_timeout='5s'` und nimmt einen Table-Lock auf
`telemetry_*`. Bei laufenden Verbindungen (brew-proxy aktiv) kann der Timeout
ausgelöst werden. Lösung: brew-proxy vor dem Apply stoppen, danach neu starten.

```bash
docker stop brew-proxy
./scripts/apply-baseline.sh --yes
docker start brew-proxy
```

Da der gesamte Baseline in einer Transaktion läuft, ist der Zustand nach einem
Abbruch sauber zurückgerollt — nach dem Stopp von brew-proxy einfach erneut starten.

---

## Bekannte Lücken / Künftige Verbesserungen

- **Kein Versions-Tracking:** Es gibt keine Tabelle (à la Flyway `flyway_schema_history`),
  die festhält, welche Migrationen bereits angewendet wurden. Neue Migrations-Dateien
  nach dem Launch müssen manuell via `docker exec ... psql` angewendet werden. Künftig:
  eine `schema_migrations`-Tabelle einführen und ein Apply-Script um einen
  Skip-already-applied-Mechanismus erweitern.
- **Kein "ab-Datei"-Parameter in apply-db-migrations.sh:** Das Regenerations-Tool
  beginnt immer bei Datei 1 (destruktiv). Für einen teil-Apply müssen die Dateien
  manuell via `docker exec ... psql < <file>` angewendet werden.
- **Baseline ist destruktiv bei Re-Run:** `apply-baseline.sh` ist für frische DBs
  gedacht. Auf einer DB mit Daten führt ein Re-Run zu Datenverlust (DROP SCHEMA CASCADE).
  Das Script erzwingt daher eine explizite Bestätigung und warnt deutlich.
