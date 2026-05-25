# ============================================================================
# db-init-runner — schlankes Init-Container-Image
#
# Basis: postgres:15-alpine (enthält psql-Client + bash, minimale Größe).
# Gepinnt auf Minor-Version (kein :latest).
# KEIN Watchtower-Label — versionsgepinnt, analog Supabase-Konvention.
#
# SQL-Files kommen per read-only Volume-Mount aus dem App-Repo (/sql),
# NICHT ins Image gebacken (Entscheidung R3).
#
# Build-Kontext: webPage_infra/ (root des Repos, nicht db-init/)
#   docker build -f db-init/Dockerfile -t <name> .
# Das Script wird aus dem scripts/-Verzeichnis des Build-Kontexts kopiert.
# ============================================================================

FROM postgres:15.13-alpine3.22

# Non-root Nutzer für den Runner-Prozess.
# postgres-User (UID 70) ist im alpine-postgres-Base-Image vordefiniert.
# psql benötigt keine root-Rechte; Verbindung per TCP zu $DB_HOST (kein Unix-Socket).
# Script chmod=755 (world-executable): notwendig weil USER postgres (uid 70) beim
# COPY-Zeitpunkt noch nicht der Eigentümer ist — x-Bit für other macht es ausführbar.
USER postgres

COPY --chmod=755 scripts/db-init-runner.sh /usr/local/bin/db-init-runner.sh

ENTRYPOINT ["/usr/local/bin/db-init-runner.sh"]
