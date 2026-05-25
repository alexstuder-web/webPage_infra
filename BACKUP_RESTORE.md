# Backup & Restore — Betriebs- und Konzeptdoku

> **Status:** Implementiert + lokal getestet (Variante A; keep-N=7 lokal+R2; cron als `alex`).
> `scripts/backup.sh` / `restore.sh` / `bootstrap.sh` fertig; Round-Trip, Retention und
> echter R2-Upload gegen Wegwerf-Stack verifiziert. Multi-VPS Phase 1 + Phase 2 committed.
> **Noch offen:** Smoke-Test auf echtem zweiten VPS; echter 2-VPS-Migrations-Round-Trip noch
> nicht live durchgeführt.

> Architektur-Hintergrund (4 verschiebbare Einheiten, Cloudflare-Tunnel, `proxy_sync`):
> → **[MULTIVPS_ARCHITEKTUR.md](MULTIVPS_ARCHITEKTUR.md)** — nicht hier dupliziert.

---

## 1. Was wird gesichert — und was nicht

Echter, nicht-reproduzierbarer State existiert an **einer** Stelle: dem zentralen
Supabase-Postgres in diesem Repo. Alles andere ist stateless.

| Repo | Backup | Restore | Begründung |
|---|---|---|---|
| `WebPageAlexStuder-new` (Nginx static) | ❌ | ❌ | Build-Artefakt → Git + Docker-Hub-Image. |
| `brew_assistent-new` (Flutter Web) | ❌ App / ✅ Daten | ❌ App / ✅ Daten | Daten in Postgres-Schema `aibrewgenius.*` **+ shared `auth`**. |
| `RAPT_Brewing_Dashboard-new` (Flutter Web) | ❌ App / ✅ Daten | ❌ App / ✅ Daten | Daten in Schema `rapt.*` **+ shared `auth`**. |
| `brew-proxy-new` (Node) | ❌ | ❌ | Stateless. `db-sync.js` schreibt nur nach Postgres. |
| `webPage_infra` | ✅ | ✅ | **Hier läuft Backup/Restore.** |

**Wichtig:** Beide Apps teilen sich **eine** Postgres-DB, und `auth` (User-Logins) ist
**gemeinsam** — `aibrewgenius.*` und `rapt.*` referenzieren beide `auth.users`
(RLS via `auth.uid()`). Deshalb gibt es neben den App-Schemas einen geteilten
`_supabase_core`-Anteil (auth, storage, public, \_realtime, …).

`supabase-storage-data` Volume ist aktuell ungenutzt (keine Upload-Calls in den Apps) —
wird vorsorglich im `_supabase_core`-Anteil mitberücksichtigt (cron-Stand).

---

## 2. Entscheidungen (abgenommen)

| Punkt | Entscheidung |
|---|---|
| Dump-Granularität | **Variante A — pro App getrennt.** Je ein `pg_dump -Fc` pro App-Schema + ein `_supabase_core`-Dump (alles außer den App-Schemas). |
| Konsistenz | Die 3 Dumps laufen **back-to-back** (kein gemeinsamer Snapshot). Das winzige Cross-Dump-Inkonsistenz-Fenster ist akzeptiert + dokumentiert (→ L2). |
| Format / Verschlüsselung | `pg_dump -Fc` → GPG **symmetrisch** AES-256, **gleiche Passphrase wie `.env.gpg`**. |
| Trigger | **cron**, nightly ~03:00, unbeaufsichtigt. Passphrase aus `/etc/brewing/gpg.pass` (mode 600, owner `alex`). |
| Off-site | **Cloudflare R2**, Bucket **`backup`**, ein Ordner pro App/Service. |
| R2-Token | Aktuell: **account-weiter R2-Token** in Gebrauch (`.env`-Vars: `R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`). Ein dedizierter, auf Bucket `backup` gescopter Token (Object Read & Write) ist **optional und empfohlen** — kein Blocker. Token-Setup: Cloudflare Dashboard → R2 → „Manage R2 API Tokens". |
| Lokale Ablage | `webPage_infra/backups/` (gitignored), gespiegelte Ordnerstruktur. |
| Restore | **immer manuell**, nicht Teil von bootstrap. Reihenfolge: `_supabase_core` zuerst, dann App-Schemas. |

### Bucket-Layout
```
backup/                         (R2-Bucket)
├── _supabase_core/             auth + storage + public + _realtime + Rest
│   └── core_<TS>.fc.gpg
├── brew_assistent/             Schema aibrewgenius
│   └── aibrewgenius_<TS>.fc.gpg
├── rapt_dashboard/             Schema rapt
│   └── rapt_<TS>.fc.gpg
└── <future_unit>/ …            erweiterbar pro neuem stateful Service
```

---

## 3. Backup-Flow (`scripts/backup.sh`)

### Marker-gesteuerte Job-Ableitung

`backup.sh` leitet die Dump-Jobs **nicht** aus hartkodierter Logik ab, sondern aus den
in `/etc/brewing/stateful-units.d/` installierten Markern (leere Touch-Dateien, eine
pro stateful Unit). Ist kein Marker vorhanden, beendet sich `backup.sh` mit Exit 0 ohne
irgendeinen Container zu berühren — **sauberer No-op**.

Heute gibt es genau eine stateful Unit: `supabase`. Ihr Marker-Dateiname ist
`/etc/brewing/stateful-units.d/supabase`; er erzeugt die drei Dumps für core +
aibrewgenius + rapt. Künftige stateful Units (z.B. ein selbst-gehosteter Mailserver)
erhalten einen eigenen Marker und einen neuen Zweig in der `unit_jobs()`-Funktion in
`backup.sh`.

Der Cron-Drop-in (`/etc/cron.d/brewing-backup`) wird auf **jedem** VPS bedingungslos
von `bootstrap.sh` angelegt. Die Scoping-Intelligenz sitzt in der markergesteuerten
Job-Ableitung, nicht in der Cron-Konfiguration. Auf einem stateless-only VPS (z.B. ein
reiner Frontend-VPS ohne `supabase-db`) ist der nächtliche Lauf damit ein garantierter
No-op — kein Fehler, kein Alarm.

### Dump-Ablauf (bei installiertem `supabase`-Marker)

**Wo läuft der Backup?** Lokal auf dem DB-VPS: `backup.sh` ruft
`docker exec supabase-db pg_dump -Fc -U supabase_admin -d postgres` gegen den lokalen
Container auf. Es gibt keinen „Backup über den Tunnel" — der Cloudflare-TCP-Tunnel
(`db-tcp.<domain>`) ist für den **Proxy** (`DATABASE_URL`, Rolle `proxy_sync`), nicht
fürs Backup. Will man die DB von einem anderen VPS aus sichern, geht das nur per SSH auf
den DB-VPS (genau das macht der Migrations-Flow — → [Abschnitt 6](#6-restore-szenario-2-migration--vps-umzug-bootstrapsh---menu-option-2)).

```
Drei Dumps back-to-back auf dem DB-VPS (Sekundenabstand):
   ├─ docker exec supabase-db pg_dump -Fc -U supabase_admin -d postgres
   │     --exclude-schema=aibrewgenius --exclude-schema=rapt
   │     | gpg --batch --symmetric AES256 --passphrase-file /etc/brewing/gpg.pass
   │     → backups/_supabase_core/core_<TS>.fc.gpg              → R2 _supabase_core/
   │
   ├─ docker exec supabase-db pg_dump -Fc -U supabase_admin -d postgres
   │     -n aibrewgenius
   │     | gpg ...
   │     → backups/brew_assistent/aibrewgenius_<TS>.fc.gpg      → R2 brew_assistent/
   │
   └─ docker exec supabase-db pg_dump -Fc -U supabase_admin -d postgres
         -n rapt
         | gpg ...
         → backups/rapt_dashboard/rapt_<TS>.fc.gpg              → R2 rapt_dashboard/
```

- **Kein Klartext auf Platte:** jeder Dump streamt direkt durch `gpg -o <out>` — die
  `.fc.gpg`-Datei ist das Endprodukt; ein Klartext-Dump landet nie auf Disk.
- `PGPASSWORD` wird als `-e`-Env an `docker exec` übergeben (nicht in der Host-argv).
- GPG-Passphrase via `--passphrase-file /etc/brewing/gpg.pass` (mode 600, owner `alex`).
  Alternativen: `$GPG_PASSPHRASE`-Env oder interaktiver Prompt. Passphrase nie auf der
  Kommandozeile (`ps`-sichtbar).
- **`--label <name>`-Flag:** hängt `_<name>` an den Dateinamen an (z.B. `pre-migration`).
  Gelabelte Dumps sind **rotation-exempt** — sie zählen nicht zur N-Retention und werden
  nicht automatisch gelöscht.
- **`--no-upload`-Flag:** sichert nur lokal, kein R2-Upload.
- **Retention** pro Ordner: neueste `N` automatische Dumps behalten (lokal UND R2),
  Rest gelöscht. `N` via `BACKUP_KEEP` (default 7). Gelabelte Dumps exempt.
- **R2-Upload + Prune** via `rclone`; Creds als `RCLONE_CONFIG_R2_*`-Env-Vars (nie in
  argv). Nach Upload prunet `backup.sh` den R2-Ordner selbst auf die neuesten N.
  Falls `R2_ACCESS_KEY_ID` nicht gesetzt ist, wird der Upload übersprungen (nur lokal).
- **Konsistenz:** die 3 Läufe sind keine atomare Cross-Schema-Momentaufnahme; das
  Sekunden-Fenster ist akzeptiert (Hobby-Stack, nightly 03:00, praktisch keine Schreiblast).
  → Bekannte Limitierung [L2](#l2--kein-write-freeze-während-des-nightly-backups).

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

## 5. Initialer R2-Seed (einmaliger Vorgang — bereits erledigt, 2026-05-25)

Der erste R2-Backup-Stand wurde am 2026-05-25 vom lokalen Dev-Stack (Volume
`webpage_infra_supabase-db-data`, 2 auth.users, Schemas aibrewgenius + rapt mit
Produktiv-Testdaten) erzeugt. Methode: normales `backup.sh` ohne `--label` — kein
dediziertes Seed-Label, damit `latest`-Logik ihn findet.

Verwendete Dateinamen (als Referenz):
- `_supabase_core/core_20260525_074013.fc.gpg` (4.5 MB)
- `brew_assistent/aibrewgenius_20260525_074013.fc.gpg` (416 KB)
- `rapt_dashboard/rapt_20260525_074013.fc.gpg` (12 KB)

Dieser Stand ist der Ausgangspunkt für Erst-Bootstraps neuer VPS via Menü-Option 3
(→ [§5a](#5a-restore-szenario-1a-erstlauf-auf-frischem-vps-bootstrap-menu-option-3)).
Künftige nightly Backups ersetzen diesen Stand (Retention N=7, rotation-exempt nur bei
`--label`).

---

## 5a. Restore-Szenario 1a: Erstlauf auf frischem VPS (`bootstrap.sh --menu`, Option 3)

**Situation:** Ein frischer VPS soll NICHT mit einer leeren Datenbank starten, sondern
den letzten Stand aus R2 laden — **ohne** SSH-Zugang zu einem alten VPS. Deckt zwei Fälle ab:
(1) **Erst-Lauf** (es gab noch nie einen VPS) und (2) **Disaster Recovery** (alter VPS tot/weg,
also kein Migrations-Umzug möglich). Die Migration (Option 2) braucht einen LAUFENDEN alten VPS
und hilft in beiden Fällen nicht — dafür ist genau dieser Pfad da.

**Voraussetzung:** R2-Creds in `.env` gesetzt + mindestens ein Backup in R2 vorhanden
(alle drei Ordner: `_supabase_core`, `brew_assistent`, `rapt_dashboard`).

### Ablauf

1. **Bootstrap auf dem neuen VPS (vollständig durchlaufen lassen):**
   ```
   curl -fsSL https://raw.githubusercontent.com/alexstuder-web/webPage_infra/main/scripts/bootstrap.sh \
     -o bootstrap.sh && chmod +x bootstrap.sh && sudo bash bootstrap.sh
   ```
   Der Bootstrap installiert alle Tools, clont das Repo, entschlüsselt `.env` (GPG-Passphrase
   aus Bitwarden), schreibt `/etc/brewing/gpg.pass` und startet den nightly Cron.

2. **Menü-Option 1 — Apps & Supabase starten (optional):**
   `bootstrap.sh --menu` → Option 1 → `brew_assistent + Supabase` auswählen.
   Supabase-DB initialisiert sich mit frischen Rollen/Schemas. Supabase-Marker wird gesetzt.
   **Dieser Schritt ist optional** — `action_restore_from_r2` (Option 3) startet Supabase
   selbst hoch, falls es noch nicht läuft (idempotente Hochzieh-Logik).

3. **Menü-Option 3 — Erstdaten aus R2 restoren:**
   ```
   sudo bash ~/webPage_infra/scripts/bootstrap.sh --menu
   # → Option 3: Erstdaten aus R2 wiederherstellen (latest, destruktiv)
   ```

   `action_restore_from_r2()` führt folgende Schritte durch:
   - Vorbedingungen prüfen (`.env`, docker, rclone, gpg, R2-Vars).
   - Supabase hochziehen falls nicht laufend (idempotent).
   - Supabase-Marker setzen (idempotent via `_ensure_supabase_marker`).
   - R2-Verfügbarkeit prüfen: jüngste `*.fc.gpg` je Ordner. Fehlt eine → sauberer
     Skip mit Hinweis, kein Abbruch des Bootstraps.
   - Überschreib-Schutz: `SELECT count(*) FROM auth.users` — wenn > 0: Warnung +
     explizite Bestätigung `force-restore` erforderlich. Im Nicht-TTY-Modus: Abbruch.
   - Tippe-`restore`-Prompt (TTY-Pflicht).
   - `./scripts/restore.sh all latest --yes` — zwingende Reihenfolge:
     `core` → `brew_assistent` → `rapt_dashboard`.
   - Tabellen-Counts nach Restore: `auth.users`, `aibrewgenius.recipes`, `rapt.brew_sessions`.
   - `cf_reconcile_if_token` (Cloudflare-Routing).

4. **Smoke-Check:** Login in der App + je eine Query auf `aibrewgenius.*` und `rapt.*`.

### Sicherheits-Guards

| Guard | Verhalten |
|---|---|
| Leerer Bucket / fehlendes `*.fc.gpg` in ≥1 Ordner | Sauberer Skip + Hinweis, Exit 0. Stack läuft mit frischer DB weiter. |
| `auth.users > 0` auf Ziel-VPS | Warnung + `force-restore`-Eingabe nötig. |
| Kein TTY | Abbruch (kein Blind-Restore). |
| R2-Vars fehlen in `.env` | Klarer Hinweis + Return 0 (kein Stacktrace). |
| `ASSUME_YES=1` + DB-Zustand `UNKNOWN` | Harter Abbruch (`return 1`). DB-Health zuerst klären — kein automatisierter destruktiver Restore gegen unbekannten Zustand. |
| `ASSUME_YES=1` + bekannter Zustand (0 oder > 0) + kein TTY | Proceed mit Warnung in stdout — Bestätigung gilt als via Env-Var erteilt. |

### pg_restore-Fehler bei Nicht-Supabase-Image (bekannte Nicht-Fatale)

Beim Restore gegen ein plain postgres-Image (z.B. für isolierte Tests) erscheinen
Fehler zu `timescaledb`, `pg_graphql`, `pgjwt`, `pgsodium`, Vault usw. — diese
Extensions existieren nur im Supabase-Image. Das ist erwartetes Verhalten und kein
Anzeichen eines fehlgeschlagenen Restores. Erfolgskriterium: Tabellen-Counts > 0 am Ende.

### Passphrase-Quelle für Restore

Gleich wie bei manuellem `restore.sh`:
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
   Der Bootstrap installiert Docker, bw CLI, clont das Repo, holt die GPG-Passphrase aus
   Bitwarden (Item `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`), entschlüsselt `.env`, schreibt
   `/etc/brewing/gpg.pass` (mode 600, owner `alex`) und startet den nightly Backup-Cron.

2. **Stack starten (Menü-Option 1 oder selektiv):**
   Der Bootstrap-Menü-Aufruf `docker compose --profile vps up -d` startet alle Container.
   Supabase-DB initialisiert sich beim ersten Start (Rollen, Extensions, Schemas via
   `docker-entrypoint-initdb.d/`). `zz-set-role-passwords.sh` legt `proxy_sync` idempotent an.
   Nach erfolgreichem Start setzt `bootstrap.sh` den `supabase`-Marker idempotent
   (`/etc/brewing/stateful-units.d/supabase`) — ab sofort sind nächtliche Backups aktiv.

3. **Restore ausführen — Reihenfolge ist zwingend (`core` zuerst):**
   ```
   cd ~/webPage_infra
   ./scripts/restore.sh all
   ```
   `all` restauriert in der fixen Reihenfolge: `core` → `brew_assistent` → `rapt_dashboard`.
   `core` muss zuerst kommen, weil beide App-Schemas via FK auf `auth.users` referenzieren.
   `latest` (Default) zieht je den jüngsten `.fc.gpg` aus dem passenden R2-Ordner.

4. **Cloudflare-Routing wiederherstellen:**
   ```
   ./scripts/cloudflare-reconcile.sh
   ```
   (Normalerweise automatisch nach dem Bootstrap-Menü.)

5. **Smoke-Check:** Login in der App + je eine Query auf `aibrewgenius.*` und `rapt.*`
   (→ [L4](#l4--restore-test-nicht-automatisiert): kein automatisches Test-Script; manuell).

### Passphrase-Quelle für Restore

`restore.sh` liest die Passphrase (in dieser Priorität):
1. `/etc/brewing/gpg.pass` (mode 600, owner `alex`) — vorhanden nach Bootstrap.
2. `$GPG_PASSPHRASE`-Env — manuell setzen wenn Datei fehlt:
   ```
   export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"
   ```
3. Interaktiver Prompt (nur mit TTY).

---

## 6. Restore-Szenario 2: Migration / VPS-Umzug (`bootstrap.sh --menu`, Option 2)

**Situation:** Die gesamte Supabase / DB-Unit soll von einem laufenden alten VPS auf
einen neuen VPS verschoben werden.

**Was ist stateful, was nicht:**
- **Supabase (DB)** ist die einzige stateful Unit — sie wird migriert (Backup + Restore).
- **brew_assistent, rapt_dashboard, brew-proxy, WebPageAlexStuder** sind zustandslose
  Apps — sie werden **ohne** Backup/Restore via „Einheiten auswaehlen & starten" (Menü-Option 1)
  auf dem Ziel-VPS neu gestartet. Kein per-App-Migrations-Menü.

**R2 ist das Transportmedium:** der Dump geht alt-VPS → R2 → neu-VPS. Es gibt keine
direkte Postgres-Verbindung zwischen den VPS für den Datentransfer.

**Voraussetzung:** passwortloser SSH-Zugang (BatchMode) vom neuen VPS zum alten. Der
Migrations-Flow prüft das am Anfang und gibt einen Credential-Schritt-Hinweis falls nötig.

### Runbook (orchestriert von `action_migrate_unit` in `bootstrap.sh`)

```
sudo bash ~/webPage_infra/scripts/bootstrap.sh --menu
# Menü → Option 2 (App migrieren)
# → Auswahl: 1) Supabase / DB migrieren
# → SSH-Daten des alten VPS eingeben
```

Die Funktion führt folgende Schritte durch:

#### (a) Backup + R2-Verifikation auf altem VPS (per SSH)

```
ssh <alter VPS>  →  cd ~/webPage_infra && ./scripts/backup.sh --label pre-migration
```

Erstellt auf dem alten VPS alle drei Dumps mit Label `pre-migration` (rotation-exempt)
und lädt sie nach R2. Danach prüft `bootstrap.sh` per SSH + rclone, ob **alle drei**
gelabelten Dumps in R2 vorhanden sind (`_verify_backup_in_r2`). Bei Fehler: Abbruch,
alter Stand bleibt laufend.

#### (b) Supabase-Stack auf altem VPS stoppen + Verifikation

```
ssh <alter VPS>  →  docker compose stop supabase-db supabase-kong … web_assistent web_rapt api_proxy
```

Der **komplette Supabase-Stack** (supabase-db + alle Services + Frontends) wird gestoppt —
nicht nur der Frontend-Container. Ab hier keine neuen Schreibzugriffe mehr.

Direkt danach läuft ein **separater SSH-Verifikations-Call**, der per
`docker inspect --format='{{.State.Running}}' supabase-db` prüft, ob `supabase-db`
tatsächlich gestoppt ist (Zustand `false`) oder gar nicht existiert (`absent`). Schlägt
diese Verifikation fehl (Container läuft noch), bricht `bootstrap.sh` **hart ab**,
bevor Schritt (c) gestartet wird. Volumes und Daten auf dem alten VPS bleiben intakt.

> **Rollback** jederzeit möglich, solange Schritt (d) nicht abgeschlossen ist:
> ```
> ssh <alter VPS>  →  cd ~/webPage_infra && docker compose up -d
> # Marker auf altem VPS wiederherstellen (falls Schritt e bereits gelaufen):
> ssh <alter VPS>  →  touch /etc/brewing/stateful-units.d/supabase
> ```
> Der pre-migration-Dump liegt rotation-exempt in R2.

#### (c) Supabase auf neuem VPS hochziehen

`bootstrap.sh` startet die Supabase-Container auf dem neuen VPS (analog Menü-Option 1:
`docker compose --profile vps up -d web_assistent supabase-kong cloudflared`).
`cf_ensure_tunnel_if_token` läuft vorher (Tunnel-Ensure pro VPS).
Nach erfolgreichem Start: `supabase`-Marker auf neuem VPS idempotent setzen.

#### (d) Alle drei pre-migration-Dumps aus R2 laden + Restore

Die aus Schritt (a) verifizierten Dump-Dateinamen (explizit — nicht `latest`) werden
heruntergeladen und eingespielt:

```
./scripts/restore.sh core         <core_<TS>_pre-migration.fc.gpg>         --yes
./scripts/restore.sh brew_assistent <aibrewgenius_<TS>_pre-migration.fc.gpg> --yes
./scripts/restore.sh rapt_dashboard <rapt_<TS>_pre-migration.fc.gpg>        --yes
```

`core` zuerst (auth.users), dann App-Schemas. `--yes` überspringt die interaktive
Bestätigung (wurde im Menü-Schritt „migrate" bereits eingeholt). Nach dem Restore werden
die lokalen Kopien der Dump-Dateien gelöscht.

#### (e) supabase-Marker auf altem VPS entfernen

```
ssh <alter VPS>  →  rm -f /etc/brewing/stateful-units.d/supabase
```

Ohne Marker ist der nächste nächtliche Cron-Lauf auf dem alten VPS ein sauberer No-op
(Exit 0). Der alte VPS sichert die DB nicht mehr — der neue VPS mit gesetztem Marker
übernimmt das Backup ab dem nächsten Cron-Lauf.

#### (f) supabase-Marker auf neuem VPS sicherstellen

Idempotenter Check — Marker wurde bereits in Schritt (c) gesetzt; dieser Schritt
stellt sicher, dass er auch nach einem Restore noch vorhanden ist.

### Supabase-Core-Überschreib-Schutz

Vor dem Start der Migration (vor Schritt a) prüft `bootstrap.sh` per
`SELECT count(*) FROM auth.users` auf dem **neuen VPS**, ob dort bereits Nutzer existieren.
Bei Fund: Abbruch mit Warnung. Explizite Eingabe `force-core` ist nötig um fortzufahren.
Im Normalfall (dedizierter Migrations-VPS, frische DB) läuft dieser Check durch.

### Post-Migrations-Pflichten (manuell)

Nach erfolgreicher Migration sind folgende manuelle Schritte nötig:

1. **Zustandslose Apps auf neuem VPS starten:**
   `bootstrap.sh --menu` → Option 1 (Einheiten auswaehlen & starten) für die gewünschten Apps:
   brew_assistent, rapt_dashboard, brew-proxy, WebPageAlexStuder.
   Kein Backup/Restore nötig — Apps sind stateless.

2. **Apps auf altem VPS stoppen:**
   ```
   ssh <alter VPS>  →  docker compose stop web_assistent web_rapt web_hauptseite
   ```

3. **Cloudflare-Routing auf altem VPS bereinigen:**
   Auf dem alten VPS den migrierten Hostname aus `scripts/cloudflare-routes.json` entfernen
   und `./scripts/cloudflare-reconcile.sh` ausführen. Sonst konkurrierende Tunnel-Ingress-
   Einträge (beide Tunnel antworten auf denselben Hostname).

4. **`RAPT_DASHBOARD_URL` anpassen** (nur bei RAPT-Migration):
   In `brew_assistent/.env` `RAPT_DASHBOARD_URL` auf die neue URL setzen, dann
   `.env.gpg` neu verschlüsseln:
   ```
   ./scripts/encrypt-env.sh
   ```
   Credential-Schritt: `ALEXSTUDER_WEBPAGE_GPG_PASSWORD` aus Bitwarden holen.

5. **`DATABASE_URL` anpassen** wenn `api_proxy` auf einem anderen VPS als die DB läuft
   (Cross-VPS-Proxy, V-10):
   ```
   DATABASE_URL=postgres://proxy_sync:<PROXY_SYNC_PASSWORD>@host.docker.internal:15432/postgres?sslmode=disable
   ```
   Port 15432 = `cloudflared access tcp`-Client (→ `docker-compose.tunnel-tcp.yml`).
   `PROXY_SYNC_PASSWORD` ist eine dedizierte Var — nicht `POSTGRES_PASSWORD`.
   Dann `.env.gpg` neu verschlüsseln (`encrypt-env.sh`, Credential-Schritt).

---

## 7. Pre-Migration-Checkliste: Rollen & Grants

Diese Punkte sind **verbindliche Vorbedingungen** bevor eine Migration durchgeführt wird.
Es sind keine manuellen Schritte, sondern Checks, dass das System korrekt aufgesetzt ist.

### `proxy_sync`-Rolle

- `proxy_sync` wird auf dem **Ziel-VPS** beim ersten DB-Start automatisch durch
  `supabase/db_init/zz-set-role-passwords.sh` angelegt (idempotent via `DO $$ IF NOT EXISTS`).
  Rollen-Attribute spiegeln Migration `004_proxy_role.sql` (Phase 1 dba-coder):
  `LOGIN NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS INHERIT`.
- **Kein manueller Schritt** für die Rollen-Anlage — aber dieser Mechanismus muss
  funktionieren (d.h. der Container muss seinen Init einmal komplett durchgelaufen sein).

### `PROXY_SYNC_PASSWORD` in `.env`

- `PROXY_SYNC_PASSWORD` muss in `.env` gesetzt sein (eigenes Secret, **≠ `POSTGRES_PASSWORD`**).
- `zz-set-role-passwords.sh` prüft beim Start `[[ -n "${PROXY_SYNC_PASSWORD:-}" ]]` und
  bricht hart ab, falls leer. Der `supabase-db`-Container startet dann nicht.
- Der Wert landet in `docker-compose.yml` im `environment:`-Block von `supabase-db`
  (Lesson 2026-05-24).

### Grants kommen via Restore, nicht via Init-Script

`pg_dump` erfasst keine Postgres-Rollen — nur Objekte. Die **Tabellen-Grants** für
`proxy_sync` (SELECT auf `rapt.*`-Tabellen, Migration `005_proxy_grants.sql`) stecken
im **rapt-Dump**, nicht im Init-Script.

**Konsequenz:** Die Restore-Quelle muss ein Dump sein, der **nach den Migrationen
004/005** erstellt wurde. Ein älterer Dump (vor 004/005) führt nach dem Restore zu
fehlenden Grants — `proxy_sync` kann nicht lesen, `api_proxy` schlägt mit
Berechtigungsfehlern fehl.

**Vorbedingung vor einer Migration prüfen:** den letzten automatischen Dump auf Datum
gegen das Datum der Migrationen 004/005 abgleichen. Falls unsicher: manuell ein frisches
Backup erstellen:
```
./scripts/backup.sh --label post-004-005
```

---

## 8. Restore-Details (`scripts/restore.sh`)

Das Supabase-Image legt beim ersten Start `auth`, `storage`, `_realtime`, Extensions
und Roles selbst an → ein roher Full-Restore kollidiert mit diesen vorhandenen Objekten.
`pg_restore --clean --if-exists` löst das: Objekte werden vor dem Neuanlegen gedroppt,
falls vorhanden.

**Aufruf:**
```
restore.sh <core|brew_assistent|rapt_dashboard|all> [datei|latest] [--yes]
```
- `latest` (Default): zieht den jüngsten `.fc.gpg` aus dem passenden R2-Ordner.
- `<pfad>`: lokale `.fc.gpg`-Datei (z.B. ein explizit heruntergeladener pre-migration-Dump).
- `--yes`: überspringt die interaktive Bestätigung (für Automatisierung / Migrations-Flow).

**Reihenfolge bei `all` ist zwingend:**
```
1. core               → _supabase_core  (auth muss zuerst da sein)
2. brew_assistent     → aibrewgenius
3. rapt_dashboard     → rapt
```

**pg_restore-Flags:** `--clean --if-exists --no-owner -U supabase_admin -d postgres`.
Läuft **ohne** `-e`/`--exit-on-error`: Supabase emittiert bekannte nicht-fatale Fehler
(supabase_realtime-Publication, `extensions`-Schema, `pgsodium`/Vault, vom Image bereits
angelegte Roles). Erfolg wird über Tabellen-Counts/Smoke-Check bewertet, nicht über den
Exit-Code.

**Nach dem Restore:** `restore.sh` gibt Tabellen-Counts aus:
- `auth.users` (core)
- `aibrewgenius.recipes` (brew_assistent)
- `rapt.brew_sessions` (rapt_dashboard)

---

## 9. Bootstrap-Integration

- `scripts/backup.sh` + `scripts/restore.sh` sind eigenständige Scripts; `bootstrap.sh`
  ruft sie auf, schreibt sie aber nicht.
- **Marker-Registry** `/etc/brewing/stateful-units.d/` — leere Touch-Dateien, eine pro
  installierter stateful Unit. Owner `alex`, mode 755. `backup.sh` liest die Marker beim
  Start; kein Marker → No-op, Exit 0.
  - **Backfill (selbstheilend):** `run_base_bootstrap` legt den `supabase`-Marker
    idempotent an, falls `supabase-db` zum Zeitpunkt des Bootstrap-Laufs bereits läuft.
    Für VPS, die vor der Marker-Einführung gebootstrapped wurden (kein Marker vorhanden,
    DB läuft aber schon), heilt der nächste `bootstrap.sh`-Lauf den fehlenden Marker.
  - **Install-Unit-Pfad:** `action_select_and_start` (Menü-Option 1) setzt den
    `supabase`-Marker nach erfolgreichem `docker compose up` via `_ensure_supabase_marker`
    (gegated auf laufenden `supabase-db`-Container).
- **Cron** (nightly ~03:00) — `/etc/cron.d/brewing-backup`:
  ```
  0 3 * * * alex /home/alex/webPage_infra/scripts/backup.sh >> /var/log/brewing-backup.log 2>&1
  ```
  Läuft als `alex` (Mitglied der `docker`-Gruppe, owner von Repo und `gpg.pass`) — kein
  sudo. Bootstrap schreibt den Drop-in idempotent bei jedem Lauf — auf **jedem** VPS,
  unabhängig davon ob Marker gesetzt sind. Der Cron-Lauf ist auf einem stateless-only VPS
  (kein Marker) ein sauberer No-op (Exit 0).
- **Passphrase-Datei** `/etc/brewing/gpg.pass` (mode 600, owner `alex`) — Bootstrap holt
  sie einmalig aus Bitwarden (Item `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`) und schreibt sie.
  Bei nightly Cron kein interaktiver Prompt.
- **Backup-Log:** `/var/log/brewing-backup.log` (owner `alex`).
  ```
  tail -f /var/log/brewing-backup.log
  ```
- **Restore bleibt aus bootstrap raus** — immer manuell, niemals automatisch.
- **rclone** wird durch Bootstrap installiert; R2-Creds aus `.env`.

---

## 10. Bekannte Limitierungen / offene Punkte

### L1 — Backup nicht remote-fähig

`backup.sh` sichert ausschließlich den **lokalen** `supabase-db`-Container via `docker exec`.
Will man die DB von einem VPS aus sichern, der die DB **nicht** lokal hält, geht das
heute nur per SSH auf den DB-VPS (genau das macht der Migrations-Flow in Schritt a).
Es gibt **kein** „Backup über den db-tcp-Tunnel" (der TCP-Tunnel ist für `proxy_sync` /
`api_proxy`, nicht für Backup).

### L2 — Kein Write-Freeze während des nightly Backups

Die drei Dumps laufen back-to-back ohne gemeinsamen Snapshot/Quiesce. Das
Sekunden-Inkonsistenz-Fenster ist akzeptiert (Hobby-Stack, nightly 03:00, praktisch
keine Schreiblast).

**Bei einer Migration** ist das Bild anders: `backup.sh --label pre-migration` läuft in
Schritt (a), während `supabase-db` noch läuft. Direkt danach (Schritt b) stoppt der
Migrations-Flow den **kompletten Supabase-Stack** und verifiziert per separatem
SSH-Call, dass `supabase-db` tatsächlich nicht mehr läuft — ein harter Abbruch erfolgt,
wenn der Container noch oben ist. Erst nach dieser Verifikation beginnt Schritt (c).

Das bedeutet: das pre-migration-Backup selbst hat kein Write-Freeze, aber der Stop
passiert **vor** dem Restore (nicht danach) und wird **hard verifiziert**. Das verbleibende
Risiko ist das winzige Inkonsistenz-Fenster *innerhalb* des Backups selbst (drei
Dumps back-to-back, Sekunden) — identisch mit dem nightly-Risiko und als akzeptiert
dokumentiert.

### L4 — Restore-Test nicht automatisiert

Ein verifizierter Restore-Round-Trip (Login + je eine Query pro Schema) ist **manuell**
durchzuführen. Es gibt kein Self-Test-Script. Das Verifikations-Runbook:

1. `restore.sh` gibt nach dem Restore Tabellen-Counts aus — diese prüfen.
2. Manueller Smoke-Check: Login in der App + je eine Query auf `aibrewgenius.*` und `rapt.*`.
3. Bekannte nicht-fatale pg_restore-Fehler: `supabase_realtime`-Publication, `extensions`-
   Schema, `pgsodium`/Vault-Objekte, vom Image vorher angelegte Rollen. Diese sind normal
   und kein Anzeichen eines fehlgeschlagenen Restores.

### Sicherheits-Hinweis: `rapt_api_key` Plaintext im Dump

`rapt.user_profiles.rapt_api_key` liegt im `rapt`-Schema heute im Klartext.
Der `rapt`-Dump enthält diesen Wert damit als Klartext (nur GPG-äußerlich verschlüsselt
im `.fc.gpg`). Dies ist ein **bekanntes, separat zu behandelndes Sicherheitsrisiko**
(Vault-Migration des `rapt`-Schemas) und ist **nicht** Teil dieses Doc-Updates oder des
Backup/Restore-Scope.
