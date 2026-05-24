#!/usr/bin/env bash
# Verschlüsselt .env -> .env.gpg (symmetrisch, AES256).
# Passphrase-Quelle (erste passende gewinnt):
#   1. $GPG_PASS_FILE             (expliziter Pfad-Override)
#   2. /etc/brewing/gpg.pass      (VPS — von bootstrap.sh angelegt, mode 600)
#   3. ~/.config/brewing/gpg.pass (Dev-Maschine, mode 600 — einmalig anlegen)
#   4. $GPG_PASSPHRASE            (Env-Var)
#   5. interaktiver Prompt        (Fallback, nur mit TTY)
# Ur-Quelle: Bitwarden Item ALEXSTUDER_WEBPAGE_GPG_PASSWORD.
# Dev einmalig:  (umask 077; mkdir -p ~/.config/brewing; cat > ~/.config/brewing/gpg.pass)   # Passphrase eintippen + Ctrl-D

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

# --- Passphrase-Quelle auflösen: Datei > Env > Prompt (konsistent mit backup/restore) ---
PASS_FILE="${GPG_PASS_FILE:-}"
if [[ -z "$PASS_FILE" ]]; then
  for _cand in /etc/brewing/gpg.pass "$HOME/.config/brewing/gpg.pass"; do
    [[ -r "$_cand" ]] && { PASS_FILE="$_cand"; break; }
  done
fi

GPG_ARGS=(--batch --yes --symmetric --cipher-algo AES256 --output .env.gpg)

if [[ -n "$PASS_FILE" && -r "$PASS_FILE" ]]; then
  # gpg liest die Passphrase direkt aus der Datei (erste Zeile, Newline gestrippt) —
  # sie landet nie in argv, einer Shell-Variable oder im Prozess-Env.
  gpg --pinentry-mode loopback --passphrase-file "$PASS_FILE" "${GPG_ARGS[@]}" .env
elif [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  # Über fd 3 statt --passphrase (das wäre in ps sichtbar).
  gpg --pinentry-mode loopback --passphrase-fd 3 "${GPG_ARGS[@]}" .env \
    3< <(printf '%s' "$GPG_PASSPHRASE")
else
  [[ -t 0 ]] || { echo "Fehler: keine Passphrase-Quelle (Datei/Env) und kein TTY." >&2; exit 1; }
  gpg "${GPG_ARGS[@]}" .env
fi

echo "OK: .env.gpg geschrieben ($(wc -c < .env.gpg) Bytes)."
echo "    Jetzt 'git add .env.gpg && git commit' nicht vergessen."
