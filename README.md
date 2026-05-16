# webPage_infra

Infrastruktur-Konfiguration für das gesamte Brewing-Ecosystem. Enthält `docker-compose.yml`, Cloudflare Tunnel Config und Watchtower Setup.

## Enthaltene Services
| Container | Beschreibung |
|---|---|
| `web_hauptseite` | Nginx – alexstuder.ch |
| `web_assistent` | Nginx – assistent.alexstuder.ch |
| `web_rapt` | Nginx – rapt.alexstuder.ch |
| `api_proxy` | Node.js Proxy (RAPT + OpenAI) |
| `cloudflared` | Cloudflare Tunnel |
| `watchtower` | Auto-Update aller Container |

## Deployment auf dem Server
```bash
# Einmalig
git clone https://github.com/Alexstuder/webPage_infra.git
cd webPage_infra
cp .env.example .env
# .env mit echten Werten befüllen
docker compose up -d

# Updates passieren automatisch via Watchtower
```

## GitOps Flow
1. Push auf `main` in einem der App-Repos
2. GitHub Actions baut Docker Image → pushed zu Docker Hub
3. Watchtower erkennt neues Image → startet Container neu
4. Zero Downtime ✅
