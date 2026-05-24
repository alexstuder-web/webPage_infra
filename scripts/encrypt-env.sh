#!/usr/bin/env bash
# Verschlüsselt .env -> .env.gpg (symmetrisch, AES256).
# Passphrase: aus $GPG_PASSPHRASE oder interaktivem Prompt.
# Quelle der Passphrase: Bitwarden.com Item ALEXSTUDER_WEBPAGE_GPG_PASSWORD.
# Tipp: export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "Fehler: .env existiert nicht. Nichts zu verschlüsseln." >&2
  exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
  echo "Fehler: gpg ist nicht installiert. (macOS: 'brew install gnupg')" >&2
  exit 1
fi

GPG_ARGS=(--batch --yes --symmetric --cipher-algo AES256 --output .env.gpg)

if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  # Passphrase NIE auf der Kommandozeile (--passphrase wäre in ps sichtbar).
  # Stattdessen über fd 3 via --passphrase-fd reinschieben — konsistent mit
  # backup.sh/restore.sh. Interaktiver Fallback unten, wenn $GPG_PASSPHRASE leer.
  gpg --pinentry-mode loopback --passphrase-fd 3 "${GPG_ARGS[@]}" .env \
    3< <(printf '%s' "$GPG_PASSPHRASE")
else
  gpg "${GPG_ARGS[@]}" .env
fi

echo "OK: .env.gpg geschrieben ($(wc -c < .env.gpg) Bytes)."
echo "    Jetzt 'git add .env.gpg && git commit' nicht vergessen."
