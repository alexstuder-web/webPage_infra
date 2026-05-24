# Phase 1 — Compose-Zerlegung, Tunnel-DB-Anbindung & URL-Parametrisierung (CICD)

**Umsetzender Agent:** cicd-coder
**Schwester-Spec (parallel):** `webPage_infra/PHASE1_DB_FUNDAMENT_DBA.md` (dba-coder)
**Master-Kontext:** `webPage_infra/MULTIVPS_ARCHITEKTUR.md`
**Ziel:** Die heute monolithische `docker-compose.yml` so umbauen, dass die **4 Einheiten je-Einheit-startbar** sind, die **DB cross-VPS über den Cloudflare-Tunnel** (TCP) erreichbar wird und alle **Verbindungs-URLs konfigurierbar** sind — als Fundament für Phase 2 (Bootstrap-Menü).

---

## 1. Was Phase 1 (CICD-Teil) liefert
- Compose so strukturiert, dass jede Einheit (`web_assistent` / `web_rapt` / `api_proxy` / Supabase-Block) gezielt startbar ist — **sauber**, nicht nur über zufällige `depends_on`-Mitnahme.
- `cloudflared`-**TCP-Ingress** für Postgres (DB-Seite) + ein `cloudflared access tcp`-**Client** (Client-Seite, v.a. Proxy-VPS), sodass der Proxy die DB über einen lokalen Loopback-Port erreicht.
- `DATABASE_URL` + `SUPABASE_INTERNAL_URL` aus `.env` parametrisiert (lokal: Service-Name; remote: Loopback-Port).
- `cloudflare-routes.json` um den DB-TCP-Hostname erweitert (bzw. der Reconcile so, dass TCP-Ingress sauber abgebildet wird).

> Du besitzt Container/Runtime/compose/cloudflared/scripts. Du besitzt NICHT den DB-**Inhalt** (Rollen/Grants/`sslmode`-Vertrag = dba-coder, Schwester-Spec) und NICHT den Dart-/Node-Code. Den Connection-Vertrag (Rolle + `sslmode`) übernimmst du **von dba-coder** (Schnittstelle §6).

---

## 2. Required reading für den Coder (zuerst lesen, an echte Pfade/Funktionen andocken)
- `/Users/alex/Git/WebPageNew/CLAUDE.md` — verbindlich (Secret-Pattern, „Claude macht alles selbst außer Credential-Schritten"; Repo-Abhängigkeiten/Include-Regeln).
- `webPage_infra/MULTIVPS_ARCHITEKTUR.md` — Zielmodell §1–§3 + Flags §6.
- `webPage_infra/PHASE1_DB_FUNDAMENT_DBA.md` — Schwester-Spec; **Schnittstelle** = `DATABASE_URL`/`sslmode`-Vertrag (dort §4).
- `webPage_infra/docker-compose.yml` — **AUTORITATIVE Ist-Realität**:
  - **EIN** Netz `brewing_net` (bridge). **Keine** `assistent_net`/`rapt_net`/`supabase_net`. **Keine** Per-App-Profile außer `profiles: [vps]` an `cloudflared`+`watchtower`.
  - Services: `web_hauptseite`, `web_assistent`, `web_rapt`, `api_proxy`, Supabase-Block (`supabase-db`, `-auth`, `-rest`, `-realtime`, `-storage`, `-meta`, `-studio`, `-kong`), `cloudflared`, `watchtower`.
  - `api_proxy` hat **keinen** `depends_on` auf Supabase; `DATABASE_URL` ist **hartkodiert** (`@supabase-db:5432`); `env_file: .env`.
  - `supabase-db` bindet intern auf Unix-Socket (`POSTGRES_HOST: /var/run/postgresql`) + TCP 5432; healthcheck `pg_isready`.
  - `cloudflared`: `command: tunnel --no-autoupdate run`, `TUNNEL_TOKEN`, `profiles: [vps]`, hängt an `brewing_net`.
  - Volumes: `supabase-db-data`, `supabase-storage-data`.
- `webPage_infra/docker-compose.dev.yml` — Dev-Override (exposed Ports: kong `54321`, db `54322`, studio `54323`, web `8081/8082/8090`, proxy `8083`). Kein Tunnel/Watchtower.
- `webPage_infra/scripts/cloudflare-reconcile.sh` + `webPage_infra/scripts/cloudflare-routes.json` — HTTP-Ingress + DNS-CNAME-Reconcile (idempotent, `cf_call`-Helper). **Heute nur HTTP-Routes** (`service: http://...`). TCP wäre `service: tcp://...`.
- `webPage_infra/.env.example` — Var-Layout (`SUPABASE_PUBLIC_URL`, `CLOUDFLARE_*`, `POSTGRES_PASSWORD` …). **`SUPABASE_INTERNAL_URL` fehlt dort noch** ([[feedback_proxy_docker_networks]] verlangt es).
- `webPage_infra/scripts/decrypt-env.sh` / `encrypt-env.sh` — `.env.gpg`-Pattern, `--passphrase-fd`/`--passphrase-file`, nie Passphrase in argv.
- `brew-proxy-new/server.js` — Z. 22–25: `SUPABASE_URL = SUPABASE_INTERNAL_URL ?? SUPABASE_PUBLIC_URL ?? SUPABASE_URL ?? …` (Override existiert bereits, **kein** Proxy-Code-Change nötig).
- Memory: [[feedback_proxy_docker_networks]] (Proxy braucht Kong-Zugriff; `SUPABASE_INTERNAL_URL` setzen), [[feedback_infra_split]] (Compose nur in `webPage_infra`, App-Repos = Source), [[project_secrets_setup]] (`.env.gpg`, EIN Bitwarden-Item).

---

## 3. Ist → Soll

### Ist
- Alles in `brewing_net`, ein VPS. Selektiver Start nur über `docker compose up -d <service>` + `depends_on`-Mitnahme. `api_proxy.DATABASE_URL` zeigt fest auf `supabase-db:5432`. Cross-VPS gibt es nicht.

### Soll
1. **Je-Einheit-startbar (sauber):** klar definierte Startgruppen für die 4 Einheiten. **Bevorzugter Weg:** Compose-Service-Profile pro Einheit (z.B. `profiles: [assistent]`, `[rapt]`, `[proxy]`, `[supabase]`) — **ABER** das ist eine **Compose-Schema-Änderung → Freigabe nötig** (§8). **Default ohne Freigabe:** dokumentierter selektiver Start über Service-Namen (`docker compose up -d <service ...>`), mit klarer Mapping-Tabelle (Phase 2 nutzt dieselbe). Du entscheidest und **skip-and-report**, falls du Profile/Netze für die saubere Lösung für nötig hältst.
2. **DB cross-VPS über Tunnel (TCP):**
   - **DB-VPS:** `cloudflared`-TCP-Ingress, der einen Hostname (z.B. `db-tcp.alexstuder.cloud`) auf `tcp://supabase-db:5432` mappt.
   - **Client-VPS (Proxy):** ein zusätzlicher Dienst/Mechanismus `cloudflared access tcp --hostname db-tcp.alexstuder.cloud --url localhost:<port>`, der den Remote-DB-Port lokal bindet. Der Proxy verbindet sich gegen `localhost:<port>`.
   - **Lokal/Single-VPS:** unverändert direkt `supabase-db:5432` (kein Tunnel-Hop) — die Parametrisierung muss beide Fälle abdecken.
3. **URL-Parametrisierung (`.env`-getrieben):**
   - `DATABASE_URL` aus `.env` statt hartkodiert in compose. Default = heutiger Service-Name-Wert; remote = der von dba-coder gelieferte Loopback-/`sslmode`-Connection-String.
   - `SUPABASE_INTERNAL_URL` als `.env`-Var einführen + an `api_proxy` reichen (schließt die offene Lücke aus [[feedback_proxy_docker_networks]]).
   - `.env.example` entsprechend ergänzen + kommentieren (welcher Wert lokal vs. remote).
4. **`cloudflare-routes.json`/Reconcile:** den DB-TCP-Hostname abbilden. **Achtung:** `cloudflare-reconcile.sh` baut heute nur HTTP-Ingress + CNAMEs. TCP-Ingress (`service: tcp://...`) + Access-Application sind ein **anderer** Cloudflare-API-Pfad → der Reconcile muss erweitert ODER der TCP-Ingress separat/dokumentiert behandelt werden. **Coder muss verifizieren** (V-2), bevor er `cf_call` blind erweitert.

---

## 4. Konkrete Deliverables
- **`docker-compose.yml`** (und ggf. ein neues Override, s.u.): `DATABASE_URL` + `SUPABASE_INTERNAL_URL` env-parametrisiert; saubere je-Einheit-Startbarkeit (Profile nur bei Freigabe, sonst Service-Namen-Mapping dokumentiert + im Header kommentiert).
- **Tunnel-TCP-Anbindung:** entweder
  - (a) ein neues Compose-Override `docker-compose.tunnel-tcp.yml` für die Client-Seite (`cloudflared access tcp`-Dienst), **oder**
  - (b) eine ergänzende Service-/Command-Definition am bestehenden `cloudflared` (DB-Seite TCP-Ingress).
  Du wählst die minimal-invasive Form und kommentierst sie. **Single-VPS muss weiter ohne TCP-Hop laufen** (Override nicht im Default-Pfad aktiv).
- **`cloudflare-routes.json`** (+ ggf. `cloudflare-reconcile.sh`): DB-TCP-Hostname abgebildet (oder klar dokumentiert, warum TCP-Ingress außerhalb des Reconcile manuell/separat gesetzt wird → dann als To-do/Credential-Schritt ausgeben).
- **`.env.example`:** `SUPABASE_INTERNAL_URL` + (Doku-Kommentar) `DATABASE_URL`-Override + DB-TCP-Hostname-Vars ergänzt.
- **Mapping-Tabelle Einheit → Start-Services** (im Compose-Header oder einem kurzen Doku-Block), die Phase 2 1:1 wiederverwendet:

| Einheit | Start-Services (`docker compose up -d ...`) | Zieht mit |
|---|---|---|
| brew_assistent | `web_assistent` (+ Supabase, falls lokal) | — (Frontend statisch) |
| rapt_dashboard | `web_rapt` | — |
| proxy | `api_proxy` | **kein** `depends_on` auf Supabase → Supabase-Erreichbarkeit ist Voraussetzung (lokal Service-Name, remote Tunnel-Loopback) |
| Supabase/DB | `supabase-kong` | `depends_on` → auth/rest/realtime/storage/meta → `supabase-db` (healthy) |

---

## 5. Shell-/Compose-/Secret-Safety (verbindlich)
- Scripts (falls neue): `set -euo pipefail`, jede Expansion gequotet, `[[ ]]` statt `[ ]`, `mktemp` + sofortige `trap '...' EXIT` für jedes Secret-Tempfile (Lesson 2026-05-24), **kein** `export VAR="$(cmd)"`-Einzeiler (erst zuweisen, dann `export` — Lesson 2026-05-24), `log()`/`ok()`/`err()`-Helfer wiederverwenden.
- **Secrets:** GPG-Passphrase nie in argv; **`docker compose config` NIE in ein Log** (expandiert `.env`); keine `.env`-Werte echoen; `.env.gpg` bleibt Source of Truth, Plaintext-`.env` gitignored.
- **Compose:** `restart: unless-stopped`; `env_file: .env` wo Runtime-Secrets nötig; Images als `${DOCKERHUB_USERNAME}/...`; **Supabase-Stack bleibt versions-gepinnt, KEIN Watchtower-Label, nicht bumpen**; `:ro` für Read-only-Mounts; bestehende Netze respektieren; named Volumes (`supabase-db-data`) **nie** ohne expliziten, geguardeten Grund löschen.
- **`cloudflared access tcp`:** der `TUNNEL_TOKEN`/Access-Service-Token kommt aus `.env`, nicht in argv/Logs.
- **Test vor „done":** `bash -n` + `shellcheck` (falls verfügbar) auf neue/geänderte Scripts; `docker compose -f docker-compose.yml [-f override] config -q` (Schema-Validierung, **nicht** in ein Log) als Dry-Check; lokalen Stack hochziehen und bestätigen, dass `DATABASE_URL` aus `.env` beim Proxy ankommt (Single-VPS-Pfad). Cross-VPS-Tunnel-Stream ohne zweiten VPS NICHT voll testbar → klar benennen.

---

## 6. Schnittstelle zu dba-coder (Phase 1)
- **dba-coder liefert:** finalen `DATABASE_URL`-Aufbau (Rolle, DB, `sslmode`) für den Cross-VPS-Fall + ob eine neue Proxy-Rolle ein neues Passwort in `.env`/`zz-set-role-passwords.sh` braucht.
- **cicd-coder setzt:** genau diesen String als `.env`-Var um, reicht ihn an `api_proxy`, ergänzt `.env.example`, und — falls neue Rolle — trägt das Passwort-Setzen in `zz-set-role-passwords.sh` + `.env` nach (⇒ `.env.gpg` re-encrypt = Credential-Schritt §10).
- **Reihenfolge:** Wenn dba-coder noch nicht geliefert hat, parametrisiere `DATABASE_URL` zunächst so, dass der **heutige** Wert der Default bleibt (Single-VPS unverändert), und markiere den remote-Wert als „von dba-coder einzusetzen".

---

## 7. Explizit NICHT im Scope
- **Kein** Proxy-Code-Change (`SUPABASE_INTERNAL_URL`/`DATABASE_URL`-Override existiert in `server.js` bereits) — falls doch nötig, skip-and-report (kein Agent → general `claude`, Master §6.3).
- **Kein** Frontend-Change durch dich. Die `EnvConfig`-URL-Konfigurierbarkeit (Override + `supabase.`-Default, A-URL-1) macht der **`flutter-coder`** in der Schwester-Spec `PHASE1_CLIENT_URLS_FLUTTER.md` — Master §6.2. Du stellst nur sicher, dass der nach außen veröffentlichte Hostname (`supabase.<domain>`, `api.<domain>` in `cloudflare-routes.json`) zu dem passt, was die Client-Defaults erwarten.
- **Kein** DB-Inhalt (Rollen/Grants/RLS) — dba-coder.
- **ufw/SSH-Hardening NICHT anfassen**; **kein** direktes Postgres-Port-Öffnen nach außen (alles durch den Tunnel).
- **Kein** Bootstrap-Menü hier (das ist Phase 2, `BOOTSTRAP_MENU_KONZEPT.md`).
- **Keine** neue apt-Dependency (`cloudflared` ist bereits Image; `access tcp` ist Teil derselben Binary).

## 8. Braucht Freigabe / außerhalb cicd-coder-Standard-Scope
- **Compose-Schema-Änderung „Per-Einheit-Profile"** (`profiles: [assistent|rapt|proxy|supabase]`): saubere je-Einheit-Startbarkeit, ABER Schema-Änderung → **Freigabe nötig**. Default ohne Freigabe = Service-Namen-Mapping (§4). Coder: skip-and-report, falls Profile bevorzugt.
- **Neue Netze** (`assistent_net`/`rapt_net`/`supabase_net`): NICHT einführen ohne Freigabe — bleibt `brewing_net`.
- **`cloudflare-reconcile.sh`-Erweiterung um TCP-Ingress/Access-Application:** falls der Reconcile den neuen Cloudflare-API-Pfad (TCP-Ingress, Access-App) abdecken soll, ist das eine nicht-triviale Script-Erweiterung → umsetzbar, aber im Report als Umfang markieren; alternativ TCP-Ingress separat/manuell + To-do.
- **Supabase-Stack** bleibt gepinnt, kein Watchtower-Label (Frozen).
- **`.env`-Änderungen** (`SUPABASE_INTERNAL_URL`, `DATABASE_URL`-Remote, DB-TCP-Vars, evtl. Proxy-Rollen-PW) ⇒ `.env.gpg` re-encrypt ⇒ **Credential-Schritt** (§10).

---

## 9. Offene Annahmen — Coder MUSS gegen die echten Dateien verifizieren
1. **V-1 — Nur `brewing_net`, keine Per-App-Profile:** bestätigt aus `docker-compose.yml`. Selektiver Start läuft heute über Service-Namen. Profile/Netze = Freigabe (§8).
2. **V-2 — Cloudflare-TCP-Ingress-API-Pfad:** `cloudflare-reconcile.sh` baut nur HTTP-Ingress (`service: http://...`) + CNAMEs. TCP-Ingress (`service: tcp://...`) und der client-seitige `cloudflared access tcp` (Access-Application + Service-Token) sind ein **anderer** API-/Config-Pfad. Verifizieren, **bevor** `routes.json`/`cf_call` blind erweitert werden — sonst TCP-Ingress separat/dokumentiert.
3. **V-3 — `SUPABASE_INTERNAL_URL` fehlt in `.env`/`.env.example`/compose:** [[feedback_proxy_docker_networks]] verlangt `SUPABASE_INTERNAL_URL=http://supabase-kong:8000`. Prüfen, ob es inzwischen in der echten (entschlüsselten) `.env` steht; in `.env.example` + compose ergänzen, falls nicht.
4. **V-4 — `DATABASE_URL` hartkodiert:** bestätigt (`api_proxy.environment` in compose). Auf `.env`-Var umstellen, heutigen Wert als Default behalten.
5. **V-5 — Hostname `db.` vs. `supabase.` (Master §3, A-URL-1) — ENTSCHIEDEN:** Kanonisch = **`supabase.`**. Der Fix liegt **frontend-seitig** bei `flutter-coder` (`PHASE1_CLIENT_URLS_FLUTTER.md` — `EnvConfig`-Default auf `supabase.` + Override). **Auf der CICD-Seite ist hier NICHTS zu ändern:** `cloudflare-routes.json` mappt bereits `supabase.alexstuder.cloud` → `supabase-kong:8000` (Z. 9) und `SUPABASE_PUBLIC_URL` ist bereits `https://supabase.alexstuder.cloud` — beides bleibt. Nur sicherstellen, dass eine etwaige neue Route oder der DB-TCP-Hostname (`db-tcp.<domain>`) nicht mit dem HTTP-Hostname `supabase.<domain>` kollidiert. Den `db.`-Hostname **nicht** neu einführen.
6. **V-6 — `dev.yml`-Ports:** Cross-VPS-Loopback-Port für den `access tcp`-Client darf nicht mit den Dev-Exposed-Ports (`54321/54322/54323/8081-8083/8090`) kollidieren. Freien Port wählen + dokumentieren.

---

## 10. Credential-Schritte (User muss tun)
- **`.env.gpg` re-encrypt** nach jeder `.env`-Ergänzung (`SUPABASE_INTERNAL_URL`, `DATABASE_URL`-Remote, DB-TCP-Hostname/Token, evtl. Proxy-Rollen-PW): `./scripts/encrypt-env.sh` mit der Brewing-GPG-Passphrase (Bitwarden `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`) + `git commit` der `.env.gpg`.
- **Cloudflare Tunnel-TCP-Ingress / Access-Application** (falls über Dashboard statt API): ggf. einmaliges Anlegen einer Access-Application + Service-Token im Cloudflare-Dashboard (echte Credentials) — Coder bereitet alles vor und benennt exakt diesen einen Schritt.

---

## 11. Launch-Instruktion für cicd-coder (copy-paste)
> Starte `cicd-coder` mit diesem Spec: `/Users/alex/Git/WebPageNew/webPage_infra/PHASE1_COMPOSE_TUNNEL_CICD.md`
>
> Mach die 4 Einheiten je-Einheit-startbar, parametrisiere `DATABASE_URL` + `SUPABASE_INTERNAL_URL` aus `.env` (heutiger Service-Name-Wert bleibt Default), und richte die Cloudflare-Tunnel-**TCP**-Anbindung für Postgres ein (DB-seitiger TCP-Ingress + client-seitiger `cloudflared access tcp` → Loopback-Port), so dass Single-VPS unverändert ohne Tunnel-Hop läuft. Den Cross-VPS-`DATABASE_URL`/`sslmode`-Wert übernimmst du vom dba-coder (Schwester-Spec `PHASE1_DB_FUNDAMENT_DBA.md`, Schnittstelle §6). KEINE Per-App-Profile/Netze ohne Freigabe (Default: Service-Namen-Mapping; skip-and-report falls du Profile bevorzugst, §8). Supabase-Stack nicht bumpen. Verifiziere V-1…V-6 (§9) gegen die echten Dateien — besonders den Cloudflare-TCP-Ingress-API-Pfad (V-2), bevor du den Reconcile erweiterst. `bash -n`+`shellcheck` auf neue Scripts, `docker compose config -q` als Schema-Check (nicht ins Log), lokalen Single-VPS-Pfad testen; benenne klar, was ohne zweiten VPS/echten Tunnel ungetestet bleibt. `.env`-Änderungen ⇒ `.env.gpg` re-encrypt = Credential-Schritt (§10) am Ende an den User.
</content>
