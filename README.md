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

## Secrets / .env

Alle Secrets liegen verschlüsselt als `.env.gpg` im Repo (symmetrisch, AES256).
Die GPG-Passphrase steckt in **Bitwarden.com** unter dem Item **`ALEXSTUDER_WEBPAGE_GPG_PASSWORD`**.

### Erste Einrichtung (neue Maschine)
```bash
# Variante A: bw CLI (empfohlen)
bw login                  # einmalig
export BW_SESSION="$(bw unlock --raw)"
export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"

# Variante B: Passphrase manuell aus Bitwarden.com kopieren
export GPG_PASSPHRASE="<Wert aus ALEXSTUDER_WEBPAGE_GPG_PASSWORD>"

# .env entschlüsseln
./scripts/decrypt-env.sh
```

### Secret ändern / hinzufügen
```bash
./scripts/decrypt-env.sh   # .env.gpg -> .env
$EDITOR .env               # Wert ändern
./scripts/encrypt-env.sh   # .env -> .env.gpg
git add .env.gpg && git commit -m "update env" && git push
```

Auf dem VPS reicht danach `git pull && ./scripts/decrypt-env.sh && docker compose up -d`.

**Niemals** die unverschlüsselte `.env` committen — `.gitignore` blockt das.

## Deployment auf dem Server
```bash
# Einmalig
git clone https://github.com/Alexstuder/webPage_infra.git
cd webPage_infra
export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"
./scripts/decrypt-env.sh
docker compose up -d

# Updates passieren automatisch via Watchtower
```

## GitOps Flow
1. Push auf `main` in einem der App-Repos
2. GitHub Actions baut Docker Image → pushed zu Docker Hub
3. Watchtower erkennt neues Image → startet Container neu
4. Zero Downtime ✅
