# Phase 1 — Client-URLs konfigurierbar (Flutter)

**Ziel-Repos:** `brew_assistent-new` UND `RAPT_Brewing_Dashboard-new` (beide!)
**Umsetzender Agent:** flutter-coder
**Master-Kontext:** `webPage_infra/MULTIVPS_ARCHITEKTUR.md` (§3 A-URL-1, §4 Phasenplan, §6)
**Schwester-Specs (Phase 1):** `webPage_infra/PHASE1_DB_FUNDAMENT_DBA.md` (dba-coder), `webPage_infra/PHASE1_COMPOSE_TUNNEL_CICD.md` (cicd-coder)
**Kontext/Warum:** Beide Flutter-Apps leiten ihre Supabase-/Proxy-URL heute aus dem **eigenen** Hostname ab (`https://db.${baseDomain}`, `https://api.${baseDomain}/api`). Im Multi-VPS-Zielmodell kann die DB auf einem **anderen** VPS/Domain liegen als das Frontend — dann sucht der Client sie am falschen Ort. Phase 1 stellt die Client-URLs auf **konfigurierbar** um (Override via `.env`, analog zum bestehenden `RAPT_DASHBOARD_URL`-Muster), mit einem korrekten Single-VPS-Default. Das löst gleichzeitig die Hostname-Inkonsistenz A-URL-1: der non-local-Default für Supabase wird auf **`supabase.`** (statt `db.`) gesetzt — kanonisch, weil `cloudflare-routes.json` und `webPage_infra/.env.example` (`SUPABASE_PUBLIC_URL`) bereits `supabase.alexstuder.cloud` benutzen.

> Reine Client-Code-Änderung. KEIN Compose, KEIN DB-Schema, KEINE Auth-Logik, KEINE neue Dependency. `flutter_dotenv` ist bereits in beiden Apps in Gebrauch.

---

## Required reading für den Coder (zuerst lesen, an echte Funktionen andocken)
- `/Users/alex/Git/WebPageNew/CLAUDE.md` — verbindlich (Deployment-Workflow, „Claude macht alles selbst außer Credential-Schritten").
- `webPage_infra/MULTIVPS_ARCHITEKTUR.md` — §3 (A-URL-1 ist **ENTSCHIEDEN**: kanonisch `supabase.`), §6 Flag 1+2.
- `brew_assistent-new/lib/utils/env_config.dart` — das **Vorbild-Muster** für Override sitzt hier schon: `raptDashboardUrl()` (Z. 37–42) und `studioUrl()` (Z. 48–53) lesen `dotenv.env['…']` und fallen sonst auf Hostname-Ableitung zurück. `supabaseAnonKey()` (Z. 56) zeigt: dotenv-Asset = build-time. Genau dieses Muster auf `supabaseUrl()` (Z. 24–27) und `proxyUrl()` (Z. 30–33) übertragen.
- `RAPT_Brewing_Dashboard-new/lib/utils/env_config.dart` — analoge, schlankere `EnvConfig` (kein `raptDashboardUrl`/`studioUrl`). `supabaseUrl()` (Z. 15–18), `proxyUrl()` (Z. 20–23). **Hier das Override-Muster erstmals einführen** (es existiert in dieser App noch nicht).
- `brew_assistent-new/.env.example` — hat bereits `SUPABASE_URL=` und `PROXY_URL=` als Keys (Z. 2 + Z. 4), die `EnvConfig` heute **NICHT** liest (tote Keys → genau die jetzt verwenden). `RAPT_DASHBOARD_URL=` (Z. 7) ist das dokumentierte Override-Vorbild.
- `RAPT_Brewing_Dashboard-new/.env.example` — hat ebenfalls `PROXY_URL=` (Z. 1) + `SUPABASE_URL=` (Z. 2), heute mit abweichenden Local-Defaults (`PROXY_URL=http://localhost:3000/api/brew`, `SUPABASE_URL=http://127.0.0.1:54321`). Diese Keys wiederverwenden, nicht neue erfinden.
- `brew_assistent-new/lib/main.dart` (Z. 26 `dotenv.load(fileName: '.env')`, Z. 32 `url: EnvConfig.supabaseUrl()`) + `RAPT_Brewing_Dashboard-new/lib/main.dart` (Z. 13 `dotenv.load`, Z. 16 `url: EnvConfig.supabaseUrl()`) — bestätigt: dotenv ist geladen, bevor `EnvConfig` greift. Caller von `proxyUrl()`: `openai_service.dart`, `brewfather_service.dart`, `rapt_service.dart`, `recipe_detail_page.dart` (alle nur Lesezugriff auf den String → keine Signaturänderung).
- Agentenprofil `flutter-coder` (Required reading #4 nennt genau `env_config.dart` als Host-Derivation-Muster).

**Schnittstelle zu cicd-coder (Phase 1):** Der Override-Key-Name + der kanonische non-local-Hostname müssen zu dem passen, was `cloudflare-routes.json` nach außen veröffentlicht: Supabase = `supabase.<domain>`, Proxy = `api.<domain>`. Diese Spec hält sich an genau diese Hostnamen. Der Coder verifiziert vor dem Schreiben, ob `cloudflare-routes.json` noch `supabase.alexstuder.cloud` + `api.alexstuder.cloud` mappt (heute: ja, Z. 8–9).

---

## Ist → Soll

### Ist (beide Apps, in `lib/utils/env_config.dart`)
- `supabaseUrl()`: local → `http://localhost:54321`; non-local → `https://db.${_baseDomain()}` (**falsches Prefix**, kein Override).
- `proxyUrl()`: local → `http://localhost:8083/api`; non-local → `https://api.${_baseDomain()}/api` (kein Override).
- `SUPABASE_URL` + `PROXY_URL` stehen in beiden `.env.example`, werden vom Code aber nie gelesen → tote Keys.

### Soll
| Methode | local (unverändert) | Override-Key (`.env`) | non-local-Default (ohne Override) |
|---|---|---|---|
| `supabaseUrl()` | `http://localhost:54321` (brew) / `http://localhost:54321` (RAPT, s.u.) | `dotenv.env['SUPABASE_URL']`, falls non-empty | **`https://supabase.${_baseDomain()}`** (geändert von `db.`) |
| `proxyUrl()` | `http://localhost:8083/api` | `dotenv.env['PROXY_URL']`, falls non-empty | `https://api.${_baseDomain()}/api` (unverändert) |

**Override-Logik (exakt nach Vorbild `raptDashboardUrl`):**
```
final override = dotenv.env['SUPABASE_URL'];
if (override != null && override.isNotEmpty) return override;
if (_isLocalHost()) return 'http://localhost:54321';
return 'https://supabase.${_baseDomain()}';
```
Analog für `proxyUrl()` mit Key `PROXY_URL` und non-local-Default `https://api.${_baseDomain()}/api`.

**Wichtige Eigenschaften:**
- **Override greift IMMER** (auch local) — konsistent mit `raptDashboardUrl()`/`studioUrl()`, die den Override vor dem local-Check prüfen. Leerer/fehlender Key → bisheriges Verhalten (local-Branch bzw. Hostname-Ableitung).
- **Backward-Compat Single-VPS:** Ohne gesetzten Override bleibt alles funktionsfähig. Einziger sichtbarer Unterschied: Supabase-Default `supabase.` statt `db.` — das ist der **gewollte** A-URL-1-Fix (kanonisch, passt zu `cloudflare-routes.json` + `SUPABASE_PUBLIC_URL`).
- **`SUPABASE_ANON_KEY` bleibt build-time** aus dem dotenv-Asset — NICHT anfassen (`supabaseAnonKey()` unverändert).

---

## Items (in empfohlener Reihenfolge)

1. **brew_assistent: `supabaseUrl()` Override + Default-Fix** — **wo:** `brew_assistent-new/lib/utils/env_config.dart` (Z. 24–27) — **Akzeptanz:** Methode liest zuerst `dotenv.env['SUPABASE_URL']` (non-empty → return), dann local-Branch unverändert, sonst `https://supabase.${_baseDomain()}`. Doc-Kommentar an die Methode (analog `raptDashboardUrl`): „Override via .env (SUPABASE_URL); non-local-Default `supabase.` (kanonisch)." — Hinweise: Header-Doc-Kommentar der Klasse (Z. 3–11) ggf. minimal anpassen (erwähnt aktuell nur ANON_KEY als nicht-ableitbar; jetzt sind Supabase-/Proxy-URL ebenfalls override-fähig).

2. **brew_assistent: `proxyUrl()` Override** — **wo:** `brew_assistent-new/lib/utils/env_config.dart` (Z. 30–33) — **Akzeptanz:** liest `dotenv.env['PROXY_URL']` (non-empty → return), sonst local-Branch unverändert, sonst `https://api.${_baseDomain()}/api`. — Hinweise: Default-String exakt beibehalten (inkl. `/api`-Suffix), nur Override davorschalten.

3. **RAPT: `supabaseUrl()` Override + Default-Fix** — **wo:** `RAPT_Brewing_Dashboard-new/lib/utils/env_config.dart` (Z. 15–18) — **Akzeptanz:** wie Item 1, Override-Muster hier neu eingeführt (App hat es noch nicht), non-local-Default `https://supabase.${_baseDomain()}`. — Hinweise: Klassen-Doc-Kommentar (Z. 3–6) erwähnt `db.<domain>` als Soll → auf `supabase.<domain>` korrigieren.

4. **RAPT: `proxyUrl()` Override** — **wo:** `RAPT_Brewing_Dashboard-new/lib/utils/env_config.dart` (Z. 20–23) — **Akzeptanz:** wie Item 2. — Hinweise: Default-`/api`-Suffix beibehalten.

5. **`.env.example` beider Apps — bestehende Keys dokumentieren** — **wo:** `brew_assistent-new/.env.example` (Z. 2 `SUPABASE_URL`, Z. 4 `PROXY_URL`) + `RAPT_Brewing_Dashboard-new/.env.example` (Z. 2 `SUPABASE_URL`, Z. 1 `PROXY_URL`) — **Akzeptanz:** Keine neuen Key-Namen. Über/neben beide Keys einen Kommentar setzen, der das Override-Verhalten erklärt (analog dem bestehenden `RAPT_DASHBOARD_URL`-Kommentar in `brew_assistent-new/.env.example` Z. 5–6): „Optional: Override … Leer lassen → EnvConfig leitet aus aktuellem Hostname ab (Supabase: `supabase.<domain>`, Proxy: `api.<domain>`)." — Hinweise: Die Local-Default-WERTE in den `.env.example` dürfen so bleiben, wie sie sind (sie sind Beispielwerte; bei lokalem Lauf wird der Override genutzt). Der Coder prüft, dass die `.env.example`-Beispielwerte nicht in Konflikt zur Override-immer-Logik geraten — falls ein Beispielwert ungewollt einen Override erzwingt, der den local-Branch aushebelt, den Wert auf leer setzen oder als auskommentiertes Beispiel notieren. **Entscheidung des Coders, am echten dotenv-Ladeverhalten verifiziert.**

---

## Reihenfolge / Begründung
Kleinster Blast-Radius zuerst, eine App nach der anderen: brew_assistent (Items 1–2, hat das Override-Muster schon → mechanische Angleichung), dann RAPT (Items 3–4, Muster neu einführen), dann `.env.example`-Doku (Item 5, kein Code-Pfad). Beide `env_config.dart`-Änderungen sind isoliert pro Datei → je App ein logischer Commit (`refactor(env): SUPABASE_URL/PROXY_URL override + supabase.-default`), `.env.example`-Doku im selben Commit der jeweiligen App.

---

## Explizit NICHT im Scope
- **Keine** Änderung am local-Branch der Methoden (Ports/Hosts bleiben).
- **Keine** Änderung an `supabaseAnonKey()` — bleibt build-time aus dotenv.
- **Keine** Auth-/Session-/Schema-Logik, kein `Supabase.initialize`-Umbau in `main.dart` (nur die von `EnvConfig` gelieferten Strings ändern sich).
- **Kein** Compose/Dockerfile/CI-Touch (das macht cicd-coder, Schwester-Spec).
- **Keine** neue pubspec-Dependency (`flutter_dotenv` reicht und ist vorhanden).
- **Keine** Änderung am `RAPT_DASHBOARD_URL`/`STUDIO_URL`-Verhalten.
- **Keine** Vereinheitlichung der zwei `EnvConfig`-Klassen in ein geteiltes Package (App-Repos sind getrennt — [[feedback_infra_split]]).

## Braucht Freigabe / außerhalb flutter-coder-Scope
- (keine) — reine Client-Code-Änderung innerhalb des flutter-coder-Scopes; keine DB-, Dependency-, Page- oder Compose/CI-Berührung.
- Hinweis (kein Blocker für diese Spec): Ob in einer **echten** Deploy-`.env` tatsächlich ein `SUPABASE_URL`/`PROXY_URL`-Override gesetzt wird, ist eine Deploy-Zeit-Entscheidung (Single-VPS braucht keinen Override). Wird ein Override in der `webPage_infra`-`.env` gesetzt, ist das eine `.env`-Änderung ⇒ `.env.gpg` re-encrypt = Credential-Schritt — **nicht** Teil dieser Code-Spec.

## Akzeptanzkriterien (gesamt)
- `flutter analyze` in **beiden** Repos: 0 issues.
- `supabaseUrl()` (beide Apps): mit gesetztem `SUPABASE_URL` in `.env` → genau dieser Wert; ohne + non-local → `https://supabase.${_baseDomain()}`; local → unverändert.
- `proxyUrl()` (beide Apps): mit gesetztem `PROXY_URL` → genau dieser Wert; ohne + non-local → `https://api.${_baseDomain()}/api`; local → unverändert.
- Kein `db.`-Prefix mehr im Code (`grep -rn 'db.\$' lib/` bzw. `db.\${` → 0 Treffer für die Supabase-URL).
- Caller von `proxyUrl()`/`supabaseUrl()` unverändert (Signaturen identisch → `grep -rn` bestätigt keinen Bruch).
- Smoke-Test laut Agentenprofil: `flutter build web --release` + lokaler Docker-Run → HTTP 200 auf der Probe-URL. (Der Default-Pfad ohne Override muss weiter bauen + laden.)

## Credential-Schritte (User muss tun)
- (keine) — reine Code-Änderung. Ein `.env.gpg`-Re-Encrypt fällt nur an, wenn zur Deploy-Zeit ein echter Override in der `webPage_infra`-`.env` gesetzt wird (außerhalb dieser Spec).

## Launch-Instruktion für flutter-coder (copy-paste)
> Starte `flutter-coder` mit diesem Spec: `/Users/alex/Git/WebPageNew/webPage_infra/PHASE1_CLIENT_URLS_FLUTTER.md`
>
> Stelle `EnvConfig.supabaseUrl()` und `proxyUrl()` in **beiden** Apps (`brew_assistent-new` + `RAPT_Brewing_Dashboard-new`) von host-abgeleitet auf konfigurierbar um — Override via `dotenv.env['SUPABASE_URL']` bzw. `['PROXY_URL']` (exakt nach dem bestehenden `raptDashboardUrl()`-Muster), Override greift vor dem local-Check. Ohne Override: local-Branch unverändert; non-local-Default für Supabase auf **`https://supabase.${_baseDomain()}`** ändern (kanonisch, ersetzt `db.`), für Proxy `https://api.${_baseDomain()}/api` unverändert. `SUPABASE_ANON_KEY` bleibt build-time. Verwende die **bestehenden** Keys `SUPABASE_URL`/`PROXY_URL` aus den `.env.example` (keine neuen Namen) und dokumentiere ihr Override-Verhalten dort (analog dem `RAPT_DASHBOARD_URL`-Kommentar). KEIN Compose/CI/Dependency/Schema-Touch. `flutter analyze` = 0 issues in beiden Repos, dann der lokale Docker-Smoke-Test laut deinem Profil. Pro App ein logischer Commit + push.
