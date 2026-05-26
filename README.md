# webPage_infra

**Single source of truth** für das gesamte Brewing-Ökosystem auf einem VPS.
Alle Anwendungen kommen als **fertige Container-Images** aus Docker Hub —
dieses Repo enthält nur Compose-Files, Configs, Bootstrap und die Backup-Scripts.

> **Architektur in einem Satz:** zwei **voneinander unabhängige Lean-Supabase-Stacks**
> (je eigene DB + Auth) — einer für `brew_assistent`, einer für `RAPT_Dashboard` —
> plus je ein eigener API-Proxy. Kein geteiltes `auth`, keine geteilte DB. Auto-Login
> zwischen den Apps läuft über eine **REST-SSO**-Schnittstelle, nicht über geteilte Logins.

## Bootstrap auf frischem Ubuntu-VPS

```bash
curl -fsSL https://raw.githubusercontent.com/alexstuder-web/webPage_infra/main/scripts/bootstrap.sh \
  -o bootstrap.sh && chmod +x bootstrap.sh && sudo ./bootstrap.sh
```

Interaktive Eingaben (Install-Pfad):

1. Passwort für neuen Linux-User `alex`
2. Bitwarden E-Mail *(nur falls `.env` noch fehlt)*
3. Bitwarden Master-Passwort *(holt die GPG-Passphrase aus Item
   `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`)*

`bootstrap.sh` ist **menügesteuert** (Neu-Installieren · einzelne App · Migrate von
altem VPS · Restore aus R2). Was der Install-Pfad automatisch tut:

`apt upgrade` → User `alex` + Docker + `cron`/`rclone`/`jq` → Bitwarden CLI →
`webPage_infra` nach `/home/alex/webPage_infra` clonen → **App-Repos
`brew_assistent-new` + `RAPT_Brewing_Dashboard-new` als Geschwister shallow-clonen**
(liefern die `db_scripts/` für die DB-Init-Mounts) → `.env` entschlüsseln →
`docker compose --profile vps up -d <gewählte Services inkl. db-init>` → die
`db-init-*`-Container legen Baseline + Migrationen an → Cloudflare-Tunnel + DNS
reconcilen → nightly-Backup-Cron einrichten.

**Threat-Model-Hinweis:** `bootstrap.sh` wird per `curl -fsSL` aus dem GitHub-Org-Repo
geladen und direkt als root ausgeführt — ohne gesonderte Checksum-Verifikation. Das
Sicherheitsmodell lautet "trust your own repo": wer schreibenden Zugriff auf
`alexstuder-web/webPage_infra` oder den DNS-Namen `raw.githubusercontent.com`
kontrolliert, kann beliebigen Code als root einschleusen. Mitigations: GitHub-Account
mit 2FA, Bitwarden-Session und GPG-Passphrase werden erst nach der Skript-Ausführung
abgerufen und landen nicht im Skript selbst.

## Enthaltene Services

Zwei **Lean-Supabase**-Stacks (nur `db + auth + rest + kong` — `realtime`, `storage`,
`studio`, `meta` werden bewusst **nicht** betrieben), getrennt nach App über
eigene Netze, Volumes, Secrets und Ports.

| Container | Image | Updates |
|---|---|---|
| `web-hauptseite` | `${DOCKERHUB_USERNAME}/web_hauptseite:latest` | Watchtower (`:latest`) |
| `web-assistent` | `${DOCKERHUB_USERNAME}/web_assistent:latest` | Watchtower (`:latest`) |
| `web-rapt` | `${DOCKERHUB_USERNAME}/web_rapt:latest` | Watchtower (`:latest`) |
| `api-proxy-assistent` | `${DOCKERHUB_USERNAME}/brew_proxy:latest` (`PROXY_ROLE=assistent`) | Watchtower (`:latest`) |
| `api-proxy-rapt` | `${DOCKERHUB_USERNAME}/brew_proxy:latest` (`PROXY_ROLE=rapt`) | Watchtower (`:latest`) |
| **assistent-Stack** | | |
| `db-assistent` | `supabase/postgres:15.8.1.060` | manuell (gepinnt) |
| `auth-assistent` | `supabase/gotrue:v2.176.1` | manuell (gepinnt) |
| `rest-assistent` | `postgrest/postgrest:v12.2.10` | manuell (gepinnt) |
| `kong-assistent` | `kong:2.8.1` | manuell (gepinnt) |
| `db-init-assistent` | `${DOCKERHUB_USERNAME}/db_init_runner:${DB_INIT_RUNNER_TAG:-latest}` | Init-Container (one-shot) |
| **rapt-Stack** | | |
| `db-rapt` | `supabase/postgres:15.8.1.060` (TimescaleDB) | manuell (gepinnt) |
| `auth-rapt` | `supabase/gotrue:v2.176.1` | manuell (gepinnt) |
| `rest-rapt` | `postgrest/postgrest:v12.2.10` | manuell (gepinnt) |
| `kong-rapt` | `kong:2.8.1` | manuell (gepinnt) |
| `db-init-rapt` | `${DOCKERHUB_USERNAME}/db_init_runner:${DB_INIT_RUNNER_TAG:-latest}` | Init-Container (one-shot) |
| **Infra / optional** | | |
| `cloudflared` | `cloudflare/cloudflared:2026.5.0` | manuell · `profiles: [vps]` |
| `watchtower` | `containrrr/watchtower:latest` | self-update · `profiles: [vps]` |
| `portainer` | `portainer/portainer-ce:2.27.3` | manuell · `profiles: [portainer-hub]` |
| `portainer_edge_agent` | `portainer/agent:2.27.3` | manuell · `profiles: [portainer-agent]` |
| `posteio` | `analogic/poste.io:2.4` | manuell · `profiles: [mail]` |

App-Container haben das Label `com.centurylinklabs.watchtower.enable=true` →
Watchtower zieht alle 5 Min neue `:latest` Images. Supabase, cloudflared, Portainer
und Mail bleiben gepinnt; Updates nur über bewusstes Anheben der Image-Tags + Re-deploy.

## Datenbanken — getrennt pro App

- **Zwei eigenständige DBs**: `db-assistent` (Schema `aibrewgenius`) und `db-rapt`
  (Schema `rapt`, TimescaleDB-Hypertables für Telemetrie). Jede DB hat ihr **eigenes
  `auth`** (eigene GoTrue). Keine geteilte `auth.users`, kein cross-DB-FK.
- **Schemas leben im jeweiligen App-Repo** (`brew_assistent-new/db_scripts/`,
  `RAPT_Brewing_Dashboard-new/db_scripts/`), **nicht** hier. Der Bootstrap mountet
  sie read-only in den passenden `db-init-*`-Container.
- **DB-Init**: pro Stack ein One-Shot-Init-Container (`db_init_runner`-Image). Er
  wartet auf `auth.users`, wendet die `baseline.sql` an und danach alle noch nicht
  applizierten `migrations/NNN_*.sql` (Tracking via `public.schema_migrations`).
  Idempotent — ein erneuter Lauf ist ein No-op. **Migrations-Konzept:** pro App eine
  Init-Baseline, danach forward-only nummerierte Migrationen.
- **SSO via REST**: das RAPT-Dashboard bietet eine Auto-Login-Schnittstelle. Der
  assistent-Proxy signiert ein kurzlebiges single-use Login-Ticket, der rapt-Proxy
  löst es server-zu-server ein (`service_role`/GoTrue-Admin) und gibt dem User eine
  echte RAPT-Session — ohne zweiten Login und ohne Secret im Browser.

## Secrets — `.env.gpg`

Alle Runtime-Secrets liegen verschlüsselt als `.env.gpg` im Repo (AES-256, symmetrisch).
Die GPG-Passphrase steckt in **Bitwarden** unter Item `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`.
`decrypt-/encrypt-env.sh` lösen die Passphrase autonom auf (`GPG_PASS_FILE` →
`/etc/brewing/gpg.pass` → `~/.config/brewing/gpg.pass` → `$GPG_PASSPHRASE` → Prompt).

### Secret hinzufügen / ändern

```bash
./scripts/decrypt-env.sh        # .env.gpg → .env  (Passphrase wird autonom gelöst)
$EDITOR .env                    # Wert ändern
./scripts/encrypt-env.sh        # .env → .env.gpg
git add .env.gpg && git commit -m "update env" && git push
```

Auf dem VPS: `git pull && ./scripts/decrypt-env.sh && docker compose --profile vps up -d`.

**Niemals** die unverschlüsselte `.env` committen — `.gitignore` blockt das.
**Keine** globalen RAPT-/Brewfather-Creds in der `.env`: beide sind rein per-User
(RAPT-Keys + Brewfather-Keys im Vault der jeweiligen DB, von den Proxies per RPC gelesen).

## Lokales Dev-Setup

```bash
./scripts/decrypt-env.sh        # .env zuerst entschlüsseln
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
```

Dev-Override aktiviert Localhost-Ports:

| Port | Service | | Port | Service |
|---|---|---|---|---|
| `:8090` | web_hauptseite | | `:54321` | kong-assistent |
| `:8081` | web_assistent | | `:54322` | db-assistent (Postgres) |
| `:8082` | web_rapt | | `:54331` | kong-rapt |
| `:8083` | api_proxy_assistent | | `:54332` | db-rapt (Postgres) |
| `:8085` | api_proxy_rapt | | | |

`cloudflared`, `watchtower`, `portainer*` und `posteio` laufen lokal **nicht**
(hinter `profiles`). Kein Studio-Container — fürs DB-Inspizieren `psql` gegen
`:54322`/`:54332` oder ein externes GUI.

## Cloudflare Tunnel + DNS  (pro VPS dynamisch, idempotent via API)

### Pro-VPS-Tunnel-Modell

Jeder VPS bekommt beim Bootstrap **automatisch seinen eigenen Cloudflare-Tunnel**
(angelegt per API, Name `brewing-<sanitisierter-hostname>`, idempotent). Der
`cloudflared`-Container läuft mit dem VPS-eigenen Connector-Token; jeder VPS
routet nur die Hostnames, deren Ziel-Container **auf ihm tatsächlich laufen**.

Reihenfolge beim Bootstrap:
1. **Tunnel-Ensure** (`cf_ensure_tunnel_if_token`): sucht `brewing-<hostname>` in der
   CF-Account-Tunnel-Liste → ID + Connector-Token holen oder neuen Tunnel anlegen.
   Token und ID werden in die **lokale `.env`** geschrieben (nie in `.env.gpg`).
2. **Container starten** (`docker compose --profile vps up -d`): `cloudflared` liest
   `CLOUDFLARE_TUNNEL_TOKEN` aus `.env`.
3. **Reconcile** (`cloudflare-reconcile.sh`): gleicht Tunnel-Ingress + DNS-CNAMEs
   gegen die laufenden Container ab. Nicht laufende Ziele werden übersprungen.

Routing-Map liegt deklarativ in [`scripts/cloudflare-routes.json`](scripts/cloudflare-routes.json):

| Hostname | Ziel | Notiz |
|---|---|---|
| `alexstuder.cloud` | `web-hauptseite:80` | Landing |
| `aibrewgenius.alexstuder.cloud` | `web-assistent:80` | AiBrewGenius UI |
| `rapt.alexstuder.cloud` | `web-rapt:80` | Fermentation Dashboard |
| `api-assistent.alexstuder.cloud` | `api-proxy-assistent:3000` | OpenAI/Brewfather-Proxy |
| `api-rapt.alexstuder.cloud` | `api-proxy-rapt:3000` | RAPT/db-sync-Proxy |
| `api.alexstuder.cloud` | `api-proxy-assistent:3000` | Legacy-Alias |
| `db-assistent.alexstuder.cloud` | `kong-assistent:8000` | assistent-Supabase-API |
| `db-rapt.alexstuder.cloud` | `kong-rapt:8000` | rapt-Supabase-API |
| `supabase.alexstuder.cloud` | `kong-assistent:8000` | Legacy-Alias |
| `db-tcp.alexstuder.cloud` | `tcp://db-assistent:5432` | TCP-Postgres cross-VPS |
| `portainer.alexstuder.cloud` | `portainer:9000` | Admin-UI — Cloudflare Access davor (Hub-VPS) |
| `edge.alexstuder.cloud` | `portainer:8000` | Edge-Agent-Endpoint (öffentlich) |
| `webmail.alexstuder.cloud` | `posteio:80` | Poste.io Webmail |

`./scripts/cloudflare-reconcile.sh` ist **idempotent**: bei jedem Lauf wird die
Tunnel-Ingress-Config gegen die JSON gediffed, nur **laufende** Ziel-Container werden
beansprucht, fehlende DNS-CNAMEs angelegt, abweichende umgebogen, verwaiste eigene
CNAMEs aufgeräumt. Zusätzlich richtet es (nur Hub-VPS) Cloudflare Access für
`portainer.` ein und (nur mit `mail`-Marker / laufendem posteio) die Mail-DNS-Records
(MX/SPF/DMARC/DKIM). Wird vom `bootstrap.sh` nach dem Container-Start aufgerufen und
kann jederzeit manuell laufen — z.B. nach Editieren der `routes.json`.

### API-Token erstellen  (einmalig, geteilt über alle VPS)

1. https://dash.cloudflare.com → Profile → **API Tokens** → *Create Token* → *Custom token*
2. Name: `webPage_infra-bootstrap`
3. Permissions:

   | Type | Resource | Permission | Wofür |
   |---|---|---|---|
   | Account | Cloudflare Tunnel | **Edit** | Tunnel anlegen (`POST cfd_tunnel`), Token holen, Ingress schreiben |
   | Zone | DNS | Edit | CNAMEs + Mail-Records anlegen/ändern/löschen |
   | Zone | Zone | Read | Zone-Auflösung |
   | Account | Access: Apps and Policies | **Edit** | Access-App + Allow-Policy für `portainer.` (nur Hub-VPS) |

   **Hinweis:** `Cloudflare Tunnel: Edit` deckt Anlegen + Ingress-Schreiben ab.
   `Access: Apps and Policies: Edit` wird **nur auf dem Hub-VPS** (`PORTAINER_ROLE=hub`)
   genutzt; Voraussetzung dort: Cloudflare Zero Trust aktiviert (Team-Domain). Ohne
   den Scope/Zero-Trust schlägt nur der Access-Schritt mit deutlichem Warn-Block fehl.

4. **Account Resources** → All accounts · **Zone Resources** → `alexstuder.cloud`
5. Create → Token **einmalig** kopieren

Nur **drei** geteilte Werte in `.env.gpg`:

```env
CLOUDFLARE_API_TOKEN=<token>
CLOUDFLARE_ACCOUNT_ID=<id>
CLOUDFLARE_ZONE_ID=<id>
```

`CLOUDFLARE_TUNNEL_TOKEN` und `CLOUDFLARE_TUNNEL_ID` **nicht** in `.env.gpg` —
der Bootstrap setzt sie pro VPS automatisch in der **lokalen** `.env`.

## Backup & Restore

**Zwei strikt getrennte DBs = zwei getrennte Backups.** Es gibt kein geteiltes
`auth` mehr, also auch keinen 3-fach-Split und keine Restore-Reihenfolge. Was
gesichert wird, steuern **Marker** unter `/etc/brewing/stateful-units.d/` — ein
stateless-VPS ohne Marker macht `backup.sh` zum sauberen No-op.

| Unit (Marker) | Quelle | → Ordner (lokal + R2 `backup/`) |
|---|---|---|
| `db-assistent` | `pg_dump -Fc` gegen `db-assistent` | `backups/db-assistent/` → `backup/db-assistent/` |
| `db-rapt` | `pg_dump -Fc` gegen `db-rapt` (TimescaleDB-Hooks) | `backups/db-rapt/` → `backup/db-rapt/` |
| `mail` | `poste-data` als `tar` | `backups/mail/` → `backup/mail/` |

```bash
# Manuelles Backup aller aktiven Units (verschlüsselt → lokal + R2). Als 'alex', kein sudo.
./scripts/backup.sh

# Pre-Migration-Backup mit Label (rotation-exempt)
./scripts/backup.sh --label pre-migration

# Nur lokal, kein Off-site-Upload
./scripts/backup.sh --no-upload

# Andere Retention (Standard: neueste N=7 pro Ordner, lokal + R2)
BACKUP_KEEP=14 ./scripts/backup.sh

# Restore — Ziel ist zwingend (kein automatischer Lauf):
./scripts/restore.sh all                  # beide DBs, jüngste aus R2
./scripts/restore.sh db-assistent latest  # nur assistent-DB
./scripts/restore.sh db-rapt latest       # nur rapt-DB (TimescaleDB-Hooks automatisch)
./scripts/restore.sh db-rapt backups/db-rapt/db-rapt_20260525_030000.fc.gpg  # lokale Datei

# Cron-Log der nightly Backups
tail -f /var/log/brewing-backup.log
```

Konzept-Details: [`BACKUP_RESTORE.md`](BACKUP_RESTORE.md).

```
scripts/backup.sh   (pro Marker-Unit eine Pipeline, kein Klartext-Dump auf Platte)
  docker exec db-<unit> pg_dump -Fc -U supabase_admin -d postgres
     ▼  gpg --symmetric AES256  (gleiche Passphrase wie .env.gpg, via --passphrase-file)
  backups/<unit>/<unit>_<TS>[_<label>].fc.gpg   ─► R2 backup/<unit>/
     └─► Retention PRO ORDNER: neueste N=7 behalten (lokal + R2), BACKUP_KEEP; Labels exempt

scripts/restore.sh <all|db-assistent|db-rapt>
  je Ziel:  (R2 holen) → entschlüsseln → pg_restore --clean --if-exists --no-owner
  db-rapt:  timescaledb_pre_restore() VOR / post_restore() NACH pg_restore (Hypertable-Chunks!)
```

- **Trigger:** nightly um 03:00 via `cron` (`/etc/cron.d/brewing-backup`), von
  `bootstrap.sh` eingerichtet. Läuft direkt **als `alex` (kein sudo/root)**: alex
  ist in der `docker`-Gruppe und owner von Repo + `/etc/brewing/gpg.pass`
  (mode 600) → liest die Passphrase ohne Prompt.
- **Verschlüsselung:** symmetrisch AES-256, **gleiche Passphrase wie `.env.gpg`**.
  R2 sieht nie Klartext — nur die fertigen `.fc.gpg`/`.tar.gpg` gehen raus.
- **Unabhängigkeit:** jede DB hat ihr eigenes `auth`, daher ist jeder Dump
  **in sich konsistent** und einzeln restore-bar — keine Reihenfolge-Abhängigkeit.
- **TimescaleDB (`db-rapt`):** `restore.sh` wrappt `pg_restore` mit
  `timescaledb_pre_restore()`/`post_restore()` (Extension-Guard, **nicht** auf
  "nur db-rapt" hartkodiert) — sonst kämen die Telemetrie-Hypertables leer zurück.
  `post_restore`-Fehler → harter Abbruch (DB nicht vertrauen).
- **R2-Credentials:** `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET=backup`
  und `R2_ENDPOINT` (bzw. `R2_ACCOUNT_ID`) in `.env`. rclone-Creds via
  `RCLONE_CONFIG_R2_*`-Env-Vars (nie in der Kommandozeile/`ps`).
- **Retention:** count-based, neueste N=7 pro Ordner (`BACKUP_KEEP`), lokal UND R2.
  Gelabelte Dumps (`--label`) sind exempt.

### Restore — bekannte, nicht-fatale Fehler

Das `supabase/postgres`-Image legt `auth`, Extensions und Roles beim ersten Start
**selbst** an. `pg_restore --clean --if-exists --no-owner` droppt/überschreibt diese
Image-Objekte. Erwartbare, **nicht** fatale Meldungen:

- `role "..." already exists` (vom Image vorab angelegt) — wegen `--no-owner` unkritisch
- `must be owner of extension ...` für vom Image verwaltete Extensions
- Warnungen rund um `extensions`-Schema, `pgsodium`, `vault`

`restore.sh` ruft `pg_restore` daher **ohne** `--exit-on-error` auf und bewertet den
Erfolg über die Tabellen-Counts (inkl. `telemetry_*`-Hypertables bei db-rapt), nicht
über den Exit-Code. Restore läuft **nie** automatisch und **nie** ohne Ziel-Argument
plus Bestätigung (`restore` tippen) bzw. `--yes`.

**Disaster-Recovery:** neuer VPS → `bootstrap.sh` (Menüpunkt *Restore aus R2*) →
`restore.sh all` → `cloudflare-reconcile.sh`. Für den Umzug eines **laufenden** VPS:
Menüpunkt *Migrate* (SSH zum alten VPS, Stop-Verifikation, pre-migration-Backup, Restore).

## Wartung auf dem VPS

```bash
docker compose --profile vps ps                       # Status
docker logs -f cloudflared                            # Logs
docker logs -f api-proxy-assistent                    # (bzw. api-proxy-rapt)

# Einzelnen App-Container neu ziehen (z.B. nach Bug-Fix)
docker compose --profile vps pull web_assistent
docker compose --profile vps up -d web_assistent

# Komplettes Stack-Update (zieht ALLE Images neu, auch Supabase)
docker compose --profile vps pull
docker compose --profile vps up -d

# DB-Schema neu anwenden (Init-Container erneut laufen lassen — idempotent)
docker compose --profile vps up -d --force-recreate db-init-assistent db-init-rapt

# Cloudflare Hostnames + DNS abgleichen (nach Edit von scripts/cloudflare-routes.json)
./scripts/cloudflare-reconcile.sh
```

## Architektur

```
Docker Hub                                              Ubuntu VPS  (~/webPage_infra)
┌────────────────────────┐                       ┌──────────────────────────────────────┐
│ alexstuder-web/        │                        │ docker-compose.yml · .env.gpg → .env  │
│  - web_hauptseite      │ ◀── watchtower pull ── │                                        │
│  - web_assistent       │      (alle 5 min)      │  assistent-Stack      rapt-Stack       │
│  - web_rapt            │                        │  ┌─────────────┐      ┌─────────────┐  │
│  - brew_proxy          │                        │  │ db-assistent│      │ db-rapt     │  │
│  - db_init_runner      │                        │  │ auth/rest/  │      │ auth/rest/  │  │
└────────────────────────┘                        │  │ kong-assist.│      │ kong-rapt   │  │
       ▲                                           │  │ db-init ─┐  │      │ db-init ─┐  │  │
       │ docker build (GitHub Actions,             │  └──────────┼──┘      └──────────┼──┘  │
       │ on push to main)                          │   mount db_scripts/  mount db_scripts/ │
       │                                           │   api-proxy-assistent  api-proxy-rapt  │
┌──────┴────────────┐ ┌────────────┐               │                                        │
│ brew_assistent    │ │ brew-proxy │ …             │   cloudflared ──► Cloudflare Tunnel    │
│ RAPT_Dashboard    │ │            │               │   (+ portainer/posteio optional)       │
│ WebPageAlexStuder │ │            │               └────────────────────────────────────────┘
└───────────────────┘ └────────────┘                          │ alexstuder.cloud (später .ch)
   (db_scripts/ = Schema-Quelle, beim Bootstrap geklont)       ▼
                                                        Cloudflare DNS + Access
```

## GitHub Org Secrets

Unter `alexstuder-web`:

- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`

Genutzt von den App-Repo-Build-Workflows **und** vom `db_init_runner`-Build-Workflow
hier in `webPage_infra` (`.github/workflows/db-init-runner-build.yml`). Alles andere
kommt aus `.env.gpg`.
