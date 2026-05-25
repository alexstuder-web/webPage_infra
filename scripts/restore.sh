#!/usr/bin/env bash
# ============================================================================
# Brewing-Stack Postgres-Restore — Variante A (manuell, destruktiv)
#
#   restore.sh <target> [file|latest] [--yes]
#
#   target:  all | aibrewgenius | rapt
#   quelle:  'latest' (default) → jüngste .fc.gpg aus R2 backup/supabase/
#            <pfad>             → lokale .fc.gpg-Datei einspielen
#
#   restore.sh all                         → Whole-DB-Restore (empfohlen, eine Operation)
#   restore.sh all latest                  → Whole-DB aus jüngstem R2-Dump
#   restore.sh aibrewgenius latest         → nur Schema aibrewgenius, aus jüngstem R2-Dump
#   restore.sh rapt backups/supabase/supabase_20260523_030000.fc.gpg
#                                          → nur Schema rapt, aus lokalem Dump
#
# Flow:
#   (R2 holen) → entschlüsseln (gpg, kein Klartext-Dump bleibt liegen) →
#   pg_restore --clean --if-exists --no-owner [-schema=<schema>] -U supabase_admin -d postgres
#
# QUELLE: alle Ziele lesen aus demselben einen Dump (R2 backup/supabase/).
# 'all' = ein Whole-DB pg_restore ohne --schema. 'aibrewgenius'/'rapt' = selektiver
# pg_restore --schema=<name> aus demselben Dump.
#
# ⚠️  SELEKTIVER RESTORE (aibrewgenius/rapt): setzt voraus, dass die FK-Ziele in
#     auth.* und vault.* zum Stand des Dumps passen. Für Disaster Recovery /
#     VPS-Umzug immer 'all' (Whole-DB) verwenden. Selektiv ist nur für gezielte
#     Einzel-Schema-Rollbacks, bei denen core unverändert bleibt.
#
# ⚠️  --clean droppt vorhandene Objekte vor dem Neuanlegen. Läuft NIE ohne
#     explizites Ziel-Argument + interaktive Bestätigung (oder --yes).
#
# Voraussetzung: laufender Stack (Image-Init hat Roles/Schemas angelegt).
# Restore ist bewusst NICHT Teil von bootstrap.sh.
#
# PASSPHRASE-QUELLE (gleiche Passphrase wie .env.gpg), in dieser Reihenfolge:
#   1. --passphrase-file $GPG_PASS_FILE (default /etc/brewing/gpg.pass).
#      Auf dem VPS gehört diese Datei alex (mode 600) → manueller Restore als
#      alex liest sie automatisch, kein Export nötig.
#   2. $GPG_PASSPHRASE (Env) — wenn die Datei fehlt/nicht lesbar ist:
#         export GPG_PASSPHRASE="$(bw get password ALEXSTUDER_WEBPAGE_GPG_PASSWORD)"
#   3. interaktiver Prompt (nur mit TTY).
# Die Passphrase landet immer in einer mode-600-Tempdatei (--passphrase-file),
# nie auf der Kommandozeile/in ps.
# ============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_DIR="$(pwd)"
ENV_FILE="${REPO_DIR}/.env"
DB_CONTAINER="${DB_CONTAINER:-supabase-db}"
PASS_FILE="${GPG_PASS_FILE:-/etc/brewing/gpg.pass}"

# ---------------------------------------------------------------- Helpers
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\n\033[1;31m✖ $*\033[0m" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: $0 <all|aibrewgenius|rapt> [file|latest] [--yes]

  all              Whole-DB-Restore aus dem supabase/-Dump (empfohlen).
                   Ein einziger pg_restore ohne --schema — stellt alle Schemas wieder her.
  aibrewgenius     Selektiver Restore: nur Schema aibrewgenius aus dem supabase/-Dump.
  rapt             Selektiver Restore: nur Schema rapt aus dem supabase/-Dump.

  [file|latest]    'latest' (default) zieht die jüngste .fc.gpg aus R2 backup/supabase/.
                   Ein Pfad spielt eine lokale Datei ein (funktioniert mit allen Zielen,
                   da alle Ziele aus demselben einen Dump lesen).
  --yes            Sicherheitsabfrage überspringen (für Automatisierung).

  WARNUNG selektiv: aibrewgenius/rapt setzen voraus, dass FK-Ziele in auth.*/vault.*
  zum Stand des Dumps passen. Für Disaster Recovery immer 'all' verwenden.

  Beispiele:
    $0 all
    $0 all latest
    $0 rapt latest
    $0 aibrewgenius backups/supabase/supabase_20260523_030000.fc.gpg
EOF
  exit 1
}

# Alle Ziele lesen aus demselben einen R2-Ordner: supabase/.
target_folder() {
  case "$1" in
    all|aibrewgenius|rapt) echo "supabase" ;;
    *) err "Unbekanntes Ziel: $1" ;;
  esac
}

# pg_restore --schema-Argument je Ziel.
# all → kein --schema (Whole-DB). aibrewgenius/rapt → selektiv.
restore_schema_arg() {
  case "$1" in
    all)          echo "" ;;
    aibrewgenius) echo "--schema=aibrewgenius" ;;
    rapt)         echo "--schema=rapt" ;;
    *)            err "Unbekanntes Ziel: $1" ;;
  esac
}

# ---------------------------------------------------------------- Args
[[ $# -ge 1 ]] || usage   # nie ohne explizites Ziel
TARGET=""
SOURCE=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    -*)        err "Unbekanntes Argument: $1" ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      elif [[ -z "$SOURCE" ]]; then
        SOURCE="$1"
      else
        err "Zu viele Positions-Argumente ('$1')"
      fi
      shift ;;
  esac
done
[[ -n "$TARGET" ]] || usage
case "$TARGET" in all|aibrewgenius|rapt) ;; *) err "Ungültiges Ziel '$TARGET'"; ;; esac
[[ -n "$SOURCE" ]] || SOURCE="latest"
# Kein all+non-latest-Verbot mehr: es gibt genau einen Dump-Ordner (supabase/),
# ein expliziter Dateipfad ist daher mit allen Zielen eindeutig verwendbar.

# ---------------------------------------------------------------- Pre-flight
command -v docker >/dev/null 2>&1 || err "docker fehlt"
command -v gpg    >/dev/null 2>&1 || err "gpg fehlt"
[[ -f "$ENV_FILE" ]] || err "Keine .env — erst ./scripts/decrypt-env.sh"
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 \
  || err "Container '$DB_CONTAINER' läuft nicht — Stack starten"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
: "${POSTGRES_PASSWORD:?fehlt in .env}"

# ---------------------------------------------------------------- Temp-Workspace
WORK_DIR="$(mktemp -d)"
chmod 700 "$WORK_DIR"
PASS_TMP="$(mktemp)"
chmod 600 "$PASS_TMP"
# Räumt ALLES weg: entschlüsselte Dumps + Passphrase, auch bei Abbruch.
trap 'rm -rf "$WORK_DIR"; rm -f "$PASS_TMP"' EXIT

# ---------------------------------------------------------------- Passphrase
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

# ---------------------------------------------------------------- R2-Remote (für 'latest')
R2_READY=0
setup_r2_remote() {
  (( R2_READY == 1 )) && return 0
  : "${R2_ACCESS_KEY_ID:?fehlt in .env (R2 für 'latest')}"
  : "${R2_SECRET_ACCESS_KEY:?fehlt in .env}"
  : "${R2_BUCKET:?fehlt in .env}"
  local endpoint="${R2_ENDPOINT:-}"
  if [[ -z "$endpoint" ]]; then
    : "${R2_ACCOUNT_ID:?fehlt in .env (R2_ENDPOINT oder R2_ACCOUNT_ID nötig)}"
    endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  fi
  command -v rclone >/dev/null 2>&1 || err "rclone fehlt — für 'latest' nötig (bootstrap installiert es)"
  # Creds via Env-Vars, NICHT in argv (nicht ps-sichtbar).
  export RCLONE_CONFIG_R2_TYPE="s3"
  export RCLONE_CONFIG_R2_PROVIDER="Cloudflare"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_ENDPOINT="$endpoint"
  export RCLONE_CONFIG_R2_REGION="auto"
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET="true"
  R2_READY=1
}

# Holt die jüngste .fc.gpg eines R2-Ordners → lokale Tempdatei, gibt Pfad aus.
# 'Jüngste' = lexikografisch letzter Name nach sort — entspricht chronologisch
# letztem nur wenn Dateinamen den Timestamp-Stem <name>_YYYYMMDD_HHMMSS tragen
# (wie backup.sh ihn erzeugt). Abweichende Namenskonventionen → kein Fallback.
fetch_latest_from_r2() {
  local folder="$1"
  setup_r2_remote
  local latest
  latest="$(rclone lsf "R2:${R2_BUCKET}/${folder}/" --include '*.fc.gpg' 2>/dev/null \
            | sort | tail -1)"
  [[ -n "$latest" ]] || err "Kein *.fc.gpg in R2 ${R2_BUCKET}/${folder}/ gefunden"
  local dest="${WORK_DIR}/${folder}__${latest}"
  rclone copyto "R2:${R2_BUCKET}/${folder}/${latest}" "$dest" \
    || err "rclone-Download fehlgeschlagen: ${folder}/${latest}"
  echo "$dest"
}

# ---------------------------------------------------------------- Ein Ziel restoren
restore_one() {
  local target="$1" source="$2"
  local folder; folder="$(target_folder "$target")"
  local enc_file desc

  if [[ "$source" == "latest" ]]; then
    log "[$target] Jüngste .fc.gpg aus R2 ${R2_BUCKET:-?}/${folder}/ holen"
    enc_file="$(fetch_latest_from_r2 "$folder")"
    desc="R2:${folder}/$(basename "${enc_file#*__}")"
    ok "[$target] geholt: $(basename "$enc_file")"
  else
    [[ -f "$source" ]] || err "Datei nicht gefunden: $source"
    enc_file="$source"
    desc="$source"
  fi

  # Entschlüsseln in den Workspace (kein Klartext-Dump bleibt liegen).
  local dump="${WORK_DIR}/${target}.fc"
  gpg --batch --yes --decrypt --pinentry-mode loopback \
      --passphrase-file "$PASS_TMP" -o "$dump" "$enc_file" \
    || err "[$target] Entschlüsselung fehlgeschlagen (falsche Passphrase / korrupte Datei?)"
  [[ -s "$dump" ]] || err "[$target] Entschlüsselter Dump ist leer"

  # Schema-Argumente: all → kein --schema (Whole-DB). aibrewgenius/rapt → selektiv.
  local _sa _sa_str schema_args=()
  _sa="$(restore_schema_arg "$target")"
  if [[ -n "$_sa" ]]; then
    schema_args=("$_sa")
    _sa_str=" (selektiv: ${_sa})"
    # D4-Warnung: selektiver Restore setzt konsistenten core voraus.
    echo "  WARNUNG: Selektiver Schema-Restore. FK-Ziele in auth.*/vault.* müssen"
    echo "           zum Stand dieses Dumps passen — sonst FK-Verletzungen möglich."
    echo "           Für Disaster Recovery / VPS-Umzug: 'all' (Whole-DB) verwenden."
  else
    _sa_str=" (Whole-DB)"
  fi

  log "[$target] pg_restore${_sa_str} (Quelle: ${desc})"
  echo "  Ziel: Container ${DB_CONTAINER} → DB 'postgres' (--clean --if-exists --no-owner)"

  # ---- TimescaleDB-Restore-Hooks (bedingt) ----
  # timescaledb_pre_restore() / timescaledb_post_restore() existieren nur wenn die
  # Extension installiert ist. Ohne die Hooks bleibt der Hypertable-Katalog
  # (_timescaledb_catalog) inkonsistent → Chunk-Verknüpfung kaputt → 0 Rows bei
  # Telemetrie-Queries trotz physisch vorhandener Chunk-Tabellen.
  #
  # Guard: prüft ob die Extension vorhanden ist, BEVOR pre_restore aufgerufen wird.
  # Wenn nicht installiert: sauberer Skip (kein Abbruch — Plain-Table-Dumps laufen ohne Hooks).
  #
  # post_restore MUSS auch laufen wenn pg_restore selbst non-zero zurückgibt (Supabase
  # emittiert bekannte nicht-fatale Fehler); sonst bleibt die DB im pre-restore-Modus.
  # Implementierung: _tsdb_active-Flag; unbedingter `if (( _tsdb_active ))`-Block nach
  # pg_restore; bei Fehler: err() — kein irreführendes OK-Signal.
  local _tsdb_active=0
  local _tsdb_pre_rc=0 _tsdb_post_rc=0

  local _tsdb_present _tsdb_guard_rc=0
  _tsdb_present="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -tA -U supabase_admin -d postgres \
    -c "SELECT count(*) FROM pg_extension WHERE extname = 'timescaledb';" 2>/dev/null)" \
    || _tsdb_guard_rc=$?
  if (( _tsdb_guard_rc != 0 )); then
    err "[$target] TimescaleDB-Präsenz nicht ermittelbar (psql Exit-Code ${_tsdb_guard_rc}) — DB-Verbindung prüfen, bevor restauriert wird"
  fi
  _tsdb_present="${_tsdb_present//[[:space:]]/}"

  if [[ "$_tsdb_present" == "1" ]]; then
    _tsdb_active=1
    log "[$target] TimescaleDB gefunden — timescaledb_pre_restore() aufrufen"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
      psql -U supabase_admin -d postgres \
      -c "SELECT public.timescaledb_pre_restore();" \
      || { _tsdb_pre_rc=$?
           echo "  [$target] WARNUNG: timescaledb_pre_restore() Exit-Code ${_tsdb_pre_rc} — Restore wird trotzdem versucht." >&2; }
  else
    echo "  [$target] TimescaleDB nicht installiert — Restore-Hooks übersprungen (plain tables)."
  fi

  # Sicherstellen: post_restore läuft unbedingt nach pg_restore, auch bei pg_restore-Fehler.
  # Implementierung: _tsdb_active-Flag; unbedingter `if (( _tsdb_active ))`-Block nach
  # pg_restore (Exit-Code via `|| rc=$?` eingefangen, set-e bleibt aktiv).
  # Bei post_restore-Fehler: err() bricht ab — kein irreführendes OK-Signal.

  # pg_restore wird NICHT mit -e/--exit-on-error aufgerufen: Supabase emittiert
  # bekannte nicht-fatale Fehler (supabase_realtime-Publication, extensions-Schema,
  # pgsodium/Vault, bereits vom Image angelegte Roles). Erfolg wird über die
  # Tabellen-Counts/Smoke-Check bewertet, nicht über den Exit-Code.
  #
  # Exit-Code via '|| rc=$?' einfangen, OHNE set-State zu togglen: das ist ein
  # einzelner Befehl (kein Pipe → pipefail irrelevant) und der '|| ...'-Zweig
  # neutralisiert errexit nur für genau dieses Kommando. Kein 'set +e/-e'-Paar,
  # das bei vorzeitigem Abbruch errexit dauerhaft falsch hinterlassen könnte.
  local rc=0
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    pg_restore --clean --if-exists --no-owner "${schema_args[@]}" \
               -U supabase_admin -d postgres < "$dump" \
    || rc=$?
  if (( rc != 0 )); then
    echo "  [$target] pg_restore Exit-Code: $rc — bei Supabase oft nicht-fatal (s. README)."
  fi

  # ---- TimescaleDB post_restore — unbedingt ausführen (auch bei pg_restore-Fehler) ----
  if (( _tsdb_active == 1 )); then
    log "[$target] timescaledb_post_restore() aufrufen (unbedingt, auch nach pg_restore-Fehler)"
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
      psql -U supabase_admin -d postgres \
      -c "SELECT public.timescaledb_post_restore();" \
      || { _tsdb_post_rc=$?
           echo "  [$target] FEHLER: timescaledb_post_restore() Exit-Code ${_tsdb_post_rc} — Hypertable-Katalog ggf. inkonsistent!" >&2; }
    if (( _tsdb_post_rc == 0 )); then
      ok "[$target] TimescaleDB post_restore OK"
    else
      rm -f "$dump"
      err "[$target] timescaledb_post_restore() fehlgeschlagen (Exit-Code ${_tsdb_post_rc}) — DB NICHT vertrauen, DB befindet sich ggf. im pre-restore-Modus. Manueller Eingriff nötig."
    fi
  fi

  rm -f "$dump"
  ok "[$target] pg_restore durchgelaufen"
}

# ---------------------------------------------------------------- Verifikation
verify_count() {
  local schema="$1" tbl="$2"
  local n
  n="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
        psql -tA -U supabase_admin -d postgres \
        -c "SELECT count(*) FROM ${schema}.${tbl};" 2>/dev/null || echo "n/a")"
  printf '  %-32s %s\n' "${schema}.${tbl}" "$n"
}

# ---------------------------------------------------------------- Plan + Bestätigung
# 'all' = ein Whole-DB pg_restore (kein --schema). Selektive Ziele = ein pg_restore
# mit --schema=<name> aus demselben supabase/-Dump. Core-first-Reihenfolge entfällt.
declare -a PLAN=("$TARGET")

log "RESTORE — destruktiv"
echo "  Ziel:        ${TARGET}"
echo "  Quelle:      ${SOURCE}"
echo "  Dump-Ordner: supabase/"
echo "  Ziel-DB:     Container ${DB_CONTAINER} → DB 'postgres'"
echo "  Hinweis:     --clean --if-exists droppt vorhandene Objekte vor dem Neuanlegen."
echo
if (( ASSUME_YES == 0 )); then
  [[ -t 0 ]] || err "Kein TTY und kein --yes — Restore aus Sicherheitsgründen abgebrochen"
  read -rp "Wirklich einspielen? Tippe 'restore' zum Bestätigen: " ans
  [[ "$ans" == "restore" ]] || err "Abgebrochen (keine Bestätigung)"
fi

# ---------------------------------------------------------------- Ausführung (in Reihenfolge)
for t in "${PLAN[@]}"; do
  restore_one "$t" "$SOURCE"
done

# ---------------------------------------------------------------- Verifikation
log "Verifikation (Tabellen-Counts je Schema)"
case "$TARGET" in
  all)
    # Whole-DB: alle relevanten Counts prüfen.
    # Hypertable-Counts (telemetry_*): 0 nach Restore = starker Indikator für
    # kaputte Chunk-Verknüpfung (TimescaleDB post_restore nicht gelaufen oder fehlgeschlagen).
    verify_count auth users
    verify_count aibrewgenius recipes 2>/dev/null || true
    verify_count rapt brew_sessions 2>/dev/null || true
    verify_count rapt telemetry_controllers 2>/dev/null || true
    verify_count rapt telemetry_hydrometers 2>/dev/null || true
    ;;
  aibrewgenius)
    verify_count aibrewgenius recipes 2>/dev/null || true
    ;;
  rapt)
    # Hypertable-Counts mit || true: ein 0-Count nach Restore ist DER Indikator
    # für kaputte TimescaleDB-Chunk-Verknüpfung (post_restore fehlgeschlagen/fehlt).
    verify_count rapt brew_sessions 2>/dev/null || true
    verify_count rapt telemetry_controllers 2>/dev/null || true
    verify_count rapt telemetry_hydrometers 2>/dev/null || true
    ;;
esac

log "✓ Restore abgeschlossen"
echo "  Nächster Smoke-Check: Login in der App + je eine Query auf aibrewgenius.* und rapt.*"
echo "  Für selektive Restores: FK-Konsistenz zu auth.*/vault.* manuell prüfen (→ README §8)."
