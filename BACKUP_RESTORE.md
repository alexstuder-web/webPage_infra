# Backup & Restore — Konzept / Spec

> **Status:** Implementiert + lokal getestet (Variante A; keep-N=7 lokal+R2; cron als `alex`).
> `scripts/backup.sh` / `restore.sh` / `bootstrap.sh` fertig; Round-Trip, Retention und
> echter R2-Upload gegen Wegwerf-Stack verifiziert. **Offen:** `.env.gpg` re-encrypten,
> commit/push, Smoke-Test auf echtem VPS (cron/bootstrap).

## 1. Was wird gesichert — und was nicht

Echter, nicht-reproduzierbarer State existiert an **einer** Stelle: dem zentralen
Supabase-Postgres in diesem Repo. Alles andere ist stateless.

| Repo | Backup | Restore | Begründung |
|---|---|---|---|
| `WebPageAlexStuder-new` (Nginx static) | ❌ | ❌ | Build-Artefakt → Git + Docker-Hub-Image. |
| `brew_assistent-new` (Flutter Web) | ❌ App / ✅ Daten | ❌ App / ✅ Daten | Daten in Postgres-Schema `aibrewgenius.*` **+ shared `auth`**. |
| `RAPT_Brewing_Dashboard-new` (Flutter Web) | ❌ App / ✅ Daten | ❌ App / ✅ Daten | Daten in Schema `rapt.*` **+ shared `auth`**. |
| `brew-proxy-new` (Node/Express) | ❌ | ❌ | Stateless. `db-sync.js` schreibt nur nach Postgres. |
| `webPage_infra` | ✅ | ✅ | **Hier läuft Backup/Restore.** |

**Wichtig:** Beide Apps teilen sich **eine** Postgres-DB, und `auth` (User-Logins) ist
**gemeinsam** — `aibrewgenius.*` und `rapt.*` referenzieren beide `auth.users`
(RLS via `auth.uid()`). Deshalb gibt es neben den App-Schemas einen geteilten
`_supabase_core`-Anteil (auth, storage, public, _realtime, …).

`supabase-storage-data` Volume ist aktuell ungenutzt (keine Upload-Calls) — wird
vorsorglich im `_supabase_core`-Anteil mitberücksichtigt.

## 2. Entscheidungen (abgenommen)

| Punkt | Entscheidung |
|---|---|
| Dump-Granularität | **Variante A — pro App getrennt.** Je ein `pg_dump -Fc` pro App-Schema + ein `_supabase_core`-Dump (alles außer den App-Schemas). |
| Konsistenz | Die 3 Dumps laufen **back-to-back** (kein gemeinsamer Snapshot). Das winzige Cross-Dump-Inkonsistenz-Fenster ist akzeptiert + in `backup.sh`/README dokumentiert. |
| Format / Verschlüsselung | `pg_dump -Fc` → GPG **symmetrisch** AES-256, **gleiche Passphrase wie `.env.gpg`**. |
| Trigger | **cron**, nightly ~03:00, unbeaufsichtigt. Passphrase aus `/etc/brewing/gpg.pass` (mode 600). |
| Off-site | **Cloudflare R2**, Bucket **`backup`**, ein Ordner pro App/Service (s.u.). |
| R2-Token | **Eigener Token**, gescoped nur auf Bucket `backup` (Object Read & Write) — entkoppelt von anderen Stacks. |
| Lokale Ablage | `webPage_infra/backups/` (existiert, gitignored), gespiegelte Ordnerstruktur. |
| Restore | **immer manuell**, nicht Teil von bootstrap. Reihenfolge: `_supabase_core` zuerst, dann App-Schemas. |

### Bucket-Layout
```
backup/                         (R2-Bucket)
├── _supabase_core/             auth + storage + public + _realtime + Rest
│   └── core_<TS>.fc.gpg
├── brew_assistent/             Schema aibrewgenius
│   └── aibrewgenius_<TS>.fc.gpg
├── rapt_dashboard/             Schema rapt
│   └── rapt_<TS>.fc.gpg
└── <future_app>/ …             erweiterbar pro neuem Service
```

## 3. Backup-Flow (`scripts/backup.sh`, cron)

```
Drei Dumps back-to-back (Sekundenabstand):
   ├─ pg_dump -Fc --exclude-schema=aibrewgenius --exclude-schema=rapt
   │     | gpg --symmetric → backups/_supabase_core/core_<TS>.fc.gpg         → R2 _supabase_core/
   ├─ pg_dump -Fc -n aibrewgenius
   │     | gpg --symmetric → backups/brew_assistent/aibrewgenius_<TS>.fc.gpg → R2 brew_assistent/
   └─ pg_dump -Fc -n rapt
         | gpg --symmetric → backups/rapt_dashboard/rapt_<TS>.fc.gpg         → R2 rapt_dashboard/
```
- Alle Dumps als `supabase_admin`, `PGPASSWORD=POSTGRES_PASSWORD`. Jeder Dump streamt direkt durch `gpg` (kein Klartext auf Platte).
- GPG symmetrisch, Passphrase via `--passphrase-file /etc/brewing/gpg.pass` (nie auf der Kommandozeile).
- Retention **pro Ordner**: **neueste N=7 behalten** (count-based), **lokal UND R2**. N via `BACKUP_KEEP` (default 7). Manuelles Pre-Migration-Backup via `--label <name>` (rotation-exempt — bleibt liegen, zählt nicht mit).
- Upload nach R2 in den jeweiligen Ordner via `rclone` (Creds über `RCLONE_CONFIG_R2_*`-Env, nie in argv). Nur die fertige `.fc.gpg`. **Nach dem Upload** prunet `backup.sh` den R2-Ordner ebenfalls auf die neuesten N (per `rclone lsf` sortiert, `rclone delete` für den Rest).
- **Konsistenz:** die 3 Läufe sind keine atomare Cross-Schema-Momentaufnahme; das Sekunden-Fenster ist akzeptiert (Hobby-Stack, nightly).

## 4. Off-site: Cloudflare R2

- Bucket `backup`, eigener Token (Object Read & Write, scoped auf `backup`).
- `.env`-Variablen (in `.env.gpg`): `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID`, `R2_ENDPOINT`, `R2_BUCKET=backup`. `R2_ENDPOINT`/`R2_ACCOUNT_ID` sind account-weit (gleicher Cloudflare-Account).
- Es geht nur die bereits GPG-verschlüsselte Datei raus → R2 sieht nie Klartext.
- Retention off-site: **`backup.sh` prunet R2 selbst** auf die neuesten N=7 pro Ordner (gleiche Logik wie lokal, `BACKUP_KEEP`). Keine R2-Lifecycle-Rule mehr nötig — der count-based Prune deckt lokal + off-site einheitlich ab.

## 5. Restore-Flow (`scripts/restore.sh`) — manuell

Das Supabase-Image legt beim ersten Start `auth`, `storage`, `_realtime`, Extensions
und Roles selbst an → roher Full-Restore kollidiert. `--clean --if-exists` löst das.

**Reihenfolge ist zwingend** (App-Daten referenzieren `auth.users`):
```
1. restore.sh core               → _supabase_core (auth muss zuerst da sein)
2. restore.sh brew_assistent     → aibrewgenius
3. restore.sh rapt_dashboard     → rapt
   (oder: restore.sh all  → core, dann beide Apps in korrekter Reihenfolge)
```
- `<core|brew_assistent|rapt_dashboard|all> [datei|latest]`; `latest` zieht das jüngste `.fc.gpg` aus dem passenden R2-Ordner.
- `pg_restore --clean --if-exists --no-owner -U supabase_admin -d postgres`.
- Läuft nie ohne explizites Ziel-Argument + Bestätigung.

⚠️ **Validierungs-Auftrag (Risikostelle):** Restore emittiert bei Supabase
nicht-fatale Fehler (realtime-Publication `supabase_realtime`, `extensions`,
`pgsodium`/Vault). Restore-Test gegen Wegwerf-Stack: `core` → App-Schemas einspielen,
Smoke-Check Login + je eine Query pro Schema; bekannte nicht-fatale Fehler dokumentieren.

## 6. bootstrap-Integration (cicd)

- `scripts/backup.sh` + `scripts/restore.sh` (auf Variante A umgebaut).
- cron (nightly ~03:00) → `backup.sh`, **als `alex` (kein sudo/root)**: alex ist in der `docker`-Gruppe und owner von Repo + Passphrase-Datei.
- Passphrase-Datei `/etc/brewing/gpg.pass` (mode 600, **owner `alex`**) schreiben (bootstrap hat sie aus Bitwarden); `/etc/brewing` gehört alex (mode 700).
- `rclone` installieren; R2-Creds aus `.env`.
- Restore bleibt aus bootstrap raus.
- README-Abschnitt „Backup & Restore".

## 7. Recovery-Gesamtbild

Neuer/kaputter VPS → `bootstrap.sh` (`.env` via Bitwarden + `.env.gpg`, Stack hoch) →
`restore.sh all latest` (core zuerst, dann Apps; aus R2-Bucket `backup`) →
`cloudflare-reconcile.sh` → läuft.
