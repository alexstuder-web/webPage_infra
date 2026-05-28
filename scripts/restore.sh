#!/usr/bin/env bash
# ============================================================================
# Brewing-Stack Postgres-Restore — Variante A (manuell, destruktiv)
#
#   restore.sh <target> [file|latest] [--yes]
#
#   target:  all | db-assistent | db-rapt | portainer
#
# 'portainer' ist ein Sonder-Target: KEIN psql/pg_restore, sondern tar-Restore
# des portainer_data-Volumes (Admin-Hash, Settings, Endpoints, JWT-Secret).
# Container wird kurz gestoppt, Volume geleert, tar-Archiv eingespielt, Container
# startet wieder → nach Login ist Admin sofort wieder da, kein OTP-Setup nötig.
#   quelle:  'latest' (default) → jüngste .fc.gpg aus R2 backup/<target>/
#            <pfad>             → lokale .fc.gpg-Datei einspielen
#                                 (nur für ein einzelnes Ziel; bei 'all' + Pfad → Fehler)
#
#   restore.sh all                             → beide DBs restoren (latest aus je eigenem Ordner)
#   restore.sh db-assistent latest             → db-assistent aus jüngstem R2-Dump
#   restore.sh db-rapt latest                  → db-rapt aus jüngstem R2-Dump (TimescaleDB-Hooks)
#   restore.sh db-rapt backups/db-rapt/db-rapt_20260525_030000.fc.gpg
#                                              → db-rapt aus lokaler Datei
#
# Flow pro DB:
#   (R2 holen) → entschlüsseln (gpg, kein Klartext-Dump bleibt liegen) →
#   pg_restore --clean --if-exists --no-owner -U supabase_admin -d postgres
#   (TimescaleDB pre/post_restore-Hooks automatisch per pg_extension-Guard)
#
# TimescaleDB-Handling:
#   - db-rapt: Hat Hypertables → Guard erkennt 'timescaledb'-Extension, ruft
#     timescaledb_pre_restore() VOR und timescaledb_post_restore() NACH pg_restore.
#     post_restore MUSS nach pg_restore laufen — auch bei pg_restore-Fehlern.
#     Bei post_restore-Fehler: harter Abbruch (DB nicht vertrauen).
#   - db-assistent: Keine Hypertables → Guard erkennt fehlende Extension, Skip.
#   Guard ist NICHT hardgekodiert auf "nur db-rapt" — er prüft die Extension
#   zur Laufzeit im jeweiligen Container (zukunftssicher).
#
# QUELLE: jede DB hat ihren eigenen R2-Ordner:
#   db-assistent → R2 backup/db-assistent/
#   db-rapt      → R2 backup/db-rapt/
# 'all' = beide DBs nacheinander, jede aus ihrem eigenen Ordner.
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
PASS_FILE="${GPG_PASS_FILE:-/etc/brewing/gpg.pass}"

# ---------------------------------------------------------------- Helpers
log()  { echo -e "\n\033[1;34m▶ $*\033[0m"; }
ok()   { echo -e "\033[1;32m  ✓ $*\033[0m"; }
err()  { echo -e "\n\033[1;31m✖ $*\033[0m" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: $0 <all|db-assistent|db-rapt|portainer> [file|latest] [--yes]

  all              Beide DBs restoren (jede aus ihrem eigenen R2-Ordner, latest).
                   Nur mit 'latest' kombinierbar — ein Dateipfad kann nicht beide
                   DBs füttern. Für all + Pfad: Fehler.
  db-assistent     Whole-DB-Restore aus backup/db-assistent/ (kein TimescaleDB).
  db-rapt          Whole-DB-Restore aus backup/db-rapt/ (TimescaleDB-Hooks auto).
  portainer        Volume-Restore aus backup/portainer/ (Admin-Hash, Settings,
                   Endpoints, JWT). Container kurz down (~5s).

  [file|latest]    'latest' (default) zieht den jüngsten Dump aus dem eigenen
                   R2-Ordner (.fc.gpg für DBs, .tar.gpg für portainer).
                   Ein Pfad spielt eine lokale Datei ein (nur für ein einzelnes Ziel).
  --yes            Sicherheitsabfrage überspringen (für Automatisierung).

  Beispiele:
    $0 all
    $0 all latest
    $0 db-rapt latest
    $0 portainer latest
    $0 db-assistent backups/db-assistent/db-assistent_20260525_030000.fc.gpg
EOF
  exit 1
}

# ---------------------------------------------------------------- Per-Target: Container + Passwort
# db_container_for <target>: Container-Name für das Restore-Ziel.
db_container_for() {
  case "$1" in
    db-assistent) printf 'db-assistent' ;;
    db-rapt)      printf 'db-rapt' ;;
    portainer)    printf 'portainer' ;;
    *)            err "db_container_for: unbekanntes Ziel '$1'" ;;
  esac
}

# db_password_for <target>: PGPASSWORD aus dem bereits gesourcten .env.
db_password_for() {
  case "$1" in
    db-assistent)
      [[ -n "${ASSISTENT_POSTGRES_PASSWORD:-}" ]] \
        || err "ASSISTENT_POSTGRES_PASSWORD fehlt in .env — für Ziel 'db-assistent' erforderlich"
      printf '%s' "$ASSISTENT_POSTGRES_PASSWORD"
      ;;
    db-rapt)
      [[ -n "${RAPT_POSTGRES_PASSWORD:-}" ]] \
        || err "RAPT_POSTGRES_PASSWORD fehlt in .env — für Ziel 'db-rapt' erforderlich"
      printf '%s' "$RAPT_POSTGRES_PASSWORD"
      ;;
    *)
      err "db_password_for: unbekanntes Ziel '$1'" ;;
  esac
}

# app_schema_for <target>: PostgreSQL-Schema-Name der App, wird zur "frische DB"-
# Erkennung benutzt. db-rapt → "rapt", db-assistent → "aibrewgenius".
app_schema_for() {
  case "$1" in
    db-assistent) printf 'aibrewgenius' ;;
    db-rapt)      printf 'rapt' ;;
    *)            err "app_schema_for: unbekanntes Ziel '$1'" ;;
  esac
}

# target_folder <target>: R2-Ordner für ein einzelnes Ziel.
target_folder() {
  case "$1" in
    db-assistent) printf 'db-assistent' ;;
    db-rapt)      printf 'db-rapt' ;;
    portainer)    printf 'portainer' ;;
    *)            err "target_folder: unbekanntes Ziel '$1'" ;;
  esac
}

# target_kind <target>: 'pg' (Postgres-DB) oder 'volume' (Docker-Volume).
# Dispatch-Hilfe für restore_one() — der Volume-Pfad hat eine ganz andere
# Mechanik (kein psql, kein TimescaleDB-Wrap, kein --clean-Heuristik).
target_kind() {
  case "$1" in
    db-assistent|db-rapt) printf 'pg' ;;
    portainer)            printf 'volume' ;;
    *)                    err "target_kind: unbekanntes Ziel '$1'" ;;
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
case "$TARGET" in all|db-assistent|db-rapt|portainer) ;; *) err "Ungültiges Ziel '$TARGET' (erwartet: all|db-assistent|db-rapt|portainer)"; ;; esac
[[ -n "$SOURCE" ]] || SOURCE="latest"

# 'all' + expliziter Pfad ist nicht sinnvoll (ein Dump kann nicht beide DBs füttern).
if [[ "$TARGET" == "all" && "$SOURCE" != "latest" ]]; then
  err "Ziel 'all' ist nur mit 'latest' kombinierbar (ein Dateipfad kann nicht beide DBs füttern).
   Für einzelne DB mit Dateipfad: restore.sh db-assistent <pfad> bzw. restore.sh db-rapt <pfad>"
fi

# ---------------------------------------------------------------- Pre-flight
command -v docker >/dev/null 2>&1 || err "docker fehlt"
command -v gpg    >/dev/null 2>&1 || err "gpg fehlt"
[[ -f "$ENV_FILE" ]] || err "Keine .env — erst ./scripts/decrypt-env.sh"

# Container-Checks pro Ziel
_check_container() {
  local t="$1"
  local c; c="$(db_container_for "$t")"
  docker inspect "$c" >/dev/null 2>&1 \
    || err "Container '$c' läuft nicht — Stack starten (docker compose ... up -d)"
}
case "$TARGET" in
  all)
    # 'all' deckt nur die DBs ab — portainer ist explizit aufzurufen, weil
    # Volume-Restore eine Downtime hat und semantisch nichts mit DB-Restore zu tun.
    _check_container db-assistent
    _check_container db-rapt
    ;;
  db-assistent|db-rapt|portainer)
    _check_container "$TARGET"
    ;;
esac

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

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
  # Komplett via Env-Vars konfiguriert → /dev/null als Config-Datei unterdrückt
  # das "Config file not found"-NOTICE pro Aufruf (siehe backup.sh:setup_r2_remote).
  export RCLONE_CONFIG="/dev/null"
  R2_READY=1
}

# Holt den jüngsten Dump eines R2-Ordners → lokale Tempdatei, gibt Pfad aus.
# 'Jüngste' = lexikografisch letzter Name nach sort — entspricht chronologisch
# letztem nur wenn Dateinamen den Timestamp-Stem <name>_YYYYMMDD_HHMMSS tragen
# (wie backup.sh ihn erzeugt). Abweichende Namenskonventionen → kein Fallback.
# $2: glob-Pattern ('*.fc.gpg' für DBs, '*.tar.gpg' für Volume-Units).
fetch_latest_from_r2() {
  local folder="$1" glob="${2:-*.fc.gpg}"
  setup_r2_remote
  local latest
  latest="$(rclone lsf "R2:${R2_BUCKET}/${folder}/" --include "$glob" 2>/dev/null \
            | sort | tail -1)"
  [[ -n "$latest" ]] || err "Kein ${glob} in R2 ${R2_BUCKET}/${folder}/ gefunden"
  local dest="${WORK_DIR}/${folder}__${latest}"
  rclone copyto "R2:${R2_BUCKET}/${folder}/${latest}" "$dest" \
    || err "rclone-Download fehlgeschlagen: ${folder}/${latest}"
  echo "$dest"
}

# ---------------------------------------------------------------- Volume-Restore (portainer)
# Spielt einen .tar.gpg-Snapshot zurück in das Named-Volume des Container-Targets.
# Mechanik (analog zur Vorlage uglyatbeautymolt/VPS_Bootstrap, kompatibel mit
# backup.sh:volume_one): container stop → Volume leeren → tar extrahieren →
# container start. Volume-Name wird LIVE aus dem Container gelesen (robust
# gegen compose-Projekt-Präfix wie 'alexstuder_portainer_data').
restore_one_volume() {
  local target="$1" source="$2"
  local folder; folder="$(target_folder "$target")"
  local container; container="$(db_container_for "$target")"
  local enc_file desc

  if [[ "$source" == "latest" ]]; then
    log "[$target] Jüngste .tar.gpg aus R2 ${R2_BUCKET:-?}/${folder}/ holen"
    enc_file="$(fetch_latest_from_r2 "$folder" '*.tar.gpg')"
    desc="R2:${folder}/$(basename "${enc_file#*__}")"
    ok "[$target] geholt: $(basename "$enc_file")"
  else
    [[ -f "$source" ]] || err "Datei nicht gefunden: $source"
    enc_file="$source"
    desc="$source"
  fi

  local tar_out="${WORK_DIR}/${target}.tar"
  gpg --batch --yes --decrypt --pinentry-mode loopback \
      --passphrase-file "$PASS_TMP" -o "$tar_out" "$enc_file" \
    || err "[$target] Entschlüsselung fehlgeschlagen (falsche Passphrase / korrupte Datei?)"
  [[ -s "$tar_out" ]] || err "[$target] Entschlüsseltes Archiv ist leer"

  # Volume-Name live ablesen.
  local vol
  vol="$(docker inspect "$container" --format \
    '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' \
    | head -1)"
  [[ -n "$vol" ]] || { rm -f "$tar_out"; err "[$target] Kein named volume an '$container' — kann nicht restoren"; }

  log "[$target] Volume-Restore (Quelle: ${desc}, Volume: ${vol})"
  echo "  Container ${container} kurz stoppen, Volume leeren, tar einspielen"

  docker stop -t 30 "$container" >/dev/null \
    || { rm -f "$tar_out"; err "[$target] docker stop fehlgeschlagen — kein Restore"; }

  # Volume leeren + tar extrahieren in einem alpine-Lauf. tar liest vom stdin → kein
  # Klartext-tar im Container bleiben. Bei Fehler: trotzdem Container wieder starten.
  local restore_failed=0
  if ! docker run --rm -i -v "${vol}:/target" alpine \
         sh -c 'rm -rf /target/* /target/.[!.]* /target/..?* 2>/dev/null; tar -xf - -C /target' \
         < "$tar_out"; then
    restore_failed=1
  fi

  docker start "$container" >/dev/null \
    || err "[$target] docker start fehlgeschlagen — Container '${container}' down, manuell prüfen!"

  rm -f "$tar_out"
  (( restore_failed == 1 )) && err "[$target] tar-Extract fehlgeschlagen — Volume ggf. halb leer"
  ok "[$target] Volume-Restore abgeschlossen — Container neu gestartet"
}

# ---------------------------------------------------------------- Ein Ziel restoren
restore_one() {
  local target="$1" source="$2"

  # Dispatch nach Target-Art: Volume-Units gehen den tar-Pfad,
  # DB-Units gehen den pg_restore-Pfad (Rest dieser Funktion).
  if [[ "$(target_kind "$target")" == "volume" ]]; then
    restore_one_volume "$target" "$source"
    return
  fi

  local folder; folder="$(target_folder "$target")"
  local container; container="$(db_container_for "$target")"
  local pgpassword; pgpassword="$(db_password_for "$target")"
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

  log "[$target] pg_restore Whole-DB (Quelle: ${desc})"

  # ---- Frische-DB-Erkennung: --clean konditional ----
  # `--clean --if-exists` ist im Migrations-Pfad nötig (DB läuft schon mit alten
  # Daten — pg_restore muss vor dem Insert droppen). Bei Disaster-Recovery in
  # eine FRISCHE supabase/postgres-DB crasht --clean aber den Container:
  # pg_restore versucht Objekte aus extensions/auth zu droppen, die der
  # Supabase-Init gerade frisch aufgebaut hat → Backend-Worker bricht ab →
  # postgres reagiert mit shutdown. Smoke-Test 2026-05-28 beobachtet.
  #
  # Heuristik "frisch": das App-Schema (aibrewgenius/rapt) existiert noch nicht.
  # Das schema wird erst von Migrations oder vom Restore selbst angelegt; eine
  # rein per supabase-init initialisierte DB hat es garantiert nicht. Damit ist
  # der Test 100% trennscharf zwischen "frisch hochgezogen" und "läuft schon".
  local app_schema; app_schema="$(app_schema_for "$target")"
  local _schema_exists _schema_rc=0
  _schema_exists="$(docker exec -e PGPASSWORD="$pgpassword" "$container" \
    psql -tA -U supabase_admin -d postgres \
    -c "SELECT count(*) FROM information_schema.schemata WHERE schema_name = '${app_schema}';" 2>/dev/null)" \
    || _schema_rc=$?
  if (( _schema_rc != 0 )); then
    err "[$target] Schema-Existenz-Probe scheiterte (psql Exit ${_schema_rc}) — DB-Verbindung prüfen"
  fi
  _schema_exists="${_schema_exists//[[:space:]]/}"

  local _pgr_clean_args=()
  if [[ "$_schema_exists" == "0" ]]; then
    echo "  Frische DB erkannt (Schema '${app_schema}' fehlt) → pg_restore OHNE --clean"
    echo "  Ziel: Container ${container} → DB 'postgres' (--no-owner --no-acl)"
  else
    _pgr_clean_args=(--clean --if-exists)
    echo "  Schema '${app_schema}' vorhanden → pg_restore MIT --clean --if-exists"
    echo "  Ziel: Container ${container} → DB 'postgres' (--clean --if-exists --no-owner --no-acl)"
  fi

  # ---- TimescaleDB-Restore-Hooks (bedingt) ----
  # timescaledb_pre_restore() / timescaledb_post_restore() existieren nur wenn die
  # Extension installiert ist. Ohne die Hooks bleibt der Hypertable-Katalog
  # (_timescaledb_catalog) inkonsistent → Chunk-Verknüpfung kaputt → 0 Rows bei
  # Telemetrie-Queries trotz physisch vorhandener Chunk-Tabellen.
  #
  # Guard: prüft ob die Extension vorhanden ist, BEVOR pre_restore aufgerufen wird.
  # NICHT hardgekodiert auf "nur db-rapt" — erkennt Extension zur Laufzeit pro Container.
  #
  # Skip-vs-Abort-Diskriminierung (Lesson 2026-05-25):
  #   psql-Fehler (Exit != 0) beim Guard ≠ "Extension absent" → harter Abbruch.
  #   Nur "COUNT=0" bedeutet sicher absent → sauberer Skip.
  #
  # post_restore MUSS auch laufen wenn pg_restore selbst non-zero zurückgibt (Supabase
  # emittiert bekannte nicht-fatale Fehler); sonst bleibt die DB im pre-restore-Modus.
  # Implementierung: _tsdb_active-Flag; unbedingter `if (( _tsdb_active ))`-Block nach
  # pg_restore; bei Fehler: err() — kein irreführendes OK-Signal.
  local _tsdb_active=0
  local _tsdb_pre_rc=0 _tsdb_post_rc=0

  local _tsdb_present _tsdb_guard_rc=0
  _tsdb_present="$(docker exec -e PGPASSWORD="$pgpassword" "$container" \
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
    docker exec -e PGPASSWORD="$pgpassword" "$container" \
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
  docker exec -i -e PGPASSWORD="$pgpassword" "$container" \
    pg_restore "${_pgr_clean_args[@]}" --no-owner --no-acl \
               -U supabase_admin -d postgres < "$dump" \
    || rc=$?
  if (( rc != 0 )); then
    echo "  [$target] pg_restore Exit-Code: $rc — bei Supabase oft nicht-fatal (s. README)."
  fi

  # ---- TimescaleDB post_restore — unbedingt ausführen (auch bei pg_restore-Fehler) ----
  if (( _tsdb_active == 1 )); then
    log "[$target] timescaledb_post_restore() aufrufen (unbedingt, auch nach pg_restore-Fehler)"
    docker exec -e PGPASSWORD="$pgpassword" "$container" \
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
  local target="$1" schema="$2" tbl="$3"
  local container; container="$(db_container_for "$target")"
  local pgpassword; pgpassword="$(db_password_for "$target")"
  local n
  n="$(docker exec -e PGPASSWORD="$pgpassword" "$container" \
        psql -tA -U supabase_admin -d postgres \
        -c "SELECT count(*) FROM ${schema}.${tbl};" 2>/dev/null || echo "n/a")"
  printf '  [%s] %-32s %s\n' "$target" "${schema}.${tbl}" "$n"
}

run_verify() {
  local target="$1"
  case "$target" in
    db-assistent)
      verify_count db-assistent auth users
      verify_count db-assistent aibrewgenius recipes 2>/dev/null || true
      ;;
    db-rapt)
      # Hypertable-Counts (telemetry_*): 0 nach Restore = starker Indikator für
      # kaputte Chunk-Verknüpfung (TimescaleDB post_restore fehlgeschlagen/fehlt).
      verify_count db-rapt auth users
      verify_count db-rapt rapt brew_sessions 2>/dev/null || true
      verify_count db-rapt rapt telemetry_controllers 2>/dev/null || true
      verify_count db-rapt rapt telemetry_hydrometers 2>/dev/null || true
      ;;
    portainer)
      # Volume-Restore hat keine SQL-Verify; statt dessen kurzer Smoke:
      # BoltDB-Datei existiert + ist > 0 Bytes. portainer/portainer-ce ist ein
      # distroless Image (kein ls/sh) → nicht via 'docker exec', sondern via
      # disposable alpine mit read-only Mount des Volumes.
      local vol db_size
      vol="$(docker inspect portainer --format \
        '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' \
        | head -1)"
      if [[ -n "$vol" ]]; then
        db_size="$(docker run --rm -v "${vol}:/d:ro" alpine \
          stat -c '%s' /d/portainer.db 2>/dev/null || echo 0)"
        if [[ "$db_size" =~ ^[0-9]+$ && "$db_size" -gt 0 ]]; then
          printf '  [portainer] %-32s %s bytes (OK)\n' "/data/portainer.db" "$db_size"
          printf '  [portainer] Login mit dem ALTEN Admin-Passwort wieder möglich.\n'
        else
          printf '  [portainer] %-32s FEHLT — Restore prüfen!\n' "/data/portainer.db"
        fi
      else
        printf '  [portainer] Kein named volume an portainer — Restore-Verify nicht möglich.\n'
      fi
      ;;
  esac
}

# ---------------------------------------------------------------- Plan + Bestätigung
# Ziele aufbauen: all = beide DBs, sonst Einzel-Ziel.
declare -a PLAN=()
case "$TARGET" in
  all)
    PLAN=(db-assistent db-rapt)
    ;;
  *)
    PLAN=("$TARGET")
    ;;
esac

log "RESTORE — destruktiv"
echo "  Ziel:        ${TARGET}"
echo "  Quelle:      ${SOURCE}"
_has_db=0; _has_volume=0
for t in "${PLAN[@]}"; do
  folder="$(target_folder "$t")"
  container="$(db_container_for "$t")"
  kind="$(target_kind "$t")"
  echo "  ${kind^^} ${t}: Ordner ${folder}/, Container ${container}"
  [[ "$kind" == "pg"     ]] && _has_db=1
  [[ "$kind" == "volume" ]] && _has_volume=1
done
(( _has_db     == 1 )) && echo "  Hinweis (DB):     --clean nur wenn App-Schema schon existiert (frische DB → kein --clean)."
(( _has_volume == 1 )) && echo "  Hinweis (Volume): Container wird kurz gestoppt (~5s), Volume geleert + tar eingespielt."
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
for t in "${PLAN[@]}"; do
  run_verify "$t"
done

log "✓ Restore abgeschlossen"
echo "  Nächster Smoke-Check: Login in der App + je eine Query pro Schema."
echo "  Für db-rapt: telemetry_*-Count > 0 ist Indikator für korrekte TimescaleDB-Chunk-Verknüpfung."
