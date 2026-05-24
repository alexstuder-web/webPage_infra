# Phase 1 — DB-Fundament: Cross-VPS-Connection-Security (DBA)

**Umsetzender Agent:** dba-coder
**Schwester-Spec (parallel):** `webPage_infra/PHASE1_COMPOSE_TUNNEL_CICD.md` (cicd-coder)
**Master-Kontext:** `webPage_infra/MULTIVPS_ARCHITEKTUR.md`
**Ziel:** Die Supabase/DB-Einheit so absichern und vorbereiten, dass der **Proxy** (und ggf. Backup/Restore) sie **cross-VPS über den Cloudflare-Tunnel** erreichen kann, ohne das Tenancy-Modell (RLS/Vault/SECURITY DEFINER) zu schwächen.

---

## 1. Was Phase 1 (DBA-Teil) liefert
Eine klare, getestete Antwort auf die Frage: **„Mit welcher Rolle, welchem Connection-String und welchem `sslmode` verbindet sich der Proxy gegen die DB, wenn er NICHT mehr im selben Docker-Netz hängt — und bleibt RLS/Vault dabei intakt?"** Plus ggf. eine forward-only Migration, falls Rollen/Grants/Search-Path angepasst werden müssen.

> Du besitzt den **Inhalt** der DB. Du besitzt NICHT die Container/compose/cloudflared-Verdrahtung (das ist cicd-coder, Schwester-Spec) und NICHT den Dart-/Node-Client. Wo eine Änderung diese Grenze überschreitet, mach deinen Teil und gib den Rest explizit weiter.

---

## 2. Required reading für den Coder (zuerst lesen, an echte Pfade andocken)
- `/Users/alex/Git/WebPageNew/CLAUDE.md` — verbindlich (Secret-Pattern, „Claude macht alles selbst außer Credential-Schritten").
- `webPage_infra/MULTIVPS_ARCHITEKTUR.md` — Zielmodell §1–§3 (4 Einheiten, Cloudflare-Tunnel-DB-Connectivity, konfigurierbare URLs).
- `webPage_infra/PHASE1_COMPOSE_TUNNEL_CICD.md` — die parallele cicd-Spec; **Schnittstelle** §6 dort = `DATABASE_URL`/`sslmode`-Vertrag.
- Bestehende Migrationen (Stil/Naming/RLS-/RPC-Muster übernehmen):
  - `brew_assistent-new/db_scripts/migrations/002_auth.sql`, `003_vault.sql`
  - `RAPT_Brewing_Dashboard-new/db_scripts/` (`001_init_rapt_schema.sql`, `002_user_profiles.sql`, `003_device_activity_view.sql`)
  - `brew_assistent-new/db_scripts/full/001_init_schema.sql`
- `webPage_infra/docker-compose.yml` — **AUTORITATIVE Realität** für: welche Rollen wie verbinden. Relevant:
  - `supabase-db` Service: `POSTGRES_HOST: /var/run/postgresql` (Unix-Socket intern), Port 5432, healthcheck via `pg_isready`.
  - `api_proxy`: `DATABASE_URL: postgres://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres` (heute **Service-Name**, kein TLS).
  - `supabase-rest` nutzt Rolle `authenticator`; `supabase-realtime`/`supabase-meta`/Storage nutzen `supabase_admin`/eigene Admin-Rollen.
- `webPage_infra/supabase/db_init/zz-set-role-passwords.sh` — setzt beim Erst-Boot Passwörter für `authenticator`, `supabase_auth_admin`, `supabase_storage_admin`, `supabase_replication_admin`, `pgbouncer`, `postgres` (alle = `${POSTGRES_PASSWORD}`). **Owner aller `aibrewgenius`-Objekte = `supabase_admin`** ([[feedback_supabase_admin_role]]).
- Memory: [[feedback_supabase_admin_role]] (DDL als `supabase_admin`), [[project_auth_migration]] (RLS/Vault/RPC-Modell, `auth.uid()`), [[feedback_proxy_docker_networks]] (Proxy ruft Kong + DB-Pool an), [[project_backup_restore]] (Dumps laufen als `supabase_admin`).

---

## 3. Ist → Soll

### Ist
- Proxy verbindet sich **als Rolle `postgres`** über den Docker-Service-Namen `supabase-db:5432`, **ohne TLS** (`sslmode` nicht gesetzt). Funktioniert, weil alles im selben Docker-Netz `brewing_net` liegt (vertrauenswürdiges internes Netz).
- Der Proxy ruft zusätzlich **Kong** (`SUPABASE_INTERNAL_URL`/`SUPABASE_PUBLIC_URL`) für RLS-scoped RPCs via JWT an (BFF-Pattern, [[feedback_proxy_docker_networks]], [[project_auth_migration]]).
- RLS/Vault/SECURITY DEFINER filtern auf `auth.uid()` aus dem JWT — **unabhängig** vom Netzwerk-Pfad.

### Soll (cross-VPS)
- Wenn der Proxy auf einem anderen VPS läuft, kommt seine DB-Verbindung über einen `cloudflared access tcp`-Client auf **`localhost:<port>`** an (cicd-coder verdrahtet das). Aus DB-Sicht ist das eine Verbindung, die durch den Tunnel kommt und am DB-VPS am `supabase-db`-Container ankommt.
- **DBA-Entscheidungen, die du treffen + dokumentieren musst:**
  1. **Welche Rolle** der Proxy remote benutzen soll. Bewerten: bleibt `postgres` (heute) vs. eine **dedizierte, minimal-privilegierte Rolle** für den Proxy-Pool. Beachte: der Proxy nutzt den pg-Pool laut [[project_auth_migration]] nur noch begrenzt (Cred-Reads laufen über Kong-RPC mit User-JWT). Prüfe in `brew-proxy-new/server.js`/`db-sync.js`, wofür der direkte `DATABASE_URL`-Pool noch gebraucht wird, und schlage die **kleinste ausreichende** Rolle vor.
  2. **`sslmode`** für die Remote-Verbindung. Der Tunnel terminiert TLS auf der Transportschicht; die Postgres-Verbindung selbst ist im `access tcp`-Stream gekapselt. Entscheide + dokumentiere die Erwartung (z.B. `sslmode=disable` ist akzeptabel, weil der Tunnel den Transport verschlüsselt — ODER `sslmode=require`, falls supabase/postgres-Image serverseitiges TLS anbietet). **Verifiziere gegen das Image** (Annahme V-3), nicht raten.
  3. **Keine Lockerung der RLS-/Vault-Garantien.** Ein anderer Netzwerk-Pfad darf NICHT dazu führen, dass eine Verbindung mehr sieht als vorher. Insbesondere: falls eine dedizierte Proxy-Rolle eingeführt wird, MUSS sie alle bestehenden RLS-Policies respektieren (kein `BYPASSRLS`, keine `rolsuper`).

---

## 4. Konkrete Deliverables
- **Connection-Vertrag (Dokument-Abschnitt + Rückgabe an cicd-coder):** finaler `DATABASE_URL`-Aufbau für den Cross-VPS-Fall — Rolle, DB, `sslmode`-Parameter. Format z.B. `postgres://<rolle>:<pw>@localhost:<tunnel-loopback-port>/postgres?sslmode=<...>`. **Das ist die Schnittstelle zu cicd-coder** (Master §4 / cicd-Spec §6).
- **Falls eine dedizierte Proxy-Rolle nötig ist:** eine **neue forward-only, nummerierte Migration** im richtigen Repo (`brew_assistent-new/db_scripts/migrations/004_*.sql` — nächste Nummer nach `003_vault.sql`; verifiziere die höchste vorhandene Nummer):
  - `CREATE ROLE` (idempotent: `DO $$ ... IF NOT EXISTS`), Passwort wird NICHT in der Migration hartkodiert (Klartext-Secret-Verbot) — stattdessen Passwort-Setzen analog `zz-set-role-passwords.sh` als Hinweis an cicd-coder, oder die Rolle erbt `${POSTGRES_PASSWORD}`-Mechanik.
  - `GRANT`s minimal (genau das, was der Proxy-Pool braucht; KEINE table-level-Rechte, die RLS mediieren soll).
  - `ALTER ROLE ... NOSUPERUSER NOBYPASSRLS`.
  - Wrappe in `BEGIN; … COMMIT;`.
- **Falls KEINE neue Rolle nötig** (Empfehlung bewerten: `postgres` weiter nutzen, da heute schon so): dann **keine Migration**, nur der dokumentierte Connection-Vertrag + Begründung, warum `postgres` remote akzeptabel bleibt (der Tunnel ist der Vertrauensanker).
- **Doku-Abschnitt „Auswirkung auf RLS/Vault/SECURITY DEFINER":** explizite Bestätigung, dass der geänderte Netzwerk-Pfad nichts an `auth.uid()`-Filterung, `SET search_path = ''` in SECURITY-DEFINER-RPCs und `vault.secrets`-Verschlüsselung ändert.

---

## 5. SQL-Safety-Vorgaben (verbindlich)
- **DDL/Policy/Rollen-Änderungen laufen als `supabase_admin`**, nicht `postgres` ([[feedback_supabase_admin_role]]): `psql -U supabase_admin -h localhost -p 54322 -d postgres -f <migration>.sql`.
- **Forward-only + nummeriert**, nächste Nummer hoch, **nie** eine angewandte Migration editieren, **nie** umnummerieren.
- **Idempotent**: `IF NOT EXISTS` / `CREATE OR REPLACE` / `DROP POLICY IF EXISTS` — Migration muss zweimal fehlerfrei laufen.
- **Least privilege**: `anon`/`authenticated`/eine etwaige Proxy-Rolle bekommen nur das Nötigste; **keine** table-Rechte, die RLS mediieren soll; **kein** `BYPASSRLS`/`SUPERUSER`.
- **Kein Klartext-Secret** in SQL/Files. Passwort-Setzen läuft über die bestehende `${POSTGRES_PASSWORD}`-Mechanik (cicd-coder-Territory) — du gibst nur den Bedarf weiter.
- **Backup vor riskanter Migration**: existiert kein aktueller Pre-Migration-Dump in `webPage_infra/backups/pre-*-migration/`, fordere genau diesen einen Schritt an (gpg-gestreamter Dump via `backup.sh --label pre-migration` ist cicd-coder/Script-Territory) — **kein** hand-gerollter Klartext-Dump.

---

## 6. Test-Erwartung (lokaler Stack, nie zuerst prod)
Lokaler Stack: `docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d` (DB exposed auf `localhost:54322`).
1. **Migration idempotent**: zweimal anwenden, beide Male clean.
2. **Smoke**: Auth-Login (`/auth/v1/token?grant_type=password`) + je eine Query pro berührtem Schema (`aibrewgenius.*`, `rapt.*`) kommt erwartet zurück.
3. **RLS-Probe**: mit zweitem User-JWT (oder `SET request.jwt.claims`) bestätigen, dass User A keine Zeilen von User B sieht/schreibt — **auch** über eine etwaige neue Proxy-Rolle.
4. **Vault-Probe** (falls berührt): `set_my_*_creds` → Klartext-Spalte/`SELECT` NULL → `get_my_*_creds` liefert Wert → `*_configured`-Flag kippt.
5. **Cross-VPS-Connection (so weit ohne zweiten VPS möglich)**: prüfe, dass der dokumentierte `DATABASE_URL` (mit gewähltem `sslmode`) gegen die **lokal exposed** DB auf `localhost:54322` funktioniert — das simuliert den Loopback-Port des `access tcp`-Clients. Was du ohne echten zweiten VPS NICHT testen kannst (echter Tunnel-Stream), klar benennen.

---

## 7. Explizit NICHT im Scope
- **Keine** Compose-/Dockerfile-/cloudflared-/GitHub-Actions-Änderung — das ist cicd-coder (Schwester-Spec). Wenn deine Rolle ein neues Passwort/Env braucht, **flag es für cicd-coder**.
- **Keine** Dart-/Node-Änderung — wenn ein Return-Shape/Schema-Vertrag bräche, flag für flutter-coder bzw. (Proxy) für general `claude`.
- **Keine** Änderung am Tenancy-Modell (RLS/Vault/SECURITY DEFINER-Logik) — Phase 1 berührt nur *Connection*-Aspekte.
- **Keine** Schema-Verschiebung/Tabellen-Umzug — die DB bleibt EINE Instanz mit beiden Schemen + core (Master §1).

## 8. Braucht Freigabe / außerhalb dba-coder-Scope
- **Neue Postgres-Rolle für den Proxy** ist eine bewusste Sicherheits-Entscheidung. Wenn du sie empfiehlst: als Migration umsetzen, aber im Report klar als Entscheidung markieren (User/Reviewer bestätigt). Wenn `postgres` weiter genügt: begründen, keine Migration.
- **Passwort-Mechanik der neuen Rolle** (falls eingeführt) ⇒ Eintrag in `zz-set-role-passwords.sh` + ggf. `.env` ⇒ **cicd-coder + Credential-Schritt** (`.env.gpg` re-encrypt).
- **`sslmode`/serverseitiges TLS** des supabase/postgres-Images: falls TLS aktiviert werden müsste (Zertifikate, `pg_hba.conf`), ist das eine Container-/Config-Änderung ⇒ cicd-coder.

---

## 9. Offene Annahmen — Coder MUSS gegen die echten Dateien verifizieren
1. **V-1 — Höchste Migrationsnummer:** Annahme `003_vault.sql` ist die höchste in `brew_assistent-new/db_scripts/migrations/`. Vor `004` verifizieren (`ls db_scripts/migrations/`).
2. **V-2 — Wofür der Proxy den direkten DB-Pool noch nutzt:** [[project_auth_migration]] sagt, Cred-Reads laufen über Kong-RPC (`callMyCredsRpc`), nicht mehr per direktem `user_profiles`-SELECT. Verifiziere in `brew-proxy-new/server.js` + `db-sync.js`, welche Queries der `DATABASE_URL`-Pool noch fährt → bestimmt die minimal nötigen Grants der Proxy-Rolle.
3. **V-3 — `sslmode`/TLS-Fähigkeit:** ob `supabase/postgres:15.8.1.060` serverseitiges TLS anbietet und ob `sslmode=require` ohne Zusatz-Config funktioniert — gegen das laufende Image testen, nicht annehmen.
4. **V-4 — Rollen-Owner:** Annahme aus [[feedback_supabase_admin_role]], dass `supabase_admin` Owner aller App-Objekte ist und `postgres` nicht-superuser. Vor GRANT-Entscheidungen am laufenden Stack bestätigen (`\du`, `\dn+`).
5. **V-5 — Kong-Pfad bleibt unverändert:** Annahme, dass der BFF-/Kong-Pfad (`SUPABASE_INTERNAL_URL`) eine separate HTTP-Verbindung ist und vom Postgres-TCP-Tunnel unberührt bleibt. Bestätigen, dass beide Pfade (Kong-HTTP + Postgres-TCP) für den Cross-VPS-Proxy abgedeckt sind — sonst an cicd-coder zurück.

---

## 10. Credential-Schritte (User muss tun)
- **`.env.gpg` re-encrypt**, falls eine neue Proxy-Rolle ein neues Passwort in `.env` braucht: `./scripts/encrypt-env.sh` mit der Brewing-GPG-Passphrase (Bitwarden `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`) + commit. (Das `.env`-Schreiben selbst koordiniert cicd-coder; du gibst nur den Var-Bedarf weiter.) — sonst **(keine)**.
- **Pre-Migration-Backup** (falls riskante Migration + kein aktueller Dump): `backup.sh --label pre-migration` braucht die Passphrase aus `/etc/brewing/gpg.pass`/Bitwarden.

---

## 11. Launch-Instruktion für dba-coder (copy-paste)
> Starte `dba-coder` mit diesem Spec: `/Users/alex/Git/WebPageNew/webPage_infra/PHASE1_DB_FUNDAMENT_DBA.md`
>
> Liefere den **Cross-VPS-Connection-Vertrag** für den Proxy (Rolle, `DATABASE_URL`-Aufbau, `sslmode`) und — falls eine dedizierte minimal-privilegierte Proxy-Rolle nötig ist — eine forward-only nummerierte Migration im richtigen Repo, idempotent, als `supabase_admin` getestet. Bestätige dokumentiert, dass RLS/Vault/SECURITY-DEFINER unverändert greifen. Verifiziere V-1…V-5 (§9) gegen die echten Dateien/das laufende Image; rate nicht. Lokal testen (Migration-Idempotenz + Smoke + RLS-Probe + ggf. Vault-Probe + Loopback-`DATABASE_URL` gegen `localhost:54322`); benenne klar, was ohne zweiten VPS/Tunnel ungetestet bleibt. Compose/cloudflared/`.env`-Verdrahtung NICHT selbst machen — als Vertrag an cicd-coder (Schwester-Spec `PHASE1_COMPOSE_TUNNEL_CICD.md`) zurückgeben. Credential-Schritte (§10) am Ende an den User.
</content>
