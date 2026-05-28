#!/usr/bin/env bash
# ============================================================================
# Brewing-Stack Postgres-Backup — Variante A (konsistente Whole-DB-Dumps, off-site)
#
# Marker-gesteuert: welche Jobs laufen, leitet backup.sh aus den installierten
# stateful Units unter $STATEFUL_UNITS_DIR (/etc/brewing/stateful-units.d/) ab.
# Auf einem stateless-only VPS (kein Marker) → sauberer No-op, Exit 0.
#
# ZWEI unabhängige App-DBs, je ein konsistenter Whole-DB-pg_dump -Fc:
#
#   Unit 'db-assistent':
#     docker exec db-assistent pg_dump -Fc -U supabase_admin -d postgres
#       | gpg --batch --symmetric AES256
#       → backups/db-assistent/db-assistent_<TS>[_<label>].fc.gpg
#       → R2 backup/db-assistent/
#     Kein TimescaleDB (keine Hypertables in der assistent-DB).
#
#   Unit 'db-rapt':
#     docker exec db-rapt pg_dump -Fc -U supabase_admin -d postgres
#       | gpg --batch --symmetric AES256
#       → backups/db-rapt/db-rapt_<TS>[_<label>].fc.gpg
#       → R2 backup/db-rapt/
#     TimescaleDB: Hypertables (telemetry_*) — restore.sh erkennt Extension automatisch.
#
#   Unit 'mail':
#     poste-data → tar | gpg → backups/mail/poste_<TS>.tar.gpg → R2 backup/mail/
#
# KONSISTENZ: Ein einzelner pg_dump -Fc erzeugt per Definition EINEN konsistenten
# Transaktions-Snapshot der jeweiligen DB — kein Cross-Dump-FK-Inkonsistenz-Fenster.
#
# PASSWORT-HANDLING: PGPASSWORD wird pro Job via 'docker exec -e PGPASSWORD=…'
# in den Container gesetzt — nie in der Host-argv (nicht ps-sichtbar).
# Passwort-Var wird nur für den aktiven Job geprüft: ein VPS mit nur db-assistent
# schlägt nicht wegen fehlendem RAPT_POSTGRES_PASSWORD fehl.
#
# Manuell:        ./scripts/backup.sh
# Pre-Migration:  ./scripts/backup.sh --label pre-migration   (rotation-exempt)
# Nur lokal:      ./scripts/backup.sh --no-upload
# Aus cron:       /home/alex/webPage_infra/scripts/backup.sh  (nightly ~03:00, als alex)
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

Bekannte Units:
  db-assistent → pg_dump gegen Container db-assistent (ASSISTENT_POSTGRES_PASSWORD)
                 backups/db-assistent/db-assistent_<TS>.fc.gpg → R2 backup/db-assistent/
  db-rapt      → pg_dump gegen Container db-rapt (RAPT_POSTGRES_PASSWORD)
                 backups/db-rapt/db-rapt_<TS>.fc.gpg → R2 backup/db-rapt/
  mail         → tar|gpg des poste-data-Verzeichnisses
                 backups/mail/poste_<TS>.tar.gpg → R2 backup/mail/
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

# unit_jobs <unit>: gibt "folder stem [type]" Tripel aus (je eine Zeile).
# type ist optional: pg (default, pg_dump) oder tar (Verzeichnis-Archiv).
unit_jobs() {
  case "$1" in
    db-assistent)
      # Whole-DB-Dump gegen Container db-assistent (assistent-App-DB, kein TimescaleDB).
      printf '%s\n' "db-assistent db-assistent pg"
      ;;
    db-rapt)
      # Whole-DB-Dump gegen Container db-rapt (rapt-App-DB, TimescaleDB/Hypertables).
      printf '%s\n' "db-rapt db-rapt pg"
      ;;
    mail)
      # poste-data ist ein Verzeichnis (kein Postgres-DB) → tar | gpg statt pg_dump.
      # Ordner: mail, Stem: poste. Dateiname: poste_<TS>.tar.gpg
      printf '%s\n' "mail poste tar"
      ;;
    portainer)
      # Portainer-BoltDB liegt in einem Named-Volume (alexstuder_portainer_data).
      # Hot-Copy ist gefährlich (BoltDB-mmap + halb-committed state nach Restore
      # → korrupte DB), darum stoppt volume_one() den Container für ~5s.
      # Wert: nach Disaster-Recovery ist der Admin-Account, alle Endpoints +
      # Settings sofort da; kein OTP-Setup-Walzer und 5min-Security-Timeout.
      # Ordner: portainer, Stem: portainer. Dateiname: portainer_<TS>.tar.gpg
      printf '%s\n' "portainer portainer volume"
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
declare -a JOB_TYPES=()   # pg = pg_dump, tar = Verzeichnis-Archiv

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
    while IFS=' ' read -r _folder _stem _jtype; do
      FOLDERS+=("$_folder")
      STEMS+=("$_stem")
      JOB_TYPES+=("${_jtype:-pg}")   # default pg für Rückwärtskompatibilität
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

# Container-Checks: pro aktiver DB-Unit den richtigen Container prüfen.
# Fehlt der Container obwohl Marker da → echter Fehlerfall, Hard-Fail korrekt.
if [[ -d "$STATEFUL_UNITS_DIR" ]] && [[ -f "${STATEFUL_UNITS_DIR}/db-assistent" ]]; then
  docker inspect db-assistent >/dev/null 2>&1 \
    || err "Container 'db-assistent' läuft nicht — Stack starten (docker compose ... up -d)"
fi
if [[ -d "$STATEFUL_UNITS_DIR" ]] && [[ -f "${STATEFUL_UNITS_DIR}/db-rapt" ]]; then
  docker inspect db-rapt >/dev/null 2>&1 \
    || err "Container 'db-rapt' läuft nicht — Stack starten (docker compose ... up -d)"
fi

# posteio-Check: nur wenn mail-Job aktiv (Marker gesetzt).
MAIL_CONTAINER="${MAIL_CONTAINER:-posteio}"
if [[ -d "$STATEFUL_UNITS_DIR" ]] && [[ -f "${STATEFUL_UNITS_DIR}/mail" ]]; then
  docker inspect "$MAIL_CONTAINER" >/dev/null 2>&1 \
    || err "Container '$MAIL_CONTAINER' läuft nicht — Stack starten (docker compose up -d posteio)"
fi

# portainer-Check: nur wenn portainer-Marker da. Container MUSS laufen — volume_one()
# wird ihn kurz stoppen, das geht aber nicht wenn er gar nicht existiert.
PORTAINER_CONTAINER="${PORTAINER_CONTAINER:-portainer}"
if [[ -d "$STATEFUL_UNITS_DIR" ]] && [[ -f "${STATEFUL_UNITS_DIR}/portainer" ]]; then
  docker inspect "$PORTAINER_CONTAINER" >/dev/null 2>&1 \
    || err "Container '$PORTAINER_CONTAINER' läuft nicht — Stack starten (docker compose --profile portainer-hub up -d)"
fi

mkdir -p "$BACKUP_DIR"

# .env nur in dieser Subshell laden (kein Leak nach außen) — brauchen
# *_POSTGRES_PASSWORD-Variablen + die R2_*-Variablen.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# ---------------------------------------------------------------- Per-Job: Container + Passwort-Resolver
# db_container_for <folder>: gibt den Container-Namen für einen pg-Job zurück.
db_container_for() {
  case "$1" in
    db-assistent) printf 'db-assistent' ;;
    db-rapt)      printf 'db-rapt' ;;
    *)            err "db_container_for: unbekannter Ordner '$1'" ;;
  esac
}

# db_password_for <folder>: gibt das PGPASSWORD (aus bereits gesourctem .env) zurück.
# Fehlende Var wird hier explizit geprüft (A3: nur die für den aktiven Job nötige Var).
db_password_for() {
  case "$1" in
    db-assistent)
      [[ -n "${ASSISTENT_POSTGRES_PASSWORD:-}" ]] \
        || err "ASSISTENT_POSTGRES_PASSWORD fehlt in .env — für Job 'db-assistent' erforderlich"
      printf '%s' "$ASSISTENT_POSTGRES_PASSWORD"
      ;;
    db-rapt)
      [[ -n "${RAPT_POSTGRES_PASSWORD:-}" ]] \
        || err "RAPT_POSTGRES_PASSWORD fehlt in .env — für Job 'db-rapt' erforderlich"
      printf '%s' "$RAPT_POSTGRES_PASSWORD"
      ;;
    *)
      err "db_password_for: unbekannter Ordner '$1'" ;;
  esac
}

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

TS="$(date +%Y%m%d_%H%M%S)"

# ---------------------------------------------------------------- Dump → GPG
# Ein Whole-DB-Dump pro DB-Unit: ein konsistenter Transaktions-Snapshot.
declare -a PRODUCED_FILES=()   # für Upload + Abschlussreport

dump_one() {
  local folder="$1" stem="$2"
  local dir="${BACKUP_DIR}/${folder}"
  mkdir -p "$dir"
  local base="${stem}_${TS}"
  [[ -n "$LABEL" ]] && base="${base}_${LABEL}"
  local out="${dir}/${base}.fc.gpg"

  # Container + Passwort per-Job bestimmen (A2: kein fixer globaler DB_CONTAINER).
  local container pgpassword
  container="$(db_container_for "$folder")"
  pgpassword="$(db_password_for "$folder")"

  log "Dump '${folder}' → ${folder}/${out##*/}"
  # PGPASSWORD wird im Container gesetzt (-e), erscheint nicht in der Host-argv.
  # Whole-DB-Dump: kein --schema / -n — alle Schemas in einem konsistenten Snapshot.
  # pipefail (oben) macht die Pipe rot, wenn pg_dump fehlschlägt.
  if ! docker exec -e PGPASSWORD="$pgpassword" "$container" \
         pg_dump -Fc -U supabase_admin -d postgres \
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

# ---------------------------------------------------------------- Verzeichnis-Archiv → GPG
# archive_one: wie dump_one, aber statt pg_dump wird ein tar-Archiv des
# poste-data-Verzeichnisses durch gpg gestreamt. Kein Klartext-Tar auf Platte.
# Konvention: <stem>_<TS>.tar.gpg (statt .fc.gpg → Rotation-Regex angepasst).
archive_one() {
  local folder="$1" stem="$2"
  local dir="${BACKUP_DIR}/${folder}"
  mkdir -p "$dir"
  local base="${stem}_${TS}"
  [[ -n "$LABEL" ]] && base="${base}_${LABEL}"
  local out="${dir}/${base}.tar.gpg"

  # N-4 VERIFY: REPO_DIR ist oben via 'cd "$(dirname "$0")/.." && REPO_DIR="$(pwd)"'
  # definiert (Zeile ~61) — zeigt auf das Verzeichnis des compose-Files, in dem
  # ./poste-data liegt. Quellverzeichnis ist damit korrekt $REPO_DIR/poste-data.
  local src_dir="${REPO_DIR}/poste-data"
  [[ -d "$src_dir" ]] \
    || err "archive_one '${folder}': Quellverzeichnis '${src_dir}' nicht gefunden — posteio jemals gestartet?"

  log "Archiv '${folder}' → ${folder}/${out##*/}"
  # tar -C <parent> -cf - <dirname>: relative Namen im Archiv (portabel).
  # pipefail lässt die Pipe rot werden wenn tar fehlschlägt.
  if ! tar -C "$REPO_DIR" -cf - "poste-data" \
       | gpg --batch --yes --symmetric --cipher-algo AES256 \
             --pinentry-mode loopback --passphrase-file "$PASS_TMP" \
             -o "$out"; then
    rm -f "$out"
    err "Archiv '${folder}' fehlgeschlagen (tar | gpg) — unvollständige Datei entfernt"
  fi
  [[ -s "$out" ]] || { rm -f "$out"; err "Archiv '${folder}' ist leer — abgebrochen"; }
  ok "${folder}: $(basename "$out") ($(du -h "$out" | cut -f1))"
  PRODUCED_FILES+=("$out")
}

# ---------------------------------------------------------------- Named-Volume → GPG
# volume_one: sichert ein Docker-Named-Volume (z.B. portainer's BoltDB).
# Stoppt den nutzenden Container kurz (5-15s) für konsistenten Snapshot —
# alternative Hot-Copy einer mmap-BoltDB würde halb-committed state einfangen
# und nach Restore eine korrupte DB liefern. Volume-Name wird LIVE aus dem
# Container abgelesen (nicht hartkodiert) → robust gegen compose-Projekt-Präfix.
volume_one() {
  local folder="$1" stem="$2"
  local dir="${BACKUP_DIR}/${folder}"
  mkdir -p "$dir"
  local base="${stem}_${TS}"
  [[ -n "$LABEL" ]] && base="${base}_${LABEL}"
  local out="${dir}/${base}.tar.gpg"

  # Container-Name = stem (Konvention: marker-name == container-name für volume-units).
  local container="$stem"
  docker inspect "$container" >/dev/null 2>&1 \
    || err "volume_one '${folder}': Container '${container}' nicht gefunden"

  # Volume-Name dynamisch lesen: erstes Volume-Mount (Mount-Typ 'volume') des Containers.
  local vol
  vol="$(docker inspect "$container" --format \
    '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' \
    | head -1)"
  [[ -n "$vol" ]] \
    || err "volume_one '${folder}': Kein named volume an Container '${container}' gefunden"

  log "Volume '${folder}' (${vol}) → ${folder}/${out##*/} — Container ${container} kurz stoppen"

  # Stop → Snapshot → Start, mit Fail-Safe: bei Fehler im Snapshot Container TROTZDEM
  # wieder starten (sonst bleibt Portainer down bis zum nächsten Bootstrap).
  local snap_failed=0
  docker stop -t 30 "$container" >/dev/null \
    || err "volume_one '${folder}': docker stop fehlgeschlagen — kein Backup, kein Snapshot"

  # tar | gpg in einem disposable alpine: kein temp-Klartext-tar auf Platte.
  # -ro mount: Snapshot read-only, kann eh nicht versehentlich schreiben.
  if ! docker run --rm -v "${vol}:/source:ro" alpine \
         tar -cf - -C /source . \
       | gpg --batch --yes --symmetric --cipher-algo AES256 \
             --pinentry-mode loopback --passphrase-file "$PASS_TMP" \
             -o "$out"; then
    snap_failed=1
    rm -f "$out"
  fi

  # Container WIEDER starten — UNBEDINGT, auch wenn Snapshot failed.
  docker start "$container" >/dev/null \
    || err "volume_one '${folder}': docker start fehlgeschlagen — Container '${container}' ist down, manuell prüfen!"

  (( snap_failed == 1 )) && err "Volume-Backup '${folder}' fehlgeschlagen (tar | gpg) — unvollständige Datei entfernt"
  [[ -s "$out" ]] || { rm -f "$out"; err "Volume-Backup '${folder}' ist leer — abgebrochen"; }
  ok "${folder}: $(basename "$out") ($(du -h "$out" | cut -f1))"
  PRODUCED_FILES+=("$out")
}

for i in "${!FOLDERS[@]}"; do
  case "${JOB_TYPES[$i]:-pg}" in
    tar)    archive_one "${FOLDERS[$i]}" "${STEMS[$i]}" ;;
    volume) volume_one  "${FOLDERS[$i]}" "${STEMS[$i]}" ;;
    *)      dump_one    "${FOLDERS[$i]}" "${STEMS[$i]}" ;;
  esac
done

# ---------------------------------------------------------------- Rotation (lokal, PRO ORDNER)
# keep-newest-N: in jedem Ordner die neuesten N automatischen Dumps behalten,
# den Rest löschen. N = $BACKUP_KEEP (default 7). Gelabelte Dumps (--label)
# bleiben rotation-exempt. Dateiname sortiert == chronologisch (TS im Namen).
rotate_folder() {
  local folder="$1" stem="$2" jtype="${3:-pg}"
  local dir="${BACKUP_DIR}/${folder}"
  [[ -d "$dir" ]] || return 0

  # Datei-Extension und Regex hängen vom Job-Typ ab:
  #   pg            → .fc.gpg  (pg_dump custom format)
  #   tar | volume  → .tar.gpg (Verzeichnis-Archiv oder Named-Volume-Snapshot)
  local ext regex
  if [[ "$jtype" == "tar" || "$jtype" == "volume" ]]; then
    ext=".tar.gpg"
    regex="^${stem}_[0-9]{8}_[0-9]{6}$"
  else
    ext=".fc.gpg"
    regex="^${stem}_[0-9]{8}_[0-9]{6}$"
  fi

  local -a files=()
  shopt -s nullglob
  for f in "$dir/${stem}_"[0-9]*_[0-9]*"${ext}"; do
    # Nur automatische Dumps (<stem>_YYYYMMDD_HHMMSS) — gelabelte (mit weiterem
    # _<wort> nach HHMMSS) ausschließen.
    local base; base="$(basename "$f" "${ext}")"
    [[ "$base" =~ $regex ]] && files+=("$f")
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
  rotate_folder "${FOLDERS[$i]}" "${STEMS[$i]}" "${JOB_TYPES[$i]:-pg}"
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
  # Wir konfigurieren komplett via RCLONE_CONFIG_*-Env-Vars (Creds-Hygiene).
  # /dev/null als Config-Datei → unterdrückt das "Config file not found - using
  # defaults"-NOTICE pro Aufruf, ohne dass eine echte Datei rumliegt.
  export RCLONE_CONFIG="/dev/null"
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
#   $2 folder z.B. "db-assistent"
#   $3 stem   z.B. "db-assistent"  (filtert gelabelte Dumps wie das lokale Pendant)
prune_r2_folder() {
  local base="$1" folder="$2" stem="$3" jtype="${4:-pg}"
  local path="${base}/${folder}/"

  # Datei-Extension und Regex hängen vom Job-Typ ab.
  # tar | volume → .tar.gpg ; pg → .fc.gpg.
  local ext rclone_include regex
  if [[ "$jtype" == "tar" || "$jtype" == "volume" ]]; then
    ext=".tar.gpg"
    rclone_include="*.tar.gpg"
    regex="^${stem}_[0-9]{8}_[0-9]{6}\.tar\.gpg$"
  else
    ext=".fc.gpg"
    rclone_include="*.fc.gpg"
    regex="^${stem}_[0-9]{8}_[0-9]{6}\.fc\.gpg$"
  fi

  # rclone lsf: nur Dateinamen, eine Ebene. Auf automatische Dumps filtern
  # (<stem>_YYYYMMDD_HHMMSS.<ext>) → gelabelte bleiben exempt.
  local -a names=()
  while IFS= read -r n; do
    [[ "$n" =~ $regex ]] && names+=("$n")
  done < <(rclone lsf "$path" --include "$rclone_include" 2>/dev/null | sort -r)

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
    prune_r2_folder "R2:${R2_BUCKET}" "${FOLDERS[$i]}" "${STEMS[$i]}" "${JOB_TYPES[$i]:-pg}"
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

log "✓ Backup abgeschlossen (${#STEMS[@]} Jobs: ${STEMS[*]})"
