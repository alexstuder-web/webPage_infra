# webPage_infra

**Single source of truth** für das gesamte Brewing-Ökosystem auf einem VPS.
Alle Anwendungen kommen als **fertige Container-Images** aus Docker Hub —
dieses Repo enthält nur Compose-Files, Configs und Bootstrap.

## Bootstrap auf frischem Ubuntu-VPS

```bash
curl -fsSL https://raw.githubusercontent.com/alexstuder-web/webPage_infra/main/scripts/bootstrap.sh \
  -o bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh
```

Drei interaktive Eingaben:

1. Bitwarden E-Mail
2. Bitwarden Master-Passwort *(holt die GPG-Passphrase aus Item
   `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`)*
3. Passwort für neuen Linux-User `alex`

Was passiert automatisch: `apt upgrade` → User `alex` + Docker installieren →
Bitwarden CLI → Repo nach `/home/alex/webPage_infra` clonen → `.env`
entschlüsseln → `docker compose --profile vps up -d`.

**Threat-Model-Hinweis:** `bootstrap.sh` wird per `curl -fsSL` aus dem privaten
GitHub-Org-Repo geladen und direkt ausgeführt — ohne gesonderte Checksum-Verifikation.
Das Sicherheitsmodell lautet "trust your own repo": wer schreibenden Zugriff auf
`alexstuder-web/webPage_infra` oder den DNS-Namen `raw.githubusercontent.com` kontrolliert,
kann beliebigen Code als root einschleusen. Mitigations: Org-Repo ist privat,
GitHub-Account mit 2FA gesichert, Bitwarden-Session und GPG-Passphrase werden erst nach
der Skript-Ausführung abgerufen und landen nicht im Skript selbst.

## Enthaltene Services

| Container | Image | Updates |
|---|---|---|
| `web-hauptseite` | `${DOCKERHUB_USERNAME}/web_hauptseite:latest` | Watchtower (`:latest`) |
| `web-assistent` | `${DOCKERHUB_USERNAME}/web_assistent:latest` | Watchtower (`:latest`) |
| `web-rapt` | `${DOCKERHUB_USERNAME}/web_rapt:latest` | Watchtower (`:latest`) |
| `api-proxy` | `${DOCKERHUB_USERNAME}/brew_proxy:latest` | Watchtower (`:latest`) |
| `supabase-db` | `supabase/postgres:15.8.1.060` | manuell (gepinnt) |
| `supabase-auth` | `supabase/gotrue:v2.176.1` | manuell (gepinnt) |
| `supabase-rest` | `postgrest/postgrest:v12.2.10` | manuell (gepinnt) |
| `supabase-realtime` | `supabase/realtime:v2.34.43` | manuell (gepinnt) |
| `supabase-storage` | `supabase/storage-api:v1.13.3` | manuell (gepinnt) |
| `supabase-meta` | `supabase/postgres-meta:v0.96.3` | manuell (gepinnt) |
| `supabase-studio` | `supabase/studio:2026.04.27-sha-5f60601` | manuell (gepinnt) |
| `supabase-kong` | `kong:2.8.1` | manuell (gepinnt) |
| `cloudflared` | `cloudflare/cloudflared:2026.5.0` | manuell (gepinnt) |
| `watchtower` | `containrrr/watchtower:latest` | self-update |

App-Container haben das Label `com.centurylinklabs.watchtower.enable=true` →
Watchtower zieht alle 5 Min neue `:latest` Images. Supabase bleibt gepinnt,
Updates nur über bewusstes Anheben der Image-Tags + Re-deploy.

## Secrets — `.env.gpg`

Alle Secrets liegen verschlüsselt als `.env.gpg` im Repo (AES-256, symmetrisch).
Die GPG-Passphrase steckt in **Bitwarden** unter
Item `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`.

### Secret hinzufügen / ändern

```bash
export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"
./scripts/decrypt-env.sh        # .env.gpg → .env
$EDITOR .env                    # Wert ändern
./scripts/encrypt-env.sh        # .env → .env.gpg
git add .env.gpg && git commit -m "update env" && git push
```

Auf dem VPS: `git pull && ./scripts/decrypt-env.sh && docker compose --profile vps up -d`.

**Niemals** die unverschlüsselte `.env` committen — `.gitignore` blockt das.

## Lokales Dev-Setup

```bash
# .env zuerst entschlüsseln (siehe oben)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

Dev-Override aktiviert Localhost-Ports (`:8081` web_assistent, `:8082` web_rapt,
`:8090` web_hauptseite, `:8083` api_proxy, `:54321` kong, `:54322` postgres,
`:54323` studio). `cloudflared` + `watchtower` laufen lokal **nicht** (sind
hinter `profiles: [vps]`).

## Cloudflare Tunnel + DNS  (pro VPS dynamisch, idempotent via API)

### Pro-VPS-Tunnel-Modell

Jeder VPS bekommt beim Bootstrap **automatisch seinen eigenen Cloudflare-Tunnel**
(angelegt per API, Name `brewing-<sanitisierter-hostname>`, idempotent). Der
`cloudflared`-Container läuft mit dem VPS-eigenen Connector-Token; jeder VPS
routet nur die Hostnames, deren Ziel-Container **auf ihm tatsächlich laufen**.

Reihenfolge beim Bootstrap:
1. **Tunnel-Ensure** (`cf_ensure_tunnel_if_token`): sucht `brewing-<hostname>` in der
   CF-Account-Tunnel-Liste → ID + Token holen oder neuen Tunnel anlegen.
   Token und ID werden in die **lokale `.env`** geschrieben (nie in `.env.gpg`).
2. **Container starten** (`docker compose --profile vps up -d … cloudflared`):
   `cloudflared` liest `TUNNEL_TOKEN` aus `.env` — ist der Token neu, wird der
   Container beim `up -d` recreated.
3. **Reconcile** (`cf_reconcile_if_token`): gleicht Tunnel-Ingress + DNS-CNAMEs
   gegen die laufenden Container ab. Nicht laufende Ziel-Container werden
   übersprungen (kein Hostname auf diesem VPS beansprucht).

Routing-Map liegt deklarativ in [`scripts/cloudflare-routes.json`](scripts/cloudflare-routes.json):

| Hostname | Container:Port | Notiz |
|---|---|---|
| `alexstuder.cloud` | `web-hauptseite:80` | Landing |
| `aibrewgenius.alexstuder.cloud` | `web-assistent:80` | AiBrewGenius UI |
| `rapt.alexstuder.cloud` | `web-rapt:80` | Fermentation Dashboard |
| `api.alexstuder.cloud` | `api-proxy:3000` | OpenAI/RAPT/Brewfather Proxy |
| `supabase.alexstuder.cloud` | `supabase-kong:8000` | Auth/REST/Realtime/Storage API |
| `studio.alexstuder.cloud` | `supabase-studio:3000` | Admin UI — Cloudflare Access davor! |
| `db-tcp.alexstuder.cloud` | `tcp://supabase-db:5432` | TCP-Postgres cross-VPS |

`./scripts/cloudflare-reconcile.sh` ist **idempotent**: bei jedem Lauf wird
die Tunnel-Ingress-Config gegen die JSON gediffed, nur **laufende** Ziel-Container
werden beansprucht, fehlende DNS-CNAMEs angelegt, abweichende umgebogen.
Wird vom `bootstrap.sh` automatisch nach dem Container-Start aufgerufen und
kann jederzeit manuell laufen — z.B. nach Editieren der `routes.json`.

"Was du startest, wird geroutet" — auf einem VPS mit nur `web-rapt` laufend
wird nur `rapt.alexstuder.cloud` beansprucht; die anderen Hostnames bleiben
beim VPS, der die jeweiligen Container betreibt.

### API-Token erstellen  (einmalig, geteilt über alle VPS)

1. https://dash.cloudflare.com → Profile → **API Tokens** → *Create Token* → *Custom token*
2. Name: `webPage_infra-bootstrap`
3. Permissions:

   | Type | Resource | Permission | Wofür |
   |---|---|---|---|
   | Account | Cloudflare Tunnel | **Edit** | Tunnel anlegen (`POST cfd_tunnel`), Token holen, Ingress schreiben |
   | Zone | DNS | Edit | CNAMEs anlegen/ändern/löschen |
   | Zone | Zone | Read | Zone-Auflösung |
   | Account | Access: Apps and Policies | **Edit** | Access-App + Allow-Policy für `portainer.alexstuder.cloud` automatisch anlegen (Hub-VPS) |

   **Hinweis:** `Cloudflare Tunnel: Edit` deckt sowohl das **Anlegen** neuer Tunnel
   (`POST /accounts/.../cfd_tunnel`) als auch das Schreiben der Ingress-Config
   (`PUT .../configurations`) ab — kein separater Scope nötig.
   `Access: Apps and Policies: Edit` wird **nur auf dem Hub-VPS** aktiv genutzt
   (`PORTAINER_ROLE=hub`); auf allen anderen VPS erzeugt er keinen API-Call.
   **Einmalige Voraussetzung:** Cloudflare Zero Trust muss auf dem Account aktiviert
   sein (Team-Domain konfiguriert — einmalig im Zero-Trust-Dashboard). Ohne diese
   Voraussetzung schlägt der Access-Schritt mit einem deutlichen Warn-Block fehl.

4. **Account Resources** → All accounts (oder selektiv)
5. **Zone Resources** → Specific zone → `alexstuder.cloud`
6. Create → Token **einmalig** kopieren

Nur **drei** Werte in `.env.gpg` (geteilt):

```env
CLOUDFLARE_API_TOKEN=<token>
CLOUDFLARE_ACCOUNT_ID=<id>
CLOUDFLARE_ZONE_ID=<id>
```

`CLOUDFLARE_TUNNEL_TOKEN` und `CLOUDFLARE_TUNNEL_ID` **nicht** in `.env.gpg` eintragen —
der Bootstrap setzt sie pro VPS automatisch in der **lokalen** `.env`.

```bash
# Nach dem Setzen der drei geteilten CF-Werte in .env:
./scripts/encrypt-env.sh && git add .env.gpg && git commit && git push
```

Die Zone ID steht im Dashboard unter `alexstuder.cloud` rechte Sidebar;
die Account ID auf der Dashboard-Hauptseite rechte Sidebar.

## Backup & Restore

**Variante A — pro App getrennte Dumps.** Beide Apps teilen sich eine Postgres-DB
und das `auth`-Schema (Logins). Pro Backup-Lauf entstehen **drei** verschlüsselte
Dumps in eigene Ordner (lokal + R2-Bucket `backup`):

| Ordner | pg_dump | Inhalt |
|---|---|---|
| `_supabase_core/` | `--exclude-schema=aibrewgenius --exclude-schema=rapt` | `auth` + `storage` + `public` + `_realtime` + Rest |
| `brew_assistent/` | `-n aibrewgenius` | Schema `aibrewgenius` |
| `rapt_dashboard/` | `-n rapt` | Schema `rapt` |

```bash
# Manuelles Backup (drei verschlüsselte Dumps → lokal + R2). Als 'alex', kein sudo.
./scripts/backup.sh

# Pre-Migration-Backup mit Label (alle drei, rotation-exempt)
./scripts/backup.sh --label pre-migration     # → ..._pre-migration.fc.gpg

# Nur lokal, kein Off-site-Upload
./scripts/backup.sh --no-upload

# Andere Retention (Standard N=7 neueste pro Ordner, lokal + R2)
BACKUP_KEEP=14 ./scripts/backup.sh

# Restore ALLER Schemas in zwingender Reihenfolge (core → apps), jüngste aus R2
./scripts/restore.sh all

# Restore eines einzelnen Ziels (jüngste aus dem passenden R2-Ordner)
./scripts/restore.sh core
./scripts/restore.sh rapt_dashboard
./scripts/restore.sh brew_assistent latest

# Restore aus konkreter lokaler Datei (ein Ziel)
./scripts/restore.sh rapt_dashboard backups/rapt_dashboard/rapt_20260523_030000.fc.gpg

# Cron-Log der nightly Backups
tail -f /var/log/brewing-backup.log
```

Echter, nicht-reproduzierbarer State liegt nur im zentralen Supabase-Postgres
(Schemas `auth`, `aibrewgenius`, `rapt`, `storage`, `_realtime`, `public`). Alles
andere ist stateless (Git + Docker-Hub-Images). Konzept-Details:
[`BACKUP_RESTORE.md`](BACKUP_RESTORE.md).

```
scripts/backup.sh   (drei getrennte Pipelines, kein Klartext-Dump auf Platte)
  docker exec supabase-db pg_dump -Fc -U supabase_admin -d postgres <schema-args>
     ▼  gpg --symmetric AES256  (gleiche Passphrase wie .env.gpg)
  backups/_supabase_core/core_<TS>.fc.gpg          ─► R2 backup/_supabase_core/
  backups/brew_assistent/aibrewgenius_<TS>.fc.gpg  ─► R2 backup/brew_assistent/
  backups/rapt_dashboard/rapt_<TS>.fc.gpg          ─► R2 backup/rapt_dashboard/
     └─► Retention PRO ORDNER: neueste N=7 behalten (lokal + R2), BACKUP_KEEP

scripts/restore.sh all
  je Ziel:  (R2 holen) → entschlüsseln → pg_restore --clean --if-exists --no-owner
  Reihenfolge: core ZUERST, dann brew_assistent, dann rapt_dashboard
```

- **Trigger:** nightly um 03:00 via `cron` (`/etc/cron.d/brewing-backup`), von
  `bootstrap.sh` eingerichtet. Läuft direkt **als `alex` (kein sudo/root)**: alex
  ist in der `docker`-Gruppe (`docker exec` ohne sudo) und owner von Repo +
  Passphrase-Datei `/etc/brewing/gpg.pass` (mode 600, owner alex) → liest sie ohne
  Prompt. `cron`s minimaler PATH wird in `backup.sh`/`cron.d` auf einen sane Wert
  gesetzt, damit `docker`/`gpg`/`rclone` auflösen.
- **Verschlüsselung:** symmetrisch AES-256, **gleiche Passphrase wie `.env.gpg`**.
  R2 sieht nie Klartext — nur die fertigen `.fc.gpg` gehen raus.
- **Konsistenz (bewusste Entscheidung):** die drei Dumps laufen **back-to-back
  ohne geteilten Snapshot** (kein `pg_export_snapshot`). Das lässt ein winziges
  Inkonsistenz-Fenster zwischen den Dumps offen — ein während des Laufs neu
  angelegter `auth.users`-Eintrag könnte im `core`-Dump fehlen, aber von einem
  später gedumpten App-Eintrag referenziert werden. Beim nightly-Lauf um 03:00
  gibt es praktisch keine Schreiblast, und `--no-owner`/nicht-fatale Fehler beim
  Restore fangen den Rand-Fall ab. Bewusst keine Snapshot-Koordination, um die
  bash-Komplexität (offene psql-Session über drei Dumps) zu vermeiden.
- **R2-Credentials:** `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET=backup`
  und entweder `R2_ENDPOINT` oder `R2_ACCOUNT_ID` in `.env` (siehe `.env.example`).
  Token: Cloudflare Dashboard → R2 → *Manage R2 API Tokens* (Object Read & Write,
  auf den Bucket gescopt). rclone-Creds werden via `RCLONE_CONFIG_R2_*`-Env-Vars
  übergeben (nie in der Kommandozeile/`ps`). Danach `./scripts/encrypt-env.sh` +
  commit `.env.gpg`.
- **Retention:** count-based, **neueste N=7 pro Ordner** (`BACKUP_KEEP`, default 7),
  **lokal UND R2**. `backup.sh` löscht in jedem `backups/<ordner>/` und nach dem
  Upload auch im R2-Ordner alles außer den neuesten N (per `rclone lsf`/`rclone
  delete`). Gelabelte Dumps (`--label`) bleiben unangetastet und zählen nicht mit.
  Keine R2-Lifecycle-Rule mehr nötig.

### Restore — der fragile Teil

Das `supabase/postgres`-Image legt `auth`, `storage`, `_realtime`, Extensions und
Roles beim ersten Start **selbst** an. `pg_restore --clean --if-exists` droppt
diese Image-Objekte vor dem Neuanlegen und löst so die Kollisionen. App-Migrationen
sind im jeweiligen Dump enthalten — kein separater Schritt nötig.

**Reihenfolge ist zwingend:** `core` zuerst (legt `auth.users` an), dann die
App-Schemas — `aibrewgenius` und `rapt` referenzieren beide `auth.users`.
`restore.sh all` erzwingt diese Reihenfolge automatisch.

Restore läuft **nie** automatisch und **nie** ohne explizites Ziel-Argument
(`core`/`brew_assistent`/`rapt_dashboard`/`all`) plus interaktive Bestätigung
(`restore` tippen) bzw. `--yes`.

**Bekannte, nicht-fatale Restore-Fehler** (erwartbar, kein echter Fehlschlag):

- `publication "supabase_realtime" already exists` / `... does not exist`
- Fehler/Warnungen rund um `extensions`-Schema, `pgsodium`, `vault`
- `role "..." already exists` (vom Image vorab angelegt) — wegen `--no-owner` unkritisch
- `must be owner of extension ...` für vom Image verwaltete Extensions

`restore.sh` ruft `pg_restore` daher **ohne** `--exit-on-error` auf und bewertet
den Erfolg über die Tabellen-Counts am Ende + den App-Smoke-Check (Login + je eine
Query auf `aibrewgenius.*` und `rapt.*`), nicht über den Exit-Code.

**Disaster-Recovery-Gesamtbild:** neuer VPS → `bootstrap.sh` (frischer Stack,
Image-Init legt Roles/Schemas an) → `restore.sh all` (core → apps, aus R2-Bucket
`backup`) → `cloudflare-reconcile.sh`.

## Wartung auf dem VPS

```bash
# Status
docker compose --profile vps ps

# Logs eines Containers
docker logs -f cloudflared
docker logs -f api-proxy

# Manueller Pull + Restart eines App-Containers (z.B. nach Bug-Fix)
docker compose --profile vps pull web_assistent
docker compose --profile vps up -d web_assistent

# Komplettes Stack-Update (zieht ALLE Images neu, auch Supabase)
docker compose --profile vps pull
docker compose --profile vps up -d

# Stack stoppen / starten
docker compose --profile vps down
docker compose --profile vps up -d

# Cloudflare Hostnames + DNS abgleichen (nach Edit von scripts/cloudflare-routes.json)
./scripts/cloudflare-reconcile.sh
```

## Architektur

```
Docker Hub                                                Ubuntu VPS
┌────────────────────────┐                          ┌────────────────────────┐
│ alexstuder-web/        │                          │ ~/webPage_infra        │
│  - web_hauptseite      │  ◀── watchtower pull ──  │   docker-compose.yml   │
│  - web_assistent       │       (alle 5 min)       │   .env.gpg → .env      │
│  - web_rapt            │                          │   supabase/kong.yml    │
│  - brew_proxy          │                          │   supabase/db_init/    │
└────────────────────────┘                          └────────────────────────┘
       ▲                                                       ▲
       │ docker build                                          │ cloudflared
       │ (GitHub Actions on push to main)                      │ tunnel
       │                                                       │
┌──────┴───────────┐ ┌─────────────┐                  ┌────────┴────────┐
│ brew_assistent   │ │ brew-proxy  │  …               │ Cloudflare DNS  │
│ RAPT_Dashboard   │ │             │                  │ alexstuder.cloud│
│ WebPageAlexStuder│ │             │                  │ (später .ch)    │
└──────────────────┘ └─────────────┘                  └─────────────────┘
```

## GitHub Org Secrets

Unter `alexstuder-web` (scoped auf App-Repos, nicht `webPage_infra`):

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Mehr nicht. Alles andere kommt aus `.env.gpg`.
