#!/usr/bin/env bash
# Entschlüsselt .env.gpg -> .env.
# Passphrase: aus $GPG_PASSPHRASE oder interaktivem Prompt.
# Quelle der Passphrase: Bitwarden.com Item ALEXSTUDER_WEBPAGE_GPG_PASSWORD.
# Tipp: export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env.gpg ]]; then
  echo "Fehler: .env.gpg existiert nicht." >&2
  exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
  echo "Fehler: gpg ist nicht installiert. (Debian/Ubuntu: 'apt install gnupg', macOS: 'brew install gnupg')" >&2
  exit 1
fi

if [[ -f .env ]]; then
  read -rp "Achtung: .env existiert bereits. Überschreiben? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Abgebrochen."; exit 1; }
fi

GPG_ARGS=(--batch --yes --decrypt --output .env)

if [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  gpg --passphrase "$GPG_PASSPHRASE" --pinentry-mode loopback "${GPG_ARGS[@]}" .env.gpg
else
  gpg "${GPG_ARGS[@]}" .env.gpg
fi

chmod 600 .env
echo "OK: .env geschrieben (mode 600)."
