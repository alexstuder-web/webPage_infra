# Backup & Restore — Betriebs- und Konzeptdoku

> **Status:** Implementiert + lokal getestet (Variante A; keep-N=7 lokal+R2; cron als `alex`).
> `scripts/backup.sh` / `restore.sh` / `bootstrap.sh` fertig; Round-Trip, Retention und
> echter R2-Upload gegen Wegwerf-Stack verifiziert. Multi-VPS Phase 1 + Phase 2 committed.
> **Phase 4:** Zwei getrennte DBs pro App (`db-assistent` / `db-rapt`), je eigener R2-Ordner.
> **Noch offen:** Smoke-Test auf echtem zweiten VPS; echter 2-VPS-Migrations-Round-Trip noch
> nicht live durchgeführt; TimescaleDB-Live-Hypertable-Restore (Prod-Gate, db-rapt).

> Architektur-Hintergrund (4 verschiebbare Einheiten, Cloudflare-Tunnel, `proxy_sync`):
> → **[MULTIVPS_ARCHITEKTUR.md](MULTIVPS_ARCHITEKTUR.md)** — nicht hier dupliziert.

---

## 1. Was wird gesichert — und was nicht

Echter, nicht-reproduzierbarer State existiert an **zwei** Stellen: den beiden getrennten
Postgres-Instanzen `db-assistent` (App-Daten brew_assistent) und `db-rapt` (RAPT-Telemetrie).
Alles andere ist stateless.

| Repo | Backup | Restore | Begründung |
|---|---|---|---|
| `WebPageAlexStuder-new` (Nginx static) | ❌ | ❌ | Build-Artefakt → Git + Docker-Hub-Image. |
| `brew_assistent-new` (Flutter Web) | ❌ App / ✅ Daten | ❌ App / ✅ Daten | Daten in `db-assistent`: Schema `aibrewgenius.*` + `auth`. |
| `RAPT_Brewing_Dashboard-new` (Flutter Web) | ❌ App / ✅ Daten | ❌ App / ✅ Daten | Daten in `db-rapt`: Schema `rapt.*` + `auth` + TimescaleDB-Hypertables. |
| `brew-proxy-new` (Node) | ❌ | ❌ | Stateless. `db-sync.js` schreibt nur nach Postgres. |
| `webPage_infra` | ✅ | ✅ | **Hier läuft Backup/Restore.** |

**Zwei getrennte DBs pro App:** `db-assistent` und `db-rapt` sind vollständig unabhängige
Postgres-Container mit je eigenem Backup-Subjekt, R2-Ordner und Marker. `auth` existiert in
beiden DBs getrennt. Es gibt keinen gemeinsamen `auth`-Namespace mehr.

`supabase-storage-data` Volumes sind aktuell ungenutzt — implizit im Whole-DB-Dump enthalten.

---

## 2. Entscheidungen (abgenommen)

| Punkt | Entscheidung |
|---|---|
| Dump-Granularität | **Zwei getrennte Whole-DB-`pg_dump -Fc`** — einer pro App-DB (db-assistent / db-rapt). Kein Schema-Split, kein `--exclude-schema`. |
| Konsistenz | Jeder `pg_dump -Fc` erzeugt **einen konsistenten Transaktions-Snapshot** seiner DB. |
| Format / Verschlüsselung | `pg_dump -Fc` → GPG **symmetrisch** AES-256, **gleiche Passphrase wie `.env.gpg`**. |
| Trigger | **cron**, nightly ~03:00, unbeaufsichtigt. Passphrase aus `/etc/brewing/gpg.pass` (mode 600, owner `alex`). |
| Off-site | **Cloudflare R2**, Bucket **`backup`**, Ordner `db-assistent/` und `db-rapt/`. |
| R2-Token | Aktuell: **account-weiter R2-Token** in Gebrauch (`.env`-Vars: `R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`). Ein dedizierter, auf Bucket `backup` gescopter Token (Object Read & Write) ist **optional und empfohlen** — kein Blocker. |
| Lokale Ablage | `webPage_infra/backups/db-assistent/` und `webPage_infra/backups/db-rapt/` (gitignored). |
| Restore | **immer manuell**, nicht Teil von bootstrap. `restore.sh db-assistent|db-rapt|all`. |

### Bucket-Layout
```
backup/                         (R2-Bucket)
├── db-assistent/               Whole-DB-Dump von db-assistent (aibrewgenius + auth)
│   └── db-assistent_<TS>[_<label>].fc.gpg
├── db-rapt/                    Whole-DB-Dump von db-rapt (rapt + auth + TimescaleDB)
│   └── db-rapt_<TS>[_<label>].fc.gpg
└── <future_unit>/ …            erweiterbar pro neuem stateful Service
```

*(Historisch existieren noch `_supabase_core/`, `brew_assistent/`, `rapt_dashboard/`,
`supabase/` in R2 — diese werden nicht mehr gelesen oder beschrieben, bleiben als
historischer Anker.)*

---

## 3. Backup-Flow (`scripts/backup.sh`)

### Marker-gesteuerte Job-Ableitung

`backup.sh` leitet die Dump-Jobs **nicht** aus hartkodierter Logik ab, sondern aus den
in `/etc/brewing/stateful-units.d/` installierten Markern (leere Touch-Dateien, eine
pro stateful Unit). Ist kein Marker vorhanden, beendet sich `backup.sh` mit Exit 0 ohne
irgendeinen Container zu berühren — **sauberer No-op**.

Es gibt zwei stateful DB-Marker:
- `/etc/brewing/stateful-units.d/db-assistent` → erzeugt Dump in `backup/db-assistent/`
- `/etc/brewing/stateful-units.d/db-rapt` → erzeugt Dump in `backup/db-rapt/`

Ein VPS mit nur einem Marker führt genau einen Dump durch. Ein VPS ohne Marker ist ein
garantierter No-op — kein Fehler, kein Alarm.

### Dump-Ablauf (bei installierten Markern)

**Wo läuft der Backup?** Lokal auf dem DB-VPS: `backup.sh` ruft `docker exec` gegen den
lokalen Container auf. Es gibt keinen „Backup über den Tunnel".

```
db-assistent-Marker → ein konsistenter Whole-DB-Dump:
   └─ docker exec -e PGPASSWORD=$ASSISTENT_POSTGRES_PASSWORD db-assistent
         pg_dump -Fc -U supabase_admin -d postgres
         (kein --exclude-schema / -n → alle Schemas: auth + aibrewgenius + Rest)
         | gpg --batch --symmetric AES256 --passphrase-file /etc/brewing/gpg.pass
         → backups/db-assistent/db-assistent_<TS>.fc.gpg    → R2 db-assistent/

db-rapt-Marker → ein konsistenter Whole-DB-Dump:
   └─ docker exec -e PGPASSWORD=$RAPT_POSTGRES_PASSWORD db-rapt
         pg_dump -Fc -U supabase_admin -d postgres
         (kein --exclude-schema / -n → alle Schemas: auth + rapt + TimescaleDB-Katalog)
         | gpg --batch --symmetric AES256 --passphrase-file /etc/brewing/gpg.pass
         → backups/db-rapt/db-rapt_<TS>.fc.gpg               → R2 db-rapt/
```

- **Kein Klartext auf Platte:** der Dump streamt direkt durch `gpg -o <out>`.
- `PGPASSWORD` wird als `-e`-Env an `docker exec` übergeben (nicht in der Host-argv).
- GPG-Passphrase via `--passphrase-file /etc/brewing/gpg.pass` (mode 600, owner `alex`).
- **`--label <name>`-Flag:** hängt `_<name>` an den Dateinamen an (z.B. `pre-migration`).
  Gelabelte Dumps sind **rotation-exempt** — sie zählen nicht zur N-Retention.
- **`--no-upload`-Flag:** sichert nur lokal, kein R2-Upload.
- **Retention** pro Ordner: neueste `N` automatische Dumps behalten (lokal UND R2),
  Rest gelöscht. `N` via `BACKUP_KEEP` (default 7). Gelabelte Dumps exempt.
  Rotation läuft **pro Ordner getrennt** (`db-assistent/` und `db-rapt/` unabhängig).
- **R2-Upload + Prune** via `rclone`. Falls `R2_ACCESS_KEY_ID` nicht gesetzt: nur lokal.

---

## 4. Off-site: Cloudflare R2

- Bucket `backup`; R2-Token (Object Read & Write) — siehe R2-Token-Entscheidung in [§2](#2-entscheidungen-abgenommen).
- `.env`-Variablen (in `.env.gpg`): `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
  `R2_ACCOUNT_ID`, `R2_ENDPOINT`, `R2_BUCKET=backup`. `R2_ENDPOINT` kann leer bleiben
  (Script leitet `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com` ab).
- Es geht nur die bereits GPG-verschlüsselte Datei raus → R2 sieht nie Klartext.
- Retention off-site: `backup.sh` prunet R2 selbst auf die neuesten `BACKUP_KEEP` pro
  Ordner (gleiche count-based Logik wie lokal). Keine R2-Lifecycle-Rule nötig.

---

## 5. Initialer R2-Seed (einmaliger Vorgang)

Der erste R2-Backup-Stand wird mit einem normalen `backup.sh`-Lauf (ohne `--label`)
erzeugt, sobald beide DBs laufen und die Marker gesetzt sind. Nach dem Lauf liegen:
- `backup/db-assistent/db-assistent_<TS>.fc.gpg`
- `backup/db-rapt/db-rapt_<TS>.fc.gpg`

Diese sind der Ausgangspunkt für Erst-Bootstraps neuer VPS via Menü-Option 3
(→ [§5a](#5a-restore-szenario-1a-erstlauf-auf-frischem-vps-bootstrap-menu-option-3)).

---

## 5a. Restore-Szenario 1a: Erstlauf auf frischem VPS (`bootstrap.sh --menu`, Option 3)

**Situation:** Ein frischer VPS soll NICHT mit leeren DBs starten, sondern den letzten
Stand aus R2 laden — **ohne** SSH-Zugang zu einem alten VPS. Deckt zwei Fälle ab:
(1) **Erst-Lauf** und (2) **Disaster Recovery** (alter VPS tot/weg).

**Voraussetzung:** R2-Creds in `.env` gesetzt + mindestens ein Backup in R2
(`db-assistent/` und/oder `db-rapt/`).

### Ablauf

1. **Bootstrap auf dem neuen VPS:**
   ```
   curl -fsSL https://raw.githubusercontent.com/alexstuder-web/webPage_infra/main/scripts/bootstrap.sh \
     -o bootstrap.sh && chmod +x bootstrap.sh && sudo bash bootstrap.sh
   ```

2. **Menü-Option 1 — Apps & DBs starten (optional):**
   `bootstrap.sh --menu` → Option 1 → Apps auswählen.
   DBs initialisieren sich mit frischen Rollen/Schemas. Marker werden gesetzt.
   **Dieser Schritt ist optional** — `action_restore_from_r2` (Option 3) startet die DBs
   selbst hoch, falls sie noch nicht laufen.

3. **Menü-Option 3 — Erstdaten aus R2 restoren:**
   ```
   sudo bash ~/webPage_infra/scripts/bootstrap.sh --menu
   # → Option 3: Erstdaten aus R2 wiederherstellen (latest, destruktiv)
   ```

   `action_restore_from_r2()` führt folgende Schritte durch:
   - Vorbedingungen prüfen (`.env`, docker, rclone, gpg, R2-Vars).
   - Beide Stacks hochziehen falls nicht laufend (idempotent).
   - Marker setzen (`db-assistent` + `db-rapt`).
   - R2-Verfügbarkeit prüfen: jüngste `*.fc.gpg` in `db-assistent/` **und** `db-rapt/`.
     Kein Dump in einem Ordner → diese DB sauber skippen, die andere trotzdem restorieren.
   - Überschreib-Schutz: `SELECT count(*) FROM auth.users` pro DB — wenn > 0:
     Warnung + explizite Bestätigung `force-restore` erforderlich.
   - Tippe-`restore`-Prompt (TTY-Pflicht).
   - `./scripts/restore.sh db-assistent latest --yes`
   - `./scripts/restore.sh db-rapt latest --yes`
     (TimescaleDB-pre/post_restore-Hooks für db-rapt feuern automatisch via Extension-Guard)
   - Tabellen-Counts nach Restore pro DB.
   - `cf_reconcile_if_token` (Cloudflare-Routing).

4. **Smoke-Check:**
   - db-assistent: Login in der App + je eine Query auf `auth.users`, `aibrewgenius.recipes`.
   - db-rapt: `auth.users`, `rapt.brew_sessions`, `rapt.telemetry_controllers`,
     `rapt.telemetry_hydrometers` (0-Count auf `telemetry_*` = Indikator für kaputte
     TimescaleDB-Chunk-Verknüpfung → Prod-Gate beachten, [§5a-tsdb-gate](#timescaledb-prod-gate)).

### TimescaleDB-Prod-Gate (db-rapt)

Der `pg_extension`-Guard in `restore.sh` erkennt TimescaleDB pro Container und ruft
`pre_restore` / `post_restore` automatisch auf. Der Guard prüft die Extension per
`psql -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb'"` — ein psql-Fehler
führt zu einem **harten Abbruch** (kein stiller Skip). Bei `db-assistent` überspringt
der Guard sauber (keine TimescaleDB-Extension dort).

**MANDATORY Prod-Rollout-Gate:** Ein verifizierter Round-Trip-Restore mit live
TimescaleDB-Hypertable-Daten (`telemetry_*` Count > 0 nach Restore) ist auf einem echten
db-rapt mit Telemetrie-Daten zu bestätigen. Lokal nicht testbar wenn keine
TimescaleDB-Daten im Dev-Stack.

### Sicherheits-Guards

| Guard | Verhalten |
|---|---|
| Leerer R2-Ordner einer DB | Sauberer Skip für diese DB; andere DB wird trotzdem restoriert. |
| R2-Verbindungsfehler (Creds/Netzwerk) | `return 1` mit klarer Meldung (kein stiller Skip). |
| `auth.users > 0` auf Ziel-VPS (pro DB) | Warnung + `force-restore`-Eingabe nötig. |
| Kein TTY | Abbruch (kein Blind-Restore). |
| R2-Vars fehlen in `.env` | Klarer Hinweis + Return 0 (kein Stacktrace). |
| `ASSUME_YES=1` + DB-Zustand `UNKNOWN` | Harter Abbruch (`return 1`). DB-Health zuerst klären. |
| `ASSUME_YES=1` + bekannter Zustand | Proceed mit Warnung — Bestätigung gilt als via Env-Var erteilt. |

### Passphrase-Quelle für Restore

1. `/etc/brewing/gpg.pass` (mode 600, owner `alex`) — vorhanden nach Bootstrap.
2. `$GPG_PASSPHRASE`-Env.
3. Interaktiver Prompt (nur mit TTY).

---

## 5b. Restore-Szenario 1b: Disaster Recovery (VPS tot/neu, manuelle Variante)

**Situation:** der VPS ist zerstört oder ein neuer leerer VPS ersetzt ihn.
Diese Variante beschreibt den manuellen Weg via `restore.sh` direkt —
die integrierte Bootstrap-Option 3 (→ [§5a](#5a-restore-szenario-1a-erstlauf-auf-frischem-vps-bootstrap-menu-option-3))
ist der bevorzugte Weg.

### Runbook

1. **Bootstrap auf dem neuen VPS:**
   ```
   curl -fsSL https://raw.githubusercontent.com/alexstuder-web/webPage_infra/main/scripts/bootstrap.sh \
     -o bootstrap.sh && chmod +x bootstrap.sh && sudo bash bootstrap.sh
   ```

2. **Stack starten (Menü-Option 1 oder selektiv):**
   Nach erfolgreichem Start setzt `bootstrap.sh` die Marker idempotent
   (`/etc/brewing/stateful-units.d/db-assistent` / `.../db-rapt`) — ab sofort sind
   nächtliche Backups aktiv.

3. **Restore ausführen (pro DB):**
   ```
   cd ~/webPage_infra
   ./scripts/restore.sh db-assistent        # aibrewgenius + auth
   ./scripts/restore.sh db-rapt             # rapt + auth + TimescaleDB-Hooks
   # oder beide auf einmal:
   ./scripts/restore.sh all
   ```
   `latest` (Default) zieht den jüngsten `.fc.gpg` aus dem jeweiligen R2-Ordner.

4. **Cloudflare-Routing wiederherstellen:**
   ```
   ./scripts/cloudflare-reconcile.sh
   ```

5. **Smoke-Check:**
   - db-assistent: Login in der App + Query auf `aibrewgenius.recipes`.
   - db-rapt: `rapt.brew_sessions`, `rapt.telemetry_controllers`, `rapt.telemetry_hydrometers`.

---

## 6. Restore-Szenario 2: Migration / VPS-Umzug (`bootstrap.sh --menu`, Option 2)

**Situation:** Eine oder beide DB-Units sollen von einem laufenden alten VPS auf einen
neuen VPS verschoben werden.

**Was ist stateful, was nicht:**
- **db-assistent** (aibrewgenius + auth) — wählbar als Unit 1.
- **db-rapt** (rapt + auth + TimescaleDB) — wählbar als Unit 2.
- **brew_assistent, rapt_dashboard, brew-proxy, WebPageAlexStuder** sind zustandslos —
  via „Einheiten auswaehlen & starten" (Menü-Option 1) auf dem Ziel-VPS neu starten.

**Menü-Auswahl:** `1) db-assistent  2) db-rapt  3) beide  b) zurück`

**R2 ist das Transportmedium:** jede DB geht alt-VPS → R2 → neu-VPS getrennt.

**Voraussetzung:** passwortloser SSH-Zugang (BatchMode) vom neuen VPS zum alten.

### Runbook (orchestriert von `action_migrate_unit` in `bootstrap.sh`)

```
sudo bash ~/webPage_infra/scripts/bootstrap.sh --menu
# Menü → Option 2 (App migrieren)
# → Auswahl: 1) db-assistent  2) db-rapt  3) beide
# → SSH-Daten des alten VPS eingeben
```

#### (a) Backup + R2-Verifikation

```
ssh <alter VPS>  →  cd ~/webPage_infra && ./scripts/backup.sh --label pre-migration
```

Erstellt auf dem alten VPS je einen Whole-DB-Dump pro gewählter Unit mit Label
`pre-migration` (rotation-exempt). Danach prüft `bootstrap.sh` per SSH + rclone, ob der
gelabelte Dump in `R2 db-assistent/` und/oder `R2 db-rapt/` vorhanden ist.

#### (b) DB-Stack(s) auf altem VPS stoppen + Verifikation

Nur die Stacks der gewählten Unit(s) werden gestoppt. Für jede gewählte DB läuft ein
separater SSH-Verifikations-Call (`docker inspect --format='{{.State.Running}}'`).
Schlägt die Verifikation fehl (Container läuft noch), bricht `bootstrap.sh` hart ab.

#### (c) Stacks auf neuem VPS hochziehen

Pro gewählter Unit werden die entsprechenden Services gestartet.
Marker werden idempotent gesetzt.

#### (d) Restore pro Unit

Pro gewählter Unit:
```
./scripts/restore.sh db-assistent <db-assistent_<TS>_pre-migration.fc.gpg> --yes
./scripts/restore.sh db-rapt      <db-rapt_<TS>_pre-migration.fc.gpg>      --yes
```

Expliziter Dateiname aus der Verifikation — kein `latest` (vermeidet Verwechslung mit
neueren automatischen Dumps). Für db-rapt feuern TimescaleDB-Hooks automatisch via Guard.

#### (e) DB-Marker auf altem VPS entfernen

```
ssh <alter VPS>  →  rm -f /etc/brewing/stateful-units.d/db-assistent
                    rm -f /etc/brewing/stateful-units.d/db-rapt
```

Ohne Marker ist der nächste Cron-Lauf auf dem alten VPS ein sauberer No-op.

#### (f) DB-Marker auf neuem VPS sicherstellen

Idempotenter Check — Marker wurden bereits in Schritt (c) gesetzt.

### Überschreib-Schutz

Vor dem Start der Migration prüft `bootstrap.sh` per `SELECT count(*) FROM auth.users`
auf dem **neuen VPS** für jede gewählte DB, ob dort bereits Nutzer existieren.
Bei Fund: Abbruch mit Warnung. Explizite Eingabe `force-core` ist nötig um fortzufahren.

### Rollback

Jederzeit möglich, solange Schritt (d) nicht abgeschlossen ist:
```
ssh <alter VPS>  →  cd ~/webPage_infra && docker compose up -d
# Marker auf altem VPS wiederherstellen (falls Schritt e bereits gelaufen):
ssh <alter VPS>  →  touch /etc/brewing/stateful-units.d/db-assistent
                    touch /etc/brewing/stateful-units.d/db-rapt
```

Die pre-migration-Dumps liegen rotation-exempt in R2.

### Post-Migrations-Pflichten (manuell)

1. **Apps auf neuem VPS starten:**
   `bootstrap.sh --menu` → Option 1.

2. **Apps auf altem VPS stoppen:**
   ```
   ssh <alter VPS>  →  docker compose stop web_assistent web_rapt web_hauptseite
   ```

3. **Cloudflare-Routing auf altem VPS bereinigen.**

4. **`RAPT_DASHBOARD_URL` anpassen** (nur bei db-rapt-Migration auf separaten VPS).

5. **`RAPT_PROXY_DATABASE_URL` anpassen** (nur wenn api_proxy_rapt auf anderem VPS als db-rapt):
   ```
   RAPT_PROXY_DATABASE_URL=postgres://proxy_sync:<RAPT_PROXY_SYNC_PASSWORD>@host.docker.internal:15432/postgres?sslmode=disable
   ```
   `RAPT_PROXY_SYNC_PASSWORD` ist eine dedizierte Var — **nicht** `RAPT_POSTGRES_PASSWORD`.
   Dann `.env.gpg` neu verschlüsseln (`encrypt-env.sh`, Credential-Schritt).

---

## 7. Pre-Migration-Checkliste: Rollen & Grants

### `proxy_sync`-Rolle (nur in db-rapt relevant)

- `proxy_sync` wird in `db-rapt` beim ersten DB-Start automatisch durch
  `supabase/db_init/zz-set-role-passwords.sh` angelegt (idempotent).
- **Kein manueller Schritt** für die Rollen-Anlage — aber dieser Mechanismus muss
  funktionieren.

### `RAPT_PROXY_SYNC_PASSWORD` in `.env`

- Muss in `.env` gesetzt sein (eigenes Secret, **≠ `RAPT_POSTGRES_PASSWORD`**).
- `zz-set-role-passwords.sh` bricht hart ab, falls leer — `db-rapt`-Container startet dann nicht.

### Grants kommen via Restore, nicht via Init-Script

Die **Tabellen-Grants** für `proxy_sync` (SELECT auf `rapt.*`-Tabellen, Migration
`005_proxy_grants.sql`) stecken im **rapt-Dump** (`db-rapt/*.fc.gpg`).

**Konsequenz:** Die Restore-Quelle muss ein Dump sein, der **nach den Migrationen
004/005** erstellt wurde. Ein älterer Dump führt zu fehlenden Grants.

---

## 8. Restore-Details (`scripts/restore.sh`)

**Aufruf:**
```
restore.sh <db-assistent|db-rapt|all> [datei|latest] [--yes]
```
- `db-assistent`: Whole-DB-`pg_restore` aus `db-assistent/`-Dump gegen Container `db-assistent`.
- `db-rapt`: Whole-DB-`pg_restore` aus `db-rapt/`-Dump gegen Container `db-rapt`.
  TimescaleDB-pre/post_restore-Hooks feuern automatisch via Extension-Guard.
- `all`: beide DBs nacheinander (zwei unabhängige Restores, je aus ihrem Ordner).
- `latest` (Default): zieht den jüngsten `.fc.gpg` aus dem jeweiligen R2-Ordner.
- `<pfad>`: lokale `.fc.gpg`-Datei — nur für ein einzelnes Ziel sinnvoll
  (eine Datei kann nicht beide DBs füttern; `all` + explizite Datei → Fehler).
- `--yes`: überspringt die interaktive Bestätigung.

**Kein `--schema`-Selektiv-Restore:** jede DB hat nur ihr eigenes App-Schema + `auth`.
Ein selektiver Schema-Restore entfällt vollständig — die DB ist das Restore-Subjekt.

**TimescaleDB (nur db-rapt):**

Der `pg_extension`-Guard in `restore.sh`:
- Prüft via `psql -c "SELECT 1 FROM pg_extension WHERE extname='timescaledb'"` gegen den
  jeweiligen Container.
- Bei db-rapt (TimescaleDB installiert): ruft `pre_restore` **vor** `pg_restore` auf,
  `post_restore` **nach** `pg_restore`. Ein Fehler bei `post_restore` führt zu hartem Abbruch.
- Bei db-assistent (keine TimescaleDB): überspringt sauber mit Hinweis.
- Ein psql-Fehler beim Guard → **harter Abbruch** (nie stiller Skip).

**pg_restore-Flags:** `--clean --if-exists --no-owner -U supabase_admin -d postgres`.
Läuft **ohne** `-e`/`--exit-on-error`: Supabase emittiert bekannte nicht-fatale Fehler
(Extensions, Vault, vom Image bereits angelegte Roles). Erfolg wird über Counts bewertet.

**Supabase-Grants-Hook (`restore-supabase-grants.sql`):**
`pg_restore --no-acl` überspringt alle GRANT-Statements aus dem Dump. Bei Supabase-DBs
ist das fatal: `supabase_auth_admin` verliert Ownership auf `auth`-Tabellen, `anon` /
`authenticated` / `service_role` verlieren USAGE auf den App-Schemas. Symptome auf dem
live-VPS: Login schlägt mit HTTP 500 fehl (`Database error querying schema`), REST antwortet
mit `permission denied for schema rapt` (oder `aibrewgenius`).

`restore.sh` führt deshalb nach `pg_restore` + TimescaleDB-`post_restore()` automatisch
`scripts/restore-supabase-grants.sql` aus — via `docker cp` + `docker exec psql -f`.
Guard: nur wenn das `auth`-Schema in der DB existiert (= Supabase-DB). Die SQL ist
**idempotent** (GRANT überschreibt; DO-Blöcke prüfen pg_namespace/pg_tables; kein CONFLICT
möglich) und kann beliebig oft wiederholt werden. Bei Fehler: harter Abbruch — ein Restore
ohne korrekte Grants ist nicht vertrauenswürdig.

`restore-supabase-grants.sql` setzt `ALTER DEFAULT PRIVILEGES` in **zwei Varianten** pro
Schema: einmal für Objekte, die als `supabase_admin` angelegt werden (direkte SQL-Ausführung
via psql), und einmal für Objekte, die als `postgres` angelegt werden (Migrations-Toolchains
wie `db-migrate`, `flyway` oder `psql -U postgres` laufen typischerweise als `postgres`).
Fehlt die `postgres`-Variante, bekommen Tabellen aus zukünftigen Migrations kein Auto-GRANT
zu `authenticated`/`anon` — derselbe Bug, nur eine Migration verzögert.

**Nach dem Restore gibt `restore.sh` Tabellen-Counts aus:**
- `db-assistent`: `auth.users`, `aibrewgenius.recipes`
- `db-rapt`: `auth.users`, `rapt.brew_sessions`, `rapt.telemetry_controllers`,
  `rapt.telemetry_hydrometers` (0-Count auf `telemetry_*` = Indikator für kaputte
  TimescaleDB-Chunk-Verknüpfung)
- `all`: beide Blöcke

---

## 9. Bootstrap-Integration

- `scripts/backup.sh` + `scripts/restore.sh` sind eigenständige Scripts; `bootstrap.sh`
  ruft sie auf, schreibt sie aber nicht.
- **Marker-Registry** `/etc/brewing/stateful-units.d/` — leere Touch-Dateien, eine pro
  installierter stateful Unit. Owner `alex`, mode 755. `backup.sh` liest die Marker beim
  Start; kein Marker → No-op, Exit 0.
  - **Zwei Marker (Phase 4):** `db-assistent` und `db-rapt` — unabhängig.
  - **Backfill (selbstheilend):** `run_base_bootstrap` legt die Marker idempotent an, falls
    `db-assistent` / `db-rapt` zum Zeitpunkt des Bootstrap-Laufs bereits laufen.
  - **Install-Unit-Pfad:** `action_select_and_start` (Menü-Option 1) setzt den jeweiligen
    Marker nach erfolgreichem `docker compose up` via `_ensure_db_marker db-assistent` /
    `_ensure_db_marker db-rapt`.
- **Cron** (nightly ~03:00) — `/etc/cron.d/brewing-backup`:
  ```
  0 3 * * * alex /home/alex/webPage_infra/scripts/backup.sh >> /var/log/brewing-backup.log 2>&1
  ```
  Läuft als `alex` — kein sudo. Auf einem stateless-only VPS (kein Marker) ein sauberer No-op.
- **Passphrase-Datei** `/etc/brewing/gpg.pass` (mode 600, owner `alex`).
- **Backup-Log:** `/var/log/brewing-backup.log` (owner `alex`).
  ```
  tail -f /var/log/brewing-backup.log
  ```
- **Restore bleibt aus bootstrap raus** — immer manuell, niemals automatisch.

---

## 10. Bekannte Limitierungen / offene Punkte

### L1 — Backup nicht remote-fähig

`backup.sh` sichert ausschließlich den **lokalen** DB-Container via `docker exec`.
Will man die DB von einem anderen VPS aus sichern, geht das nur per SSH auf den DB-VPS
(genau das macht der Migrations-Flow in Schritt a).

### L2 — Konsistenz-Fenster: durch unabhängige Single-Snapshots pro DB eliminiert

Jeder `pg_dump -Fc` läuft in **einer serialisierbaren Snapshot-Transaktion** — kein
Cross-Dump-FK-Inkonsistenz-Risiko (die DBs sind seit Phase 4 getrennt; kein Cross-DB-FK).

### L3 — TimescaleDB-Live-Restore-Gate (offenes Prod-Gate)

Ein verifizierter Restore-Round-Trip mit live Hypertable-Daten (`telemetry_*` Count > 0)
ist **manuell auf einem Prod-ähnlichen db-rapt** durchzuführen. Lokal nicht testbar wenn
kein TimescaleDB mit Telemetrie-Daten im Dev-Stack. **MANDATORY Prod-Rollout-Gate.**

### L4 — Restore-Test nicht automatisiert

Ein verifizierter Round-Trip (Login + Query pro Schema) ist **manuell** durchzuführen.
Verifikations-Runbook:
1. `restore.sh` gibt Tabellen-Counts aus — prüfen.
2. Manueller Smoke-Check: Login + Query auf `aibrewgenius.*` und `rapt.*`.
3. Bekannte nicht-fatale pg_restore-Fehler: Extensions, Vault-Objekte, vom Image
   vorher angelegte Rollen — normal, kein Anzeichen eines fehlgeschlagenen Restores.

### Sicherheits-Hinweis: Secrets im Dump

RAPT- und Brewfather-Keys liegen **verschlüsselt** in `vault.secrets` (pgsodium).
Der `db-rapt`-Dump enthält diese nur in verschlüsselter Form, zusätzlich GPG-umhüllt.
**Kein Klartext-Key im Dump.**
