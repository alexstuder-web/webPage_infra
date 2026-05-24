#!/usr/bin/env bash
# ============================================================================
# Brewing-Stack Postgres-Backup — Variante A (pro App getrennt, off-site)
#
# Marker-gesteuert: welche Jobs laufen, leitet backup.sh aus den installierten
# stateful Units unter $STATEFUL_UNITS_DIR (/etc/brewing/stateful-units.d/) ab.
# Auf einem stateless-only VPS (kein Marker) → sauberer No-op, Exit 0.
#
# Drei getrennte pg_dump -Fc als supabase_admin, jeder einzeln direkt durch GPG
# gestreamt (kein Klartext-Dump landet je auf Platte):
#
#   docker exec supabase-db pg_dump -Fc -U supabase_admin -d postgres ...
#     │
#     ▼  gpg --batch --symmetric --cipher-algo AES256 (gleiche Passphrase wie .env.gpg)
#     ▼
#   backups/<folder>/<name>_<TS>[_<label>].fc.gpg   ──►  Upload R2 backup/<folder>/
#
#   Unit 'supabase' — drei Jobs:
#   1. _supabase_core  → pg_dump --exclude-schema=aibrewgenius --exclude-schema=rapt
#                        (auth + storage + public + _realtime + Rest)
#   2. brew_assistent  → pg_dump -n aibrewgenius
#   3. rapt_dashboard  → pg_dump -n rapt
#
# Beide App-Schemas referenzieren das gemeinsame auth.users → core MUSS zuerst
# zurückgespielt werden (siehe restore.sh).
#
# KONSISTENZ-HINWEIS (bewusste Entscheidung): Die drei Dumps laufen back-to-back,
# OHNE geteilten Snapshot (kein pg_export_snapshot/--snapshot). Daraus ergibt sich
# ein winziges Inkonsistenz-Fenster (Sekunden) zwischen den Dumps: ein in dieser
# Zeit neu angelegter auth.users-Row könnte im core-Dump fehlen, aber von einem
# später gedumpten App-Row referenziert werden. Der nightly-Lauf um 03:00 trifft
# praktisch keine Schreiblast; ein Restore mit --no-owner lässt eine evtl. fehlende
# FK-Referenz höchstens als nicht-fatalen Fehler stehen. Dokumentiert in README.
#
# Manuell:        ./scripts/backup.sh
# Pre-Migration:  ./scripts/backup.sh --label pre-migration   (rotation-exempt)
# Nur lokal:      ./scripts/backup.sh --no-upload
# Aus cron:       /home/alex/webPage_infra/scripts/backup.sh   (nightly ~03:00, als alex)
#
# Passphrase: --passphrase-file /etc/brewing/gpg.pass (von bootstrap.sh, mode 600,
#             owner alex) oder $GPG_PASS_FILE / $GPG_PASSPHRASE / interaktiv.
#
# RETENTION: keep-newest-N pro Ordner (count-based), lokal UND R2. N via
#            $BACKUP_KEEP (default 7). Gelabelte Dumps (--label) sind exempt.
# ============================================================================

set -euo pipefail

# cron liefert ein minimales PATH (/usr/bin:/bin) → docker/gpg/rclone werden
# evtl. nicht gefunden. Sane PATH voranstellen, damit die Tools auflösen.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# mapfile/readarray + lokale Arrays brauchen bash 4+. Ziel-VPS ist Ubuntu
# (bash 5.x); hier nur ein klarer Fehler statt kryptischem "command not found".
if (( BASH_VERSINFO[0] < 4 )); then
  echo "✖ Benötigt bash >= 4 (gefunden: ${BASH_VERSION}). Auf dem Ziel-VPS (Ubuntu) gegeben." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
ENV_FILE="${REPO_DIR}/.env"
BACKUP_DIR="${REPO_DIR}/backups"
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
PASS_FILE="${GPG_PASS_FILE:-/etc/brewing/gpg.pass}"
# Retention: neueste N pro Ordner behalten (lokal + R2). Gelabelte Dumps exempt.
BACKUP_KEEP="${BACKUP_KEEP:-7}"
# Marker-Registry: leere Touch-Dateien je installierter stateful Unit.
# Konfigurierbar via Env für isoliertes Testen (z.B. STATEFUL_UNITS_DIR=/tmp/test-units).
STATEFUL_UNITS_DIR="${STATEFUL_UNITS_DIR:-/etc/brewing/stateful-units.d}"

# ---------------------------------------------------------------- Helpers
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\n\033[1;31m✖ $*\033[0m" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: $0 [--label <name>] [--no-upload]

  --label <name>   Hängt _<name> an alle Dateinamen an (z.B. pre-migration).
                   Gelabelte Dumps sind rotation-exempt (bleiben liegen).
  --no-upload      Nur lokal sichern, kein R2-Upload.

Welche Jobs laufen, wird aus den Markern in \$STATEFUL_UNITS_DIR
(${STATEFUL_UNITS_DIR}) abgeleitet. Kein Marker → No-op, Exit 0.

Unit 'supabase' erzeugt drei Dumps:
  backups/_supabase_core/core_<TS>.fc.gpg
  backups/brew_assistent/aibrewgenius_<TS>.fc.gpg
  backups/rapt_dashboard/rapt_<TS>.fc.gpg
EOF
  exit 1
}

# ---------------------------------------------------------------- Args (getopts-Stil)
LABEL=""
DO_UPLOAD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)     [[ $# -ge 2 ]] || usage; LABEL="$2"; shift 2 ;;
    --no-upload) DO_UPLOAD=0; shift ;;
    -h|--help)   usage ;;
    *)           err "Unbekanntes Argument: $1" ;;
  esac
done

# Label säubern: nur [A-Za-z0-9._-] zulassen (kein Pfad-Traversal im Dateinamen)
if [[ -n "$LABEL" ]]; then
  [[ "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]] || err "Ungültiges --label '$LABEL' (erlaubt: A-Z a-z 0-9 . _ -)"
fi

# BACKUP_KEEP muss eine positive Ganzzahl >= 1 sein.
[[ "$BACKUP_KEEP" =~ ^[0-9]+$ && "$BACKUP_KEEP" -ge 1 ]] \
  || err "BACKUP_KEEP muss eine Ganzzahl >= 1 sein (gefunden: '$BACKUP_KEEP')"

# ---------------------------------------------------------------- Marker-Discovery + Unit→Jobs-Registry
# Liest installierten stateful Units aus $STATEFUL_UNITS_DIR.
# Leeres Markerset → No-op, Exit 0 (BEVOR irgendein docker inspect läuft).
# Erweiterbarkeit: neue Unit X → (a) Marker /etc/brewing/stateful-units.d/X beim
# Install setzen + (b) neuer Zweig in unit_jobs() hinzufügen. Kein Kern-Flow-Umbau.

# unit_jobs <unit>: gibt "folder stem" Paare aus (je eine Zeile).
unit_jobs() {
  case "$1" in
    supabase)
      printf '%s\n' \
        "_supabase_core core" \
        "brew_assistent aibrewgenius" \
        "rapt_dashboard rapt"
      ;;
    # Erweiterungspunkt: weitere Units hier als neuer case-Zweig eintragen.
    *)
      err "unit_jobs: unbekannte Unit '$1'"
      ;;
  esac
}

# Effektive Job-Liste aus vorhandenen Markern aufbauen.
declare -a FOLDERS=()
declare -a STEMS=()

if [[ -d "$STATEFUL_UNITS_DIR" ]]; then
  shopt -s nullglob
  for _marker in "$STATEFUL_UNITS_DIR"/*; do
    _unit="$(basename "$_marker")"
    # I3: Unbekannte Unit mit Warnung überspringen statt hart abbrechen —
    # eine Fremddatei (z.B. .gitkeep) darf nicht den ganzen Backup-Lauf killen.
    # Subshell-Check: unit_jobs ruft intern err() → exit 1; den Exit in einer
    # Subshell fangen, damit er nicht den Haupt-Prozess beendet.
    if ! ( unit_jobs "$_unit" >/dev/null 2>&1 ); then
      log "WARNUNG: unbekannte Unit '$_unit' in ${STATEFUL_UNITS_DIR} — übersprungen"
      continue
    fi
    while IFS=' ' read -r _folder _stem; do
      FOLDERS+=("$_folder")
      STEMS+=("$_stem")
    done < <(unit_jobs "$_unit")
  done
  shopt -u nullglob
fi

if (( ${#FOLDERS[@]} == 0 )); then
  log "Keine stateful Unit installiert (${STATEFUL_UNITS_DIR} leer oder fehlt) — nichts zu sichern."
  ok "No-op — stateless-only VPS. Backup-Cron läuft, tut aber nichts."
  exit 0
fi

# ---------------------------------------------------------------- Pre-flight
# Nur wenn tatsächlich Jobs vorhanden: Tools + Container prüfen.
command -v docker >/dev/null 2>&1 || err "docker fehlt"
command -v gpg    >/dev/null 2>&1 || err "gpg fehlt"
[[ -f "$ENV_FILE" ]] || err "Keine .env — erst ./scripts/decrypt-env.sh"

# supabase-db-Check: nur wenn supabase-Jobs aktiv (Marker gesetzt).
# Fehlt der Container obwohl Marker da → echter Fehlerfall, Hard-Fail korrekt.
if [[ -d "$STATEFUL_UNITS_DIR" ]] && [[ -f "${STATEFUL_UNITS_DIR}/supabase" ]]; then
  docker inspect "$DB_CONTAINER" >/dev/null 2>&1 \
    || err "Container '$DB_CONTAINER' läuft nicht — Stack starten (docker compose ... up -d)"
fi

mkdir -p "$BACKUP_DIR"

# .env nur in dieser Subshell laden (kein Leak nach außen) — brauchen
# POSTGRES_PASSWORD + die R2_*-Variablen.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${POSTGRES_PASSWORD:?fehlt in .env}"

# ---------------------------------------------------------------- Passphrase
# Quelle: root-only Datei (cron) > $GPG_PASSPHRASE (Env) > interaktiver Prompt.
# Wir schreiben die Passphrase IMMER in eine eigene mode-600 Tempdatei und
# übergeben sie via --passphrase-file (nie auf der Kommandozeile, nie via -x).
PASS_TMP="$(mktemp)"
chmod 600 "$PASS_TMP"
trap 'rm -f "$PASS_TMP"' EXIT

if [[ -r "$PASS_FILE" ]]; then
  cat "$PASS_FILE" > "$PASS_TMP"
elif [[ -n "${GPG_PASSPHRASE:-}" ]]; then
  printf '%s' "$GPG_PASSPHRASE" > "$PASS_TMP"
else
  [[ -t 0 ]] || err "Keine Passphrase-Quelle ($PASS_FILE nicht lesbar, \$GPG_PASSPHRASE leer, kein TTY)"
  read -rsp "GPG-Passphrase: " _pp; echo
  printf '%s' "$_pp" > "$PASS_TMP"
  unset _pp
fi
[[ -s "$PASS_TMP" ]] || err "Passphrase ist leer"

# ---------------------------------------------------------------- pg_dump-Argumente je Ordner
# dump_args() wird von dump_one() aufgerufen und gibt die pg_dump-Schema-Argumente
# für einen folder-Wert zurück (als Wort-Liste via echo).
# Die FOLDERS/STEMS-Arrays werden marker-gesteuert oben befüllt; dump_args() ist
# die Job-Definition (was gedumpt wird) und bleibt davon getrennt.
dump_args() {
  case "$1" in
    _supabase_core) echo "--exclude-schema=aibrewgenius --exclude-schema=rapt" ;;
    brew_assistent) echo "-n aibrewgenius" ;;
    rapt_dashboard) echo "-n rapt" ;;
    *)              err "Unbekannter Backup-Ordner: $1" ;;
  esac
}

TS="$(date +%Y%m%d_%H%M%S)"

# ---------------------------------------------------------------- Dump → GPG (3×)
# back-to-back, kein geteilter Snapshot (Konsistenz-Hinweis im Header/README).
declare -a PRODUCED_FILES=()   # für Upload + Abschlussreport

dump_one() {
  local folder="$1" stem="$2"
  local dir="${BACKUP_DIR}/${folder}"
  mkdir -p "$dir"
  local base="${stem}_${TS}"
  [[ -n "$LABEL" ]] && base="${base}_${LABEL}"
  local out="${dir}/${base}.fc.gpg"

  # pg_dump-Schema-Argumente sind statisch/aus dump_args → bewusst gewortsplittet.
  local -a pgargs
  read -ra pgargs <<< "$(dump_args "$folder")"

  log "Dump '${folder}' → ${folder}/${out##*/}"
  # PGPASSWORD wird im Container gesetzt (-e), erscheint nicht in der Host-argv.
  # pipefail (oben) macht die Pipe rot, wenn pg_dump fehlschlägt.
  if ! docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
         pg_dump -Fc -U supabase_admin -d postgres "${pgargs[@]}" \
       | gpg --batch --yes --symmetric --cipher-algo AES256 \
             --pinentry-mode loopback --passphrase-file "$PASS_TMP" \
             -o "$out"; then
    rm -f "$out"
    err "Backup '${folder}' fehlgeschlagen (pg_dump | gpg) — unvollständige Datei entfernt"
  fi
  [[ -s "$out" ]] || { rm -f "$out"; err "Backup '${folder}' ist leer — abgebrochen"; }
  ok "${folder}: $(basename "$out") ($(du -h "$out" | cut -f1))"
  PRODUCED_FILES+=("$out")
}

for i in "${!FOLDERS[@]}"; do
  dump_one "${FOLDERS[$i]}" "${STEMS[$i]}"
done

# ---------------------------------------------------------------- Rotation (lokal, PRO ORDNER)
# keep-newest-N: in jedem Ordner die neuesten N automatischen Dumps behalten,
# den Rest löschen. N = $BACKUP_KEEP (default 7). Gelabelte Dumps (--label)
# bleiben rotation-exempt. Dateiname sortiert == chronologisch (TS im Namen).
rotate_folder() {
  local folder="$1" stem="$2"
  local dir="${BACKUP_DIR}/${folder}"
  [[ -d "$dir" ]] || return 0

  local -a files=()
  shopt -s nullglob
  for f in "$dir/${stem}_"[0-9]*_[0-9]*.fc.gpg; do
    # Nur automatische Dumps (<stem>_YYYYMMDD_HHMMSS) — gelabelte (mit weiterem
    # _<wort> nach HHMMSS) ausschließen.
    local base; base="$(basename "$f" .fc.gpg)"
    [[ "$base" =~ ^${stem}_[0-9]{8}_[0-9]{6}$ ]] && files+=("$f")
  done
  shopt -u nullglob

  (( ${#files[@]} == 0 )) && return 0

  # Neueste zuerst (Name sortiert == chronologisch).
  local -a sorted=()
  while IFS= read -r line; do sorted+=("$line"); done \
    < <(printf '%s\n' "${files[@]}" | sort -r)

  local deleted=0 idx=0
  for f in "${sorted[@]}"; do
    if (( idx < BACKUP_KEEP )); then
      idx=$((idx + 1)); continue          # neueste N behalten
    fi
    rm -f "$f"
    echo "  - ${folder}/$(basename "$f")"
    deleted=$((deleted + 1))
  done
  local kept=$(( ${#sorted[@]} - deleted ))
  echo "  ${folder}: behalten ${kept} · gelöscht ${deleted}"
}

log "Lokale Rotation pro Ordner (neueste N=${BACKUP_KEEP} behalten)"
for i in "${!FOLDERS[@]}"; do
  rotate_folder "${FOLDERS[$i]}" "${STEMS[$i]}"
done
ok "Lokale Rotation fertig"

# ---------------------------------------------------------------- Off-site: R2
# rclone-Remote 'R2' via RCLONE_CONFIG_*-Env-Vars (KEINE Creds in argv → nicht
# ps-sichtbar). Verweise als R2:$R2_BUCKET/<folder>/<file>.
setup_r2_remote() {
  : "${R2_ACCESS_KEY_ID:?fehlt in .env (R2-Upload) — oder mit --no-upload starten}"
  : "${R2_SECRET_ACCESS_KEY:?fehlt in .env (R2-Upload)}"
  : "${R2_BUCKET:?fehlt in .env (R2-Upload)}"
  local endpoint="${R2_ENDPOINT:-}"
  if [[ -z "$endpoint" ]]; then
    : "${R2_ACCOUNT_ID:?fehlt in .env (R2_ENDPOINT oder R2_ACCOUNT_ID nötig)}"
    endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  fi
  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="$endpoint"
  export RCLONE_CONFIG_R2_REGION="auto"
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"
}

upload_r2() {
  command -v rclone >/dev/null 2>&1 \
    || err "rclone fehlt — R2-Upload nicht möglich (bootstrap installiert rclone). Sonst --no-upload."
  setup_r2_remote
  log "Upload nach R2 (Bucket: ${R2_BUCKET})"
  local f rel
  for f in "${PRODUCED_FILES[@]}"; do
    # rel = <folder>/<file> (relativ zu backups/)
    rel="${f#"${BACKUP_DIR}"/}"
    rclone copyto "$f" "R2:${R2_BUCKET}/${rel}" \
      || err "rclone-Upload fehlgeschlagen: ${rel}"
    ok "Hochgeladen: ${R2_BUCKET}/${rel}"
  done
}

# R2-Retention: keep-newest-N pro Ordner. Setzt voraus, dass setup_r2_remote
# bereits gelaufen ist (RCLONE_CONFIG_R2_* gesetzt). Liefert keinen harten
# Fehler bei leerem/fehlendem Ordner; nur echte rclone-delete-Fehler brechen ab.
#   $1 base   z.B. "R2:${R2_BUCKET}"  (oder ein Test-Prefix)
#   $2 folder z.B. "_supabase_core"
#   $3 stem   z.B. "core"   (filtert gelabelte Dumps wie das lokale Pendant)
prune_r2_folder() {
  local base="$1" folder="$2" stem="$3"
  local path="${base}/${folder}/"

  # rclone lsf: nur Dateinamen, eine Ebene. Auf automatische Dumps filtern
  # (<stem>_YYYYMMDD_HHMMSS.fc.gpg) → gelabelte bleiben exempt.
  local -a names=()
  while IFS= read -r n; do
    [[ "$n" =~ ^${stem}_[0-9]{8}_[0-9]{6}\.fc\.gpg$ ]] && names+=("$n")
  done < <(rclone lsf "$path" --include '*.fc.gpg' 2>/dev/null | sort -r)

  (( ${#names[@]} == 0 )) && { echo "  ${folder}: R2 leer/keine Auto-Dumps"; return 0; }

  local deleted=0 idx=0 n
  for n in "${names[@]}"; do
    if (( idx < BACKUP_KEEP )); then
      idx=$((idx + 1)); continue          # neueste N behalten
    fi
    rclone delete "${path}${n}" \
      || err "rclone-delete fehlgeschlagen: ${folder}/${n}"
    echo "  - R2 ${folder}/${n}"
    deleted=$((deleted + 1))
  done
  local kept=$(( ${#names[@]} - deleted ))
  echo "  ${folder}: R2 behalten ${kept} · gelöscht ${deleted}"
}

prune_r2() {
  setup_r2_remote
  log "R2-Rotation pro Ordner (neueste N=${BACKUP_KEEP} behalten)"
  local i
  for i in "${!FOLDERS[@]}"; do
    prune_r2_folder "R2:${R2_BUCKET}" "${FOLDERS[$i]}" "${STEMS[$i]}"
  done
  ok "R2-Rotation fertig"
}

if (( DO_UPLOAD == 1 )); then
  if [[ -n "${R2_ACCESS_KEY_ID:-}" ]]; then
    upload_r2
    prune_r2
  else
    echo "  R2_ACCESS_KEY_ID nicht gesetzt — Off-site-Upload übersprungen (nur lokal gesichert)."
  fi
else
  echo "  --no-upload gesetzt — Off-site-Upload + R2-Rotation übersprungen."
fi

log "✓ Backup abgeschlossen (${#STEMS[@]} Dumps: ${STEMS[*]})"
