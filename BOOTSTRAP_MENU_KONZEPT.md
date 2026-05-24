# Phase 2 — Bootstrap-Menü: Selektive Einheiten-Installation + SSH-orchestrierte VPS-Migration

**Umsetzender Agent:** cicd-coder
**Phase:** 2 (Bedienung) — **setzt Phase 1 voraus** (`webPage_infra/PHASE1_COMPOSE_TUNNEL_CICD.md` + `PHASE1_DB_FUNDAMENT_DBA.md`).
**Master-Kontext:** `webPage_infra/MULTIVPS_ARCHITEKTUR.md` (Zielmodell der 4 Einheiten).
**Ziel:** `scripts/bootstrap.sh` erhält nach dem bestehenden Basis-Bootstrap ein interaktives Menü mit zwei Aktionen — (1) einzelne Einheit gezielt installieren/starten, (2) eine Einheit per SSH von einem alten VPS auf den neuen VPS migrieren (Umzug). Das Menü ist auf einem bereits gebootstrappten, laufenden VPS jederzeit erneut aufrufbar (Basis-Schritte werden dann übersprungen).

> **Aktualisierung gegenüber der ersten Fassung dieses Dokuments:** Diese Spec ging ursprünglich von „Option A" aus (geteilte Supabase, KEIN Compose-Umbau, selektiver Start nur über Service-Namen). Das Zielmodell hat sich zu einem **Multi-VPS-Umbau mit 4 Einheiten** entwickelt (Master `MULTIVPS_ARCHITEKTUR.md`). Die **Migrations-Schrittfolge a–d (§5.2.2), die Shell-Safety-Vorgaben (§6) und der idempotente Wiedereinstieg (§4.2) bleiben unverändert gültig** und sind weiterhin der Kern dieser Phase-2-Spec. Was sich ändert:
> - „App" → **„Einheit"** im Sinne der 4 Einheiten aus dem Master (brew_assistent / rapt_dashboard / proxy / Supabase-DB).
> - Der **selektive Start** baut auf dem auf, was Phase 1 (cicd-coder) liefert (saubere je-Einheit-Startbarkeit; falls Phase 1 Per-Einheit-Profile eingeführt hat, nutzt das Menü diese statt der reinen Service-Namen-Mappings).
> - Die **Cross-VPS-DB-Erreichbarkeit** (Tunnel-TCP, `DATABASE_URL`-Parametrisierung) kommt aus Phase 1 — das Menü konfiguriert sie nicht neu, sondern setzt sie voraus.
> - Die **Migration der DB** läuft weiterhin über `backup.sh`/`restore.sh` (Variante A); stateless Einheiten werden per Stop-alt/Start-neu + URL-Repoint verschoben (keine Datenmigration).

---

## 1. Problem / Ziel

Heute zieht `bootstrap.sh` am Ende immer den **kompletten** Stack hoch (`docker compose --profile vps up -d`). Es gibt:
- keine Möglichkeit, gezielt nur **eine Einheit** zu installieren/starten (z.B. nur RAPT, nur die statische Hauptseite, nur die Supabase/DB-Einheit),
- keinen unterstützten Weg, eine Einheit **von einem alten VPS auf einen neuen umzuziehen** (DB: Backup → Stop alt → Start neu → Restore; stateless: Stop alt → Start neu → URL-Repoint).

Das Script ist **noch nie auf einem echten VPS gelaufen**. Es soll um genau dieses Menü erweitert werden — schlank, ohne zusätzliche Health-Checks, ohne Hardening-Änderungen.

**Phase-1-Abhängigkeit (zwingend zuerst):** Dieses Menü setzt voraus, dass Phase 1 (`PHASE1_COMPOSE_TUNNEL_CICD.md` + `PHASE1_DB_FUNDAMENT_DBA.md`) bereits umgesetzt ist — d.h. die Einheiten sind sauber je-Einheit-startbar, `DATABASE_URL`/`SUPABASE_INTERNAL_URL` sind `.env`-parametrisiert, und die Cross-VPS-DB-Erreichbarkeit (Cloudflare-Tunnel-TCP) existiert. Falls Phase 1 **Per-Einheit-Profile** eingeführt hat (`profiles: [assistent|rapt|proxy|supabase]`), nutzt das Menü diese; falls nicht, läuft der selektive Start über die Service-Namen-Mappings (§5.1). Der Coder MUSS den tatsächlichen Phase-1-Stand der `docker-compose.yml` lesen und sich danach richten (Annahme V-9, §8).

---

## 2. Required reading für den Coder

Zuerst lesen, an echte Funktionsnamen/Pfade andocken:

- `/Users/alex/Git/WebPageNew/CLAUDE.md` — verbindlich (Secret-Pattern, „Claude macht alles selbst außer Credential-Schritten").
- `webPage_infra/MULTIVPS_ARCHITEKTUR.md` — Zielmodell (4 Einheiten, Cross-VPS-Connectivity, was Frozen ist). **Verbindlicher Kontext für „Einheit" = brew_assistent / rapt_dashboard / proxy / Supabase-DB.**
- `webPage_infra/PHASE1_COMPOSE_TUNNEL_CICD.md` + `webPage_infra/PHASE1_DB_FUNDAMENT_DBA.md` — Phase-1-Ergebnis (selektive Startbarkeit, `.env`-URL-Parametrisierung, Tunnel-TCP). **Den nach Phase 1 tatsächlichen Stand der `docker-compose.yml` lesen** — Profile vs. Service-Namen (V-9).
- `webPage_infra/scripts/bootstrap.sh` — der zu erweiternde Hauptpfad. Helfer `log()`/`ok()`/`err()`, Konstanten `APP_USER=alex`, `APP_DIR=/home/alex/webPage_infra`, `BW_ITEM`, das `sudo -u "$APP_USER" -H ... bash <<'EOSU'`-Muster, der `trap 'rm -f ...' EXIT` für Secret-Tempfiles, der `--profile vps`-Aufruf, der Cloudflare-Reconcile-Block, der idempotente Cron-Drop-in.
- `webPage_infra/scripts/backup.sh` — Aufrufsignatur: `./scripts/backup.sh [--label <name>] [--no-upload]`. `--label pre-migration` ist **rotation-exempt**. Erzeugt drei Dumps in `backups/{_supabase_core,brew_assistent,rapt_dashboard}/` und lädt nach R2 `${R2_BUCKET}/<folder>/`.
- `webPage_infra/scripts/restore.sh` — Aufrufsignatur: `./scripts/restore.sh <core|brew_assistent|rapt_dashboard|all> [file|latest] [--yes]`. `latest` zieht jüngste `.fc.gpg` aus dem passenden R2-Ordner. Reihenfolge bei `all`: core → brew_assistent → rapt_dashboard.
- `webPage_infra/docker-compose.yml` — **AUTORITATIVE Realität** (siehe Annahmen unten): Services `web_hauptseite`, `web_assistent`, `web_rapt`, `api_proxy`, Supabase-Stack (`supabase-db` … `supabase-kong`), `cloudflared`/`watchtower` (nur `profiles: [vps]`). **Es gibt nur EIN Netzwerk `brewing_net`** — keine getrennten `assistent_net`/`rapt_net`/`supabase_net`. **Es gibt KEIN Per-App-Profil.**
- `webPage_infra/scripts/cloudflare-reconcile.sh` + `scripts/cloudflare-routes.json` — Hostname→Container-Mapping, idempotent.
- `webPage_infra/scripts/decrypt-env.sh` / `encrypt-env.sh` — `.env.gpg`-Pattern, `--passphrase-fd`/`--passphrase-file`, nie Passphrase in argv.
- Memory: [[project_backup_restore]] (Variante A, keep-N=7, cron als alex, `/etc/brewing/gpg.pass`), [[project_secrets_setup]] (`.env.gpg`, EIN Bitwarden-Item), [[feedback_proxy_docker_networks]] (Proxy hängt seit BFF an Supabase-Netz).

---

## 3. Ist-Zustand (knapp, auf Basis des echten Scripts)

`bootstrap.sh` läuft linear als root durch:
Pre-flight (root + Ubuntu) → 3 interaktive Eingaben (BW-Mail, BW-Master-PW, Linux-User-PW) → apt update/upgrade + Base-Packages → User `alex` (UID 1000, sudo+docker) → Docker → Bitwarden CLI → Repo clonen bzw. `git fetch` + `reset --hard origin/main` (mit dirty-tree-Guard) → BW unlock → GPG-Passphrase in 600-Tempfile → `.env` via `decrypt-env.sh` → Passphrase nach `/etc/brewing/gpg.pass` → `docker compose --profile vps pull && up -d` → Cloudflare-Reconcile (falls Token in `.env`) → idempotenter Cron-Drop-in (Backup 03:00 als alex) → Abschluss-Text. **Kein Menü, kein selektiver Start, keine Migration.**

---

## 4. Soll-Zustand: das Menü-Feature

### 4.1 Einhängepunkt im Flow

- Der gesamte bestehende Basis-Bootstrap (Abschnitte „System" bis „Nightly Backup-Cron") bleibt erhalten und läuft **zuerst**.
- **Der Schritt „Container starten" (`--profile vps pull && up -d`, Zeilen 217–225) wird NICHT mehr unbedingt ausgeführt.** Stattdessen ruft `bootstrap.sh` nach dem Cron-Setup die neue Funktion `main_menu()` auf. Der bisherige Voll-Start wird zu einer Menü-Option „Alles starten (kompletter Stack, wie bisher)".
- Cloudflare-Reconcile bleibt als eigener Schritt, wird aber **nach** einer Installations-/Migrations-Aktion aufgerufen (eine App-Installation kann neue Hostnames brauchen). Empfehlung: Reconcile als wiederverwendbare Funktion `cf_reconcile_if_token()` kapseln und nach jeder Aktion aufrufen, die Container gestartet hat.

### 4.2 Idempotenter Wiedereinstieg (erneuter Aufruf auf laufendem VPS)

Beim erneuten Lauf von `bootstrap.sh` müssen die Basis-Schritte **erkannt-und-übersprungen** werden, damit man direkt ins Menü gelangt. Pro Basis-Schritt eine Skip-Bedingung (check-before-do):

| Schritt | Skip-Bedingung (bereits erledigt → überspringen) |
|---|---|
| Base-Packages | `command -v docker && command -v bw && command -v rclone && command -v jq` alle vorhanden |
| Linux-User `alex` | `id alex` erfolgreich → kein erneutes `chpasswd`-Prompt nötig |
| Docker | `command -v docker` |
| Bitwarden CLI | `command -v bw` |
| Repo | `[[ -d "$APP_DIR/.git" ]]` → `fetch` + `reset --hard` (bestehender dirty-tree-Guard bleibt) |
| `.env` | `[[ -f "$APP_DIR/.env" ]]` → kein erneutes BW-Login/Decrypt nötig |
| `/etc/brewing/gpg.pass` | `[[ -s /etc/brewing/gpg.pass ]]` |
| Cron-Drop-in | bleibt wie bisher idempotent (wird jedes Mal neu geschrieben) — unverändert lassen |

**Wichtig für die interaktiven Eingaben:** Die drei `read`-Prompts (BW-Mail/PW, User-PW) dürfen beim Wiedereinstieg **nicht** erzwungen werden, wenn `.env` + `gpg.pass` schon existieren und der User `alex` schon da ist. Lösung: Die Prompts erst dann anfordern, wenn der jeweilige Schritt tatsächlich ausgeführt werden muss (BW-Login/Decrypt nur falls `.env` fehlt; User-PW nur falls User neu angelegt wird). → Eingaben „lazy" pro Bedarf erfragen statt alle drei pauschal oben.

- **Optionaler Direkteinstieg:** `bootstrap.sh --menu` springt (nach Pre-flight + Skip-Checks) direkt ins Menü und überspringt jeden bereits erledigten Basis-Schritt geräuschlos. Argument-Parsing via `getopts` (oder `case "$1"`), default ohne Argument = normaler Lauf mit Skip-Erkennung. Pre-flight (`root` + Ubuntu) gilt weiterhin immer.

### 4.3 Menü-Struktur (konkreter Text der Optionen)

```
▶ Brewing-Stack — Aktion wählen

  1) Komplett-Stack starten        (docker compose --profile vps up -d, wie bisher)
  2) Einzelne App installieren     (gezielt einen Stack hochziehen)
  3) App migrieren (VPS-Umzug)     (Backup alt → Stop alt → Start neu → Restore)
  q) Beenden

Auswahl [1-3,q]:
```

`read -rp` einlesen, `case` darüber. Ungültige Eingabe → Hinweis + Menü erneut zeigen (Schleife). `q`/EOF → sauber beenden.

#### Untermenü Option 2 — Einzelne App installieren

```
▶ Welche App installieren/starten?

  1) brew_assistent + Supabase   (web_assistent + kompletter supabase-* Stack)
  2) RAPT Dashboard              (web_rapt)
  3) brew-proxy (API)            (api_proxy — braucht laufendes Supabase)
  4) WebPageAlexStuder           (web_hauptseite, statisches Nginx)
  b) zurück

Auswahl [1-4,b]:
```

---

## 5. Technische Detail-Vorgaben

### 5.1 Aktion 2 — Selektive App-Installation

**Realität:** Die Compose-Datei hat **kein Per-App-Profil** und nur **ein** Netzwerk (`brewing_net`). Selektives Starten geht daher über **gezieltes `docker compose up -d <service ...>`** (Compose startet `depends_on`-Abhängigkeiten automatisch mit). Es werden KEINE neuen Profile/Netzwerke eingeführt, solange das nicht freigegeben ist (siehe §8 + §9).

Service-Zuordnung je Menüpunkt (autoritativ — exakt diese Servicenamen aus `docker-compose.yml`):

| Menü | `docker compose up -d <services>` | Zieht mit (depends_on) |
|---|---|---|
| 1) brew_assistent + Supabase | `web_assistent supabase-kong` | `supabase-kong` → auth/rest/realtime/storage/meta → `supabase-db` (healthy). Damit kommt der komplette Supabase-Core mit. |
| 2) RAPT Dashboard | `web_rapt` | (keine — statisches Frontend; RAPT-Daten kommen über api_proxy/Supabase, nicht über web_rapt selbst) |
| 3) brew-proxy | `api_proxy` | **keine compose-`depends_on`** auf Supabase! `api_proxy` braucht aber laufendes `supabase-db` (DATABASE_URL). → der Coder muss vor `api_proxy`-Start prüfen, ob `supabase-db` läuft (`docker inspect supabase-db`), und falls nicht, `supabase-db` (bzw. `supabase-kong`) mit-hochziehen oder den User klar warnen. |
| 4) WebPageAlexStuder | `web_hauptseite` | (keine) |

Vorgaben:
- Aufruf als `alex` im `$APP_DIR` (gleiches `sudo -u "$APP_USER" -H APP_DIR="$APP_DIR" bash <<'EOSU' … EOSU`-Muster wie der bestehende Start-Block). `cd "$APP_DIR"` zuerst.
- `docker compose ... pull <services>` vor `up -d <services>` (gleiche Reihenfolge wie heute).
- **Profil-Frage:** `cloudflared`/`watchtower` hängen an `profiles: [vps]`. Für eine selektive App MUSS der Tunnel laufen, sonst ist die App nicht erreichbar. Vorgabe: bei jeder selektiven Installation `cloudflared` mitstarten (`--profile vps up -d <services> cloudflared` ODER separater Start), und danach `cf_reconcile_if_token()` aufrufen. Der Coder soll den minimal nötigen, aber funktionierenden Befehl wählen und im Script kommentieren.
- Abhängigkeits-Warnung explizit ausgeben (z.B. „brew-proxy braucht ein laufendes Supabase — wird mitgestartet" bzw. „Supabase läuft bereits").
- Nach dem Start: keine zusätzlichen Health-Checks (bewusst out of scope, §8). Nur `ok "<App> gestartet"`.

### 5.2 Aktion 3 — SSH-orchestrierte VPS-Migration (Umzug)

**Ausführungsort:** Das Menü läuft auf dem **NEUEN** VPS. Der User wählt „App migrieren". Das Script SSHt selbst in den **ALTEN** VPS.

**Welche App migrierbar:** Untermenü analog 5.1, aber mappt auf die **Backup/Restore-Ziele** (nicht auf reine Frontend-Container):

```
▶ Welche App migrieren?

  1) brew_assistent   (Schema aibrewgenius + Frontend web_assistent + Supabase-Core)
  2) RAPT Dashboard   (Schema rapt + Frontend web_rapt)
  b) zurück
```

- `WebPageAlexStuder` (statisches Nginx) und `brew-proxy` haben **keine eigene DB** → für sie gibt es nichts zu „migrieren" außer den Container; sie sind hier bewusst **nicht** als Migrationsziel gelistet (Frontend kommt ohnehin per Image aus Docker Hub). Falls der User sie umziehen will: Hinweis ausgeben „nur Container-Start, keine Daten — via Option 2 installieren".
- **Achtung Supabase-Core:** `brew_assistent` und `rapt` teilen sich `auth.users` im `_supabase_core`-Dump. Wenn auf dem neuen VPS noch KEIN Supabase mit Daten existiert, muss `core` mitmigriert werden (Restore-Reihenfolge core → app). Wenn auf dem neuen VPS bereits eine zweite App mit eigenen Usern läuft, würde ein `core`-Restore (`--clean`) deren auth.users überschreiben. → Der Coder MUSS diesen Konflikt vor dem Restore prüfen/abfragen und im Zweifel abbrechen statt blind `core` zu überschreiben (siehe Rollback §5.2.4). Dies als expliziten Sicherheits-Check implementieren.

#### 5.2.1 SSH-Zugang neu → alt

- Eingaben beim Migrations-Start (interaktiv, via `read`):
  - `OLD_VPS_HOST` (IP oder Hostname des alten VPS)
  - `OLD_VPS_USER` (default `alex` — gleicher App-User wie hier)
  - SSH-Port (default `22`)
- **Auth:** SSH-Key-basiert. Vorgabe: das Script generiert KEINE Keys automatisch (kein neues Key-Material ohne Not). Stattdessen:
  - Prüfen, ob ein passwortloser SSH-Login als `$OLD_VPS_USER@$OLD_VPS_HOST` möglich ist (`ssh -o BatchMode=yes -o ConnectTimeout=5 ... true`).
  - Falls nicht: klar dem User sagen, dass er erst Key-Zugang einrichten muss (Credential-Schritt, §10) — Migration abbrechen, NICHT auf Passwort-Prompt zurückfallen (vermeidet hängende Prompts in Sub-SSH-Befehlen).
- SSH-Befehle laufen als `alex` (der gehört der docker-Gruppe an → `docker exec`/`docker compose` ohne sudo, owner des Repos + `/etc/brewing/gpg.pass`). Auf dem alten VPS liegt dasselbe Repo unter `/home/alex/webPage_infra`.

#### 5.2.2 Exakte Schrittfolge a–d (zwingende Reihenfolge)

**(a) Auf dem ALTEN VPS ein frisches, verifiziertes Backup erstellen:**
```
ssh alex@OLD  'cd ~/webPage_infra && ./scripts/backup.sh --label pre-migration'
```
- `--label pre-migration` ⇒ rotation-exempt (wird auf dem alten VPS nicht von keep-N weggeräumt) und liegt sofort in R2 `${R2_BUCKET}/<folder>/`.
- **Verifizieren, BEVOR gestoppt wird:** Nach dem Backup prüfen, dass die erwartete `*_pre-migration.fc.gpg` (für `_supabase_core` + den App-Ordner) tatsächlich in R2 liegt — z.B. per `ssh alex@OLD 'cd ~/webPage_infra && rclone ... lsf'` oder über einen kleinen Verify-Aufruf. Erst wenn das Backup nachweislich existiert, weiter zu (b). Schlägt die Verifikation fehl → **Abbruch, alte App bleibt laufend** (§5.2.4).

**(b) App auf dem ALTEN VPS stoppen:**
```
ssh alex@OLD 'cd ~/webPage_infra && docker compose stop <frontend-service(s) der App>'
```
- Nur die App-Frontend-Container stoppen (`web_assistent` bzw. `web_rapt`). **Supabase-DB auf dem alten VPS NICHT zwingend stoppen** — sie kann weiterlaufen; entscheidend ist, dass keine neuen Writes nach dem Backup mehr in die migrierte App fließen. Der Coder soll den minimalen Stop-Satz wählen (Frontend stoppen reicht, um die App „offline" zu nehmen); ob `supabase-db` mit gestoppt wird, als Annahme markieren (§9).
- `docker compose stop` (nicht `down`) — Volumes bleiben, falls Rollback nötig.

**(c) Auf dem NEUEN VPS die App hochziehen:**
- Exakt der selektive Installations-Pfad aus §5.1 für die gewählte App (inkl. Supabase-Core, falls nötig).

**(d) Backup auf dem NEUEN VPS restoren:**
```
cd ~/webPage_infra
./scripts/restore.sh core <…pre-migration…> --yes      # nur falls core mitmigriert
./scripts/restore.sh <brew_assistent|rapt_dashboard> latest --yes
```
- `restore.sh ... latest` zieht die jüngste `.fc.gpg` aus R2 — das ist nach (a) der frische `pre-migration`-Dump (vorausgesetzt, er ist der jüngste; falls ein labelloser Dump jünger wäre, stattdessen den konkreten Dateipfad/-namen an `restore.sh` übergeben — der Coder soll den `pre-migration`-Dump explizit selektieren, nicht blind `latest`, um Verwechslung zu vermeiden).
- `--yes` weil das Menü selbst schon eine Bestätigung eingeholt hat (siehe unten). Reihenfolge core → app strikt einhalten (restore.sh erzwingt das bei `all`; bei Einzelaufrufen muss das Menü die Reihenfolge selbst garantieren).

#### 5.2.3 Bestätigung vor destruktivem Teil

- Vor (b)+(d): einmalige, klare Zusammenfassung ausgeben („Alter VPS: X · App: Y · es wird auf dem NEUEN VPS per --clean restored, vorhandene Daten im Ziel-Schema werden überschrieben") und `read`-Bestätigung verlangen (z.B. Tippen von `migrate`). Kein TTY → Abbruch (analog restore.sh).

#### 5.2.4 Idempotenz / Rollback / Reihenfolge-Sicherheit

- **Backup-first, verify-before-stop:** (b) wird NUR erreicht, wenn (a) inkl. R2-Verifikation erfolgreich war.
- **Restore-Fehler:** `restore.sh` toleriert bekannte nicht-fatale Supabase-Fehler (Exit-Code wird dort nicht hart bewertet). Das Menü soll nach (d) NICHT automatisch die alte App auf dem alten VPS wieder starten — der alte Stand bleibt (App gestoppt, Daten + `pre-migration`-Dump intakt) als manuelles Rollback-Netz. Dem User am Ende ausgeben: „Rollback bei Bedarf: auf dem alten VPS `docker compose start <service>`; der pre-migration-Dump liegt rotation-exempt in R2."
- **Re-run-Sicherheit:** Bricht die Migration zwischen (a) und (d) ab, kann das Menü erneut gestartet werden; (a) läuft idempotent neu (neuer Timestamp), (c) ist idempotent (`up -d`), (d) ist re-runnable (`--clean`).
- **Supabase-Core-Überschreib-Schutz:** siehe §5.2 — vor `core`-Restore prüfen, ob auf dem neuen VPS bereits fremde auth.users existieren; im Konfliktfall abbrechen statt überschreiben.

#### 5.2.5 Cross-Referenzen nach dem Umzug (anpassen / hinweisen)

Nach erfolgreicher Migration ändern sich evtl. URLs/Routing. Das Script soll diese NICHT still raten, sondern reconcilen bzw. klar als To-do ausgeben:

- **Cloudflare-Tunnel-Routing:** Auf dem NEUEN VPS `cf_reconcile_if_token()` aufrufen → der Hostname der migrierten App (`aibrewgenius.alexstuder.cloud` bzw. `rapt.alexstuder.cloud`, siehe `cloudflare-routes.json`) zeigt dann auf den neuen Tunnel. Auf dem ALTEN VPS muss derselbe Hostname aus dem Tunnel/DNS verschwinden — Hinweis ausgeben: „Auf dem alten VPS Hostname aus `cloudflare-routes.json` entfernen + `cloudflare-reconcile.sh` laufen lassen, sonst konkurrierende Tunnel-Ingress-Einträge."
- **`RAPT_DASHBOARD_URL`:** Wenn RAPT auf einen anderen VPS umzieht als `brew_assistent` (vgl. CLAUDE.md „Currently Brewing"), muss in der `brew_assistent`-`.env` `RAPT_DASHBOARD_URL` auf die neue RAPT-URL zeigen. Das ist eine `.env`-Änderung → `.env.gpg` re-encrypt (Credential-Schritt, §10). Das Script soll diesen Bedarf **erkennen und ausgeben**, ihn aber nicht automatisch durchführen (Passphrase nötig). Konkret: nach RAPT-Migration Hinweis „RAPT läuft jetzt auf <neu> — `RAPT_DASHBOARD_URL` in brew_assistent/.env prüfen/setzen + .env.gpg neu verschlüsseln."

---

## 6. Shell-Safety-Vorgaben (verbindlich für cicd-coder)

- `set -euo pipefail` bleibt am Script-Anfang. Neue Funktionen dürfen es nicht aufweichen.
- Jede Expansion gequotet (`"$VAR"`), `[[ ]]` statt `[ ]`, `case` für Menü-Dispatch.
- **Keine `export VAR="$(cmd)"`-Einzeiler** — erst zuweisen (failt bei Fehler), dann `export` (siehe Lessons im Agenten-Profil, Zeilen 167/173/190 waren genau das).
- **Jedes Secret-Tempfile sofort mit `trap '...' EXIT` schützen** (Lesson 2026-05-24). Falls die Migration neue Tempfiles braucht (z.B. R2-Verify-Output), `mktemp` + sofortige `trap`-Erweiterung; bestehende `trap`-Kette nicht überschreiben, sondern konsolidieren (das Script hat aktuell EINE EXIT-trap — beim Erweitern aufpassen, dass alle Tempfiles erfasst bleiben).
- **Keine Secrets ins Log / in argv:** GPG-Passphrase nie auf CLI; SSH-Befehle dürfen keine Passwörter/Keys enthalten; kein `set -x` um BW/GPG/SSH-Blöcke; kein `docker compose config` in ein Log (expandiert `.env`).
- SSH-Aufrufe: `-o BatchMode=yes -o ConnectTimeout=<n>`, Remote-Kommando als **einzelner gequoteter String**; bei Pfad-/Variableninterpolation auf der Remote-Seite vorsichtig (lieber feste Pfade `~/webPage_infra` als Host-Variablen durchreichen).
- Idempotenz: Skip-Checks (§4.2) als `command -v` / `id` / `[[ -f ]]`-Guards, kein blindes Neu-Anlegen.
- `log()`/`ok()`/`err()` aus `bootstrap.sh` wiederverwenden — keine eigenen Ausgabe-Helfer.
- `bash -n` + `shellcheck` (falls verfügbar) auf das geänderte Script. Menü-Dispatch und Skip-Logik per Dry-Run / lokal durchspielen, soweit ohne echten VPS möglich.

---

## 7. Explizit NICHT im Scope

- **Kein finaler Smoke-/Health-Check** nach dem Start (User will es schlank).
- **ufw / SSH-Hardening NICHT anfassen** — bleibt exakt wie es ist.
- **Kein** generischer Update/Re-Deploy-Menüpunkt, **kein** DB-Migrations-Menüpunkt, **kein** eigenständiger Backup/Restore-Menüpunkt (Backup/Restore nur eingebettet in die Migrations-Aktion).
- Keine neuen Tools/Packages außer dem, was schon installiert wird (docker, bw, rclone, jq, unzip, cron, ufw, curl, git, gnupg) — `ssh`/`scp` sind auf Ubuntu Standard. **Keine neue apt-Dependency ohne Freigabe.**
- Keine Änderung an `backup.sh`/`restore.sh`-Logik selbst — sie werden nur aufgerufen.
- Kein automatisches Wiederanwerfen der alten App nach erfolgreichem Restore (Rollback bleibt manuell, §5.2.4).

---

## 8. Offene technische Punkte / Annahmen (Coder MUSS verifizieren)

1. **Netzwerk-Realität:** Die Anforderung nennt `assistent_net`/`rapt_net`/`supabase_net`. Die echte `docker-compose.yml` hat **nur `brewing_net`**. Das Konzept geht von der echten Datei aus (alle Services in `brewing_net`). Falls eine Netz-Trennung gewünscht ist, ist das eine **Compose-Schema-Änderung → Freigabe nötig** (§9). Coder: NICHT eigenmächtig Netze einführen.
2. **Per-App-Profile gibt es nicht.** Selektiver Start läuft über `docker compose up -d <service>`. Wenn der User saubere Per-App-Profile will (`profiles: [assistent]` etc.), ist das eine Compose-Änderung → Freigabe (§9). Coder soll im Script kurz kommentieren, dass selektiver Start ohne Profile über Service-Namen läuft.
3. **`api_proxy` hat keinen `depends_on` auf Supabase** (vgl. [[feedback_proxy_docker_networks]]: Proxy sollte eigentlich auch am Supabase-Netz hängen — heute alle in `brewing_net`, also erreichbar). Coder muss den „Supabase-läuft?"-Check für Menüpunkt 2/3 selbst implementieren, da Compose ihn nicht erzwingt.
4. **Backup-Verifikation in R2:** Genaue rclone-`lsf`-Pfadform (`R2:${R2_BUCKET}/<folder>/`) aus `backup.sh`/`restore.sh` übernehmen; R2-Remote-Setup via `RCLONE_CONFIG_R2_*`-Env-Vars (nicht in argv) — Muster aus `backup.sh` `setup_r2_remote()` wiederverwenden.
5. **`pre-migration`-Dump als jüngster:** Annahme, dass direkt nach (a) kein neuerer labelloser Dump existiert; sicherer ist, den konkreten Dateinamen aus dem (a)-Output zu greifen und an `restore.sh <ziel> <pfad/name>` zu übergeben statt `latest`. Coder soll den robusteren Weg wählen.
6. **Stop-Umfang auf dem alten VPS:** Annahme, dass das Stoppen der Frontend-Container (`web_*`) genügt, um die App offline zu nehmen; `supabase-db` muss nicht zwingend gestoppt werden. Coder verifiziert/markiert.
7. **Gleicher Repo-Pfad + gleicher User auf altem VPS** (`/home/alex/webPage_infra`, User `alex`, docker-Gruppe, `/etc/brewing/gpg.pass` vorhanden) — Annahme aus dem Bootstrap-Standard. Falls abweichend: SSH-Befehle würden scheitern → klare Fehlermeldung statt stiller Annahme.
8. **R2-Bucket geteilt zwischen alt + neu:** Beide VPS nutzen denselben R2-Bucket/dieselben Ordner (Variante A). Das ist Voraussetzung dafür, dass der neue VPS den vom alten VPS erzeugten Dump per `restore.sh latest` sieht. Coder geht davon aus; falls getrennte Buckets → Migration über R2 funktioniert nicht.
9. **V-9 — Phase-1-Stand der `docker-compose.yml`:** Diese Spec setzt Phase 1 voraus. Der Coder MUSS die **aktuelle** `docker-compose.yml` lesen und feststellen, ob Phase 1 (a) Per-Einheit-Profile (`profiles: [assistent|rapt|proxy|supabase]`) eingeführt hat → dann `docker compose --profile <einheit> up -d` nutzen, oder (b) beim Service-Namen-Mapping geblieben ist → dann §5.1-Tabelle nutzen. **Nicht raten** — am echten File festmachen. Ebenso: ob `DATABASE_URL`/`SUPABASE_INTERNAL_URL` bereits `.env`-parametrisiert sind (Phase 1) — Migration darf diese nicht hartkodiert überschreiben.
10. **V-10 — Cross-VPS-DB-Pfad bei verschobenem Proxy:** Wenn der Proxy auf einem anderen VPS als die DB landet, kommt seine DB-Verbindung über den `cloudflared access tcp`-Loopback (Phase 1). Das Menü konfiguriert das NICHT neu, sondern setzt voraus, dass die `.env` des Proxy-VPS den korrekten remote `DATABASE_URL` trägt. Falls eine Migration die DB auf einen anderen VPS legt als den Proxy: das Menü gibt einen **Hinweis** aus (analog `RAPT_DASHBOARD_URL`, §5.2.5), ändert die `.env` aber nicht selbst (`.env.gpg` re-encrypt = Credential-Schritt).

---

## 9. Braucht Freigabe / außerhalb cicd-coder-Standard-Scope

- **Compose-Schema-Änderungen** (neue `profiles:` pro Einheit, neue Netzwerke): gehören in **Phase 1** (`PHASE1_COMPOSE_TUNNEL_CICD.md`), NICHT in diese Phase-2-Spec. Phase 2 **nutzt** den Phase-1-Stand (Profile falls vorhanden, sonst Service-Namen, V-9), führt aber selbst **keine** Compose-Schema-Änderung durch. → Coder: skip-and-report, falls er für das Menü eine Compose-Änderung für nötig hält.
- **Supabase-Stack** bleibt versions-gepinnt, kein Watchtower-Label, nicht bumpen (Frozen).
- **`.env`-Änderung für `RAPT_DASHBOARD_URL`** nach RAPT-Umzug ⇒ `.env.gpg` re-encrypt ⇒ Brewing-Passphrase = **Credential-Schritt** (§10). Script gibt nur den Hinweis aus.
- **Keine neue apt-Dependency.** `ssh` ist Standard; alles andere wird schon installiert.

---

## 10. Credential-Schritte (User muss tun)

- **SSH-Key neu → alt:** Falls passwortloser SSH-Login vom neuen auf den alten VPS noch nicht eingerichtet ist, muss der User den Public-Key des neuen `alex` in `~alex/.ssh/authorized_keys` des alten VPS hinterlegen (oder per `ssh-copy-id`). Das Script prüft nur und bricht mit klarer Anweisung ab — es legt kein neues Key-Material an.
- **`.env.gpg` re-encrypt** nach evtl. `RAPT_DASHBOARD_URL`-Änderung: `./scripts/encrypt-env.sh` braucht die Brewing-GPG-Passphrase (aus Bitwarden `ALEXSTUDER_WEBPAGE_GPG_PASSWORD`) + anschließenden `git commit` der `.env.gpg`. Nur falls eine RAPT-Migration die URL ändert.
- **Bitwarden-Login / GPG-Passphrase** beim Erst-Bootstrap unverändert wie heute (nur falls `.env`/`gpg.pass` fehlen).

---

## 11. Launch-Instruktion für cicd-coder (copy-paste)

> Starte `cicd-coder` mit diesem Spec: `/Users/alex/Git/WebPageNew/webPage_infra/BOOTSTRAP_MENU_KONZEPT.md`
>
> **Voraussetzung:** Phase 1 (`PHASE1_COMPOSE_TUNNEL_CICD.md` + `PHASE1_DB_FUNDAMENT_DBA.md`) ist umgesetzt. Lies zuerst `MULTIVPS_ARCHITEKTUR.md` (4 Einheiten) und den **aktuellen** Stand der `docker-compose.yml` (V-9: Profile vs. Service-Namen, `.env`-parametrisierte URLs).
>
> Erweitere `webPage_infra/scripts/bootstrap.sh` um das beschriebene interaktive Menü (Komplett-Start / selektive Einheiten-Installation / SSH-orchestrierte VPS-Migration) inkl. idempotentem Wiedereinstieg. Halte dich an §4–§6. Führe KEINE Compose-Schema-Änderungen durch — nutze den Phase-1-Stand (Profile falls vorhanden, sonst `docker compose up -d <service>`); falls du eine Compose-Änderung für nötig hältst, skip-and-report (§9). Keine neuen Dependencies, kein Hardening, keine Health-Checks (§7). Verifiziere die offenen Punkte aus §8 (inkl. V-9/V-10) gegen die echten Scripts/Compose. `bash -n` + `shellcheck` auf das Ergebnis; nenne klar, was du ohne echten VPS NICHT testen konntest. Credential-Schritte (§10) am Ende an den User zurückgeben, nicht selbst lösen.
