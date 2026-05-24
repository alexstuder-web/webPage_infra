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

## Cloudflare Tunnel + DNS  (idempotent via API)

Routing-Map liegt deklarativ in [`scripts/cloudflare-routes.json`](scripts/cloudflare-routes.json):

| Hostname | Container:Port | Notiz |
|---|---|---|
| `alexstuder.cloud` | `web-hauptseite:80` | Landing |
| `aibrewgenius.alexstuder.cloud` | `web-assistent:80` | AiBrewGenius UI |
| `rapt.alexstuder.cloud` | `web-rapt:80` | Fermentation Dashboard |
| `api.alexstuder.cloud` | `api-proxy:3000` | OpenAI/RAPT/Brewfather Proxy |
| `supabase.alexstuder.cloud` | `supabase-kong:8000` | Auth/REST/Realtime/Storage API |
| `studio.alexstuder.cloud` | `supabase-studio:3000` | Admin UI — Cloudflare Access davor! |

`./scripts/cloudflare-reconcile.sh` ist **idempotent**: bei jedem Lauf wird
die Tunnel-Ingress-Config gegen die JSON gediffed, fehlende DNS-CNAMEs
angelegt, abweichende auf den Tunnel umgebogen. Wird vom `bootstrap.sh`
automatisch am Ende aufgerufen und kann jederzeit manuell laufen — z.B.
nach Editieren der `routes.json`.

### API-Token erstellen  (einmalig)

1. https://dash.cloudflare.com → Profile → **API Tokens** → *Create Token* → *Custom token*
2. Name: `webPage_infra-bootstrap`
3. Permissions:

   | Type | Resource | Permission |
   |---|---|---|
   | Account | Cloudflare Tunnel | Edit |
   | Zone | DNS | Edit |
   | Zone | Zone | Read |

4. **Account Resources** → All accounts (oder selektiv)
5. **Zone Resources** → Specific zone → `alexstuder.cloud`
6. Create → Token **einmalig** kopieren

Plus drei IDs (alle im Dashboard sichtbar, keine Secrets):

- **Account ID** — Dashboard-Hauptseite, rechte Sidebar
- **Zone ID** — `alexstuder.cloud` öffnen, rechte Sidebar
- **Tunnel ID** — Zero Trust → Networks → Tunnels → dein Tunnel → UUID in der URL

Diese 4 Werte in `.env`:

```env
CLOUDFLARE_API_TOKEN=<token>
CLOUDFLARE_ACCOUNT_ID=<id>
CLOUDFLARE_ZONE_ID=<id>
CLOUDFLARE_TUNNEL_ID=<id>
```

Dann `./scripts/encrypt-env.sh && git add .env.gpg && git commit && git push`.

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
