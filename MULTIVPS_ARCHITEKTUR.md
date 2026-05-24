# Multi-VPS-Architektur — Zielmodell & Phasenplan

**Status:** Durable Architektur-Record. Die per-Agent-Implementierungs-Specs waren transiente Build-Inputs und wurden nach Umsetzung entfernt.
**Betroffenes Repo:** `webPage_infra` (zentral) + DB-Inhalte in den App-Repos
**Umsetzende Agenten:** `dba-coder` + `cicd-coder` + `flutter-coder` (Phase 1), `cicd-coder` (Phase 2)
**Kontext/Warum:** Der Brewing-Stack soll von Single-VPS auf ein **verteiltes Multi-VPS-Deployment** umgebaut werden — vier unabhängig platzier- und jederzeit verschiebbare Einheiten. Heute laufen alle Services monolithisch in einem Docker-Netz `brewing_net` auf einem VPS.

> Dieses Dokument beschreibt das **Zielmodell** und ordnet die Arbeit in Phasen. Es ist KEINE Implementierungs-Spezifikation. Die per-Agent-Implementierungs-Specs (Phase 1 dba/cicd/flutter, Phase 2 Bootstrap-Menü) waren **transiente Build-Inputs** und wurden nach Umsetzung entfernt — die Umsetzung lebt im Code und in der git-Historie, das durable Zielmodell hier.

---

## 1. Zielmodell — Die 4 Einheiten

Vier Einheiten, jede unabhängig auf einem beliebigen VPS platzier- und **jederzeit verschiebbar**:

| # | Einheit | Container | State | Verschieben durch |
|---|---|---|---|---|
| 1 | **brew_assistent** (Frontend) | `web_assistent` | zustandslos | Image stoppen / auf Ziel-VPS starten + Verbindungs-URLs neu setzen |
| 2 | **rapt_dashboard** (Frontend) | `web_rapt` | zustandslos | wie 1 |
| 3 | **proxy** | `api_proxy` | zustandslos | wie 1 |
| 4 | **Supabase / DB** | `supabase-db` … `supabase-kong` | **EINZIGE zustandsbehaftete Einheit** | `backup.sh` (alle Schemen + core) → `restore.sh` auf Ziel-VPS, Reihenfolge core → app-Schema |

### Bewusste Entscheidung: EINE Supabase-Instanz, KEIN per-App-Supabase
Die Supabase/DB-Einheit hält **beide Schemen** (`aibrewgenius` + `rapt`) **plus** den geteilten core (`auth.users`/storage/public/_realtime). Es gibt **bewusst KEIN** per-App-Supabase, damit der **geteilte Login** über beide Apps erhalten bleibt (kein SSO-Problem). Siehe [[project_auth_migration]] — beide App-Schemen FKen auf `auth.users`.

### Verschieben — konkret
- **Zustandslose Einheiten (1–3):** Image auf altem VPS stoppen, auf Ziel-VPS starten, Verbindungs-URLs neu setzen. **Keine Datenmigration.**
- **DB (4):** `backup.sh` auf altem VPS (drei Dumps: `_supabase_core` + `brew_assistent` + `rapt_dashboard`, Variante A — siehe [[project_backup_restore]]) → `restore.sh` auf Ziel-VPS. **Reihenfolge core → app-Schema.** Der geteilte core wird auf dem Ziel-VPS **überschrieben** (Ziel-VPS gilt als dediziert). Konfliktschutz, falls auf dem Ziel-VPS bereits fremde `auth.users` existieren: wird im Migrations-Pfad des `bootstrap.sh`-Menüs (Phase 2) behandelt.

---

## 2. Cross-VPS-Connectivity — Cloudflare Tunnel

**Entscheidung (verbindlich):** Cross-VPS-Verbindungen laufen über **Cloudflare Tunnel** — das bereits vorhandene `cloudflared`. **NICHT** WireGuard/Tailscale, **NICHT** direktes Postgres-Port-Öffnen + ufw.

### HTTP-Ingress (heute schon vorhanden)
Frontends, Proxy, Kong und Studio sind bereits über Tunnel-Ingress + DNS-CNAMEs erreichbar (`scripts/cloudflare-routes.json` → `scripts/cloudflare-reconcile.sh`). Hostnames: `alexstuder.cloud`, `aibrewgenius.alexstuder.cloud`, `rapt.alexstuder.cloud`, `api.alexstuder.cloud`, `supabase.alexstuder.cloud`, `studio.alexstuder.cloud`.

### NEU — Postgres-TCP cross-VPS
Wenn der Proxy (oder eine andere Einheit) auf einem **anderen** VPS läuft als die DB, braucht er eine Postgres-Verbindung über VPS-Grenzen. Lösung:
- **DB-Seite:** `cloudflared`-TCP-Ingress auf die Postgres-Verbindung (`supabase-db:5432`) unter einem dedizierten Hostname (z.B. `db-tcp.alexstuder.cloud`).
- **Client-Seite (v.a. Proxy):** ein `cloudflared access tcp`-Client, der den Remote-DB-Hostname lokal auf einen Loopback-Port bindet; der Proxy verbindet sich gegen `localhost:<port>`.

> **WICHTIG:** Postgres ist eine TCP-/Nicht-HTTP-Connection. Cloudflare-Tunnel-TCP-Ingress + `cloudflared access tcp` ist genau dafür da. Das ist eine **neue Compose-/cloudflared-Konfiguration** und gehört in Phase 1 (cicd-coder). Die **DB-seitigen** Konsequenzen (Remote-Rollen/Grants, `sslmode`, ob `authenticator`/`postgres` über die Loopback-bridge ankommen) gehören zu Phase 1 (dba-coder).

### ufw / SSH-Hardening = FROZEN
Bleiben **unangetastet**. Es wird KEIN Postgres-Port nach außen geöffnet. Der gesamte cross-VPS-Traffic geht durch den Tunnel.

---

## 3. Konfigurierbare Verbindungs-URLs

Alle Verbindungs-URLs müssen **konfigurierbar** werden, damit eine Einheit verschoben werden kann, ohne Code/Image neu zu bauen:

| URL / Var | Wer nutzt sie | Heutiger Stand | Soll |
|---|---|---|---|
| `DATABASE_URL` | `api_proxy` | hartkodiert in `docker-compose.yml` → `postgres://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres` | aus `.env` parametrisierbar (Local: Service-Name; Remote: Loopback-Port des `access tcp`-Clients) |
| `SUPABASE_INTERNAL_URL` | `api_proxy` (BFF, Kong) | im Proxy-Code bereits Override-fähig (`server.js`), aber NICHT in `.env.example`/compose gesetzt | als `.env`-Var einführen + in compose an `api_proxy` reichen |
| `SUPABASE_PUBLIC_URL` | Auth/Studio/Frontend | `.env` → `https://supabase.alexstuder.cloud` | bleibt — ist schon konfigurierbar |
| `RAPT_DASHBOARD_URL` | `brew_assistent`-Frontend | Override via dotenv-`.env`-Asset (`EnvConfig.raptDashboardUrl()`), sonst hostname-abgeleitet | bleibt frontend-seitig — Vorbild-Muster für die neue Konfigurierbarkeit (§6.2) |
| `SUPABASE_URL` (Override) | beide Frontends | Key in `.env.example` vorhanden, aber von `EnvConfig` **nicht** gelesen; URL hostname-abgeleitet `db.${baseDomain}` | **Phase 1 (flutter-coder):** `EnvConfig.supabaseUrl()` liest `dotenv.env['SUPABASE_URL']` als Override; non-local-Default auf **`https://supabase.${baseDomain}`** geändert (kanonisch, löst die `db.`/`supabase.`-Inkonsistenz). Local-Branch unverändert. |
| `PROXY_URL` (Override) | beide Frontends | Key in `.env.example` vorhanden, aber von `EnvConfig` **nicht** gelesen; URL hostname-abgeleitet `api.${baseDomain}/api` | **Phase 1 (flutter-coder):** `EnvConfig.proxyUrl()` liest `dotenv.env['PROXY_URL']` als Override; non-local-Default `https://api.${baseDomain}/api` unverändert. Local-Branch unverändert. |

> **A-URL-1 — ENTSCHIEDEN (verbindlich):** Kanonischer Supabase-Hostname = **`supabase.`** (nicht `db.`). Begründung: `cloudflare-routes.json` registriert `supabase.alexstuder.cloud` und `webPage_infra/.env.example` `SUPABASE_PUBLIC_URL` ist ebenfalls `supabase.alexstuder.cloud` — die Server-Seite ist also bereits konsistent. Es ist **kein laufender Prod-Bug**, weil noch nichts deployed ist (Bootstrap lief nie); die Cloudflare-Einträge entstehen erst beim ersten Bootstrap/Reconcile aus `cloudflare-routes.json`. **Der Fix gehört in Phase 1 und ist `flutter-coder`-Arbeit:** beide Frontends leiten ihre Supabase-/Proxy-URL heute aus dem **eigenen** Hostname ab (`https://db.${baseDomain}`), was cross-VPS grundsätzlich falsch ist (liegt die DB auf einem anderen VPS/Domain, sucht der Client sie am falschen Ort). Phase 1 stellt die Client-URLs auf **konfigurierbar** um (Override via `.env`, analog `RAPT_DASHBOARD_URL`/`STUDIO_URL`), mit `supabase.`-Default fürs Single-VPS-Setup. Damit ist die Prefix-Konsistenz automatisch gelöst UND der Cross-VPS-Fall abgedeckt. Umsetzung: `flutter-coder` (Phase 1).

---

## 4. Phasenplan

### Phase 1 — Fundament (dba-coder + cicd-coder + flutter-coder)
Supabase als **eigenständige, cross-VPS-erreichbare** Einheit + konfigurierbare Verbindungs-URLs (Server- UND Client-Seite) + Tunnel-Anbindung der DB.

- **dba-coder** (Phase 1): Connection-Security für Remote-Zugriff — Rollen/Grants, `sslmode`/TLS-Erwartung, Auswirkungen auf RLS / SECURITY DEFINER / Vault, wenn der Proxy nicht mehr im selben Docker-Netz hängt.
- **cicd-coder** (Phase 1): Compose-Zerlegung (heute monolithisch) in **je-Einheit-startbar**, `cloudflared`-TCP-Ingress + `access tcp`-Client für Postgres, env-Parametrisierung der Verbindungs-URLs, `cloudflare-routes.json`-Erweiterung.
- **flutter-coder** (Phase 1): `EnvConfig.supabaseUrl()` + `proxyUrl()` in **beiden** Flutter-Apps von host-abgeleitet auf **konfigurierbar** umstellen (Override via `.env`, analog `RAPT_DASHBOARD_URL`); non-local-Default `supabase.` (kanonisch, A-URL-1) bzw. unverändertes `api.`. Local-Branch + build-time `SUPABASE_ANON_KEY` unverändert.

**Schnittstelle dba ↔ cicd:** dba-coder definiert *welche* Rolle/Connection-String/`sslmode` der Proxy remote benutzen muss (DB-Inhalt); cicd-coder verdrahtet *wie* die TCP-Verbindung durch den Tunnel kommt und welche `.env`-Var das trägt (Container/Runtime). Die gemeinsame Größe ist `DATABASE_URL` (+ `SUPABASE_INTERNAL_URL`): **dba-coder spezifiziert den Inhalt, cicd-coder setzt ihn in compose/.env.**

**Schnittstelle cicd ↔ flutter:** Der Client-`.env`-Override-Key (`SUPABASE_URL`/`PROXY_URL` in den App-`.env.example`) muss zum nach-außen-sichtbaren Supabase-/Proxy-Hostname passen, den cicd-coder via `cloudflare-routes.json` (kanonisch `supabase.<domain>`, `api.<domain>`) bereitstellt. flutter-coder kann **unabhängig** laufen; die einzige Kopplung ist diese Namens-/Hostname-Konsistenz. Der Client-Default ohne gesetzten Override (`supabase.${baseDomain}`) deckt das Single-VPS-Setup ab.

### Phase 2 — Bedienung (cicd-coder)
`bootstrap.sh`-Menü zum gezielten **Installieren/Verschieben** einzelner Einheiten; SSH-orchestrierte Migration (Backup alt → stop alt → start neu → restore), Menü jederzeit erneut aufrufbar. **Setzt Phase 1 voraus** (selektiver Start, Cross-VPS-DB).

---

## 5. Was Frozen ist (nicht anfassen)
- **ufw + SSH-Hardening** — exakt wie es ist.
- **Supabase-Stack-Versionen** — gepinnt, kein Watchtower-Label, nicht bumpen ([[feedback_infra_split]]).
- **Secret-Pattern** — `.env.gpg` Source of Truth, EIN Bitwarden-Item für die Passphrase ([[project_secrets_setup]]). Jede `.env`-Änderung ⇒ `encrypt-env.sh` ⇒ Credential-Schritt.
- **DB-Schema-Inhalt** als solcher — Auth/RLS/Vault-Modell bleibt ([[project_auth_migration]]); Phase 1 ändert nur *Connection*-Aspekte, nicht das Tenancy-Modell.
- **Backup/Restore-Logik** — `backup.sh`/`restore.sh` werden in Phase 2 nur **aufgerufen**, nicht umgeschrieben.
- **App-Repos = reine Source** — Production-Compose lebt nur in `webPage_infra` ([[feedback_infra_split]]).

---

## 6. Cross-Agent-Befunde / Flags (keine Coder-Arbeit ohne separate Entscheidung)
1. **Hostname `db.` vs. `supabase.` (A-URL-1) — ENTSCHIEDEN, KEIN offener Flag mehr.** Kanonisch = `supabase.`; gelöst in Phase 1 durch `flutter-coder`, nicht durch `cloudflare-routes.json` (Server-Seite ist schon konsistent). Siehe §3 A-URL-1.
2. **Frontend-URL-Konfigurierbarkeit — ENTSCHIEDEN, jetzt Teil von Phase 1.** Die Client-URLs (`EnvConfig.supabaseUrl()`/`proxyUrl()`) werden in Phase 1 von host-abgeleitet auf **konfigurierbar** umgestellt (Override via `.env`, `supabase.`-Default). Umsetzender Agent: `flutter-coder` (Phase 1). Grund für den Vorzug der Override-Lösung gegenüber reiner Hostname-Ableitung: cross-VPS liegt die DB ggf. auf einer anderen Domain als das Frontend, dann ist die Eigen-Hostname-Ableitung falsch.
3. **brew-proxy-Code:** Der Proxy unterstützt `SUPABASE_INTERNAL_URL`/`DATABASE_URL` bereits als env-Override (`brew-proxy-new/server.js`). Es ist **kein** Proxy-Code-Change nötig. Falls doch (z.B. Connection-Pool-Tuning für höhere Latenz über den Tunnel), gibt es **keinen dedizierten Agenten** → general `claude` + User-Entscheidung.
4. **DB-Schema-Migrationen:** Falls Phase 1 eine neue Rolle/Grant-Migration braucht, ist das `dba-coder` (forward-only, nummeriert) — siehe Phase-1-dba-Spec.

---

## 7. Umsetzungs-Reihenfolge (historisch)
Die Arbeit lief in dieser Reihenfolge; die per-Agent-Specs waren transient und sind entfernt — Details in der git-Historie:
1. **Phase 1 dba-coder** — Connection-Vertrag (Rolle + `DATABASE_URL`/`sslmode`) zuerst.
2. **Phase 1 cicd-coder** — übernimmt den Vertrag, verdrahtet Compose/Tunnel/env (Schnittstelle §4).
3. **Phase 1 flutter-coder** — stellt die Client-URLs konfigurierbar. **Lief unabhängig** (auch parallel zu 1/2); Kopplung nur über den `.env`-Override-Key-Name + den kanonischen Hostname (`supabase.`/`api.`), die mit `cloudflare-routes.json` übereinstimmen müssen (Schnittstelle §4).
4. **Phase 2 cicd-coder** — `bootstrap.sh`-Menü (selektiver Start + SSH-Migration), nach Phase 1.
</content>
</invoke>
