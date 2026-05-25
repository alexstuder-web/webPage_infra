# webPage_infra — Claude-Instruktionen (repo-scoped, versioniert)

Der **projektweite** Kontext (alle 5 Repos, Secrets-Pattern, Deployment-Workflow,
Arbeitsweise-Regeln) liegt in der übergeordneten `../CLAUDE.md`. Diese Datei hier ist
die **versionierte, repo-eigene** Ergänzung — Claude Code lädt sie automatisch, sobald
das Arbeitsverzeichnis `webPage_infra` (oder ein Unterordner) ist. Sie ist damit die
**Source of Truth** für die unten stehende Regel; die parent `../CLAUDE.md` verweist nur
hierher (sie ist nicht versioniert).

## Code-Review-Loop (Coder ↔ Reviewer) — vom Orchestrator getrieben

Jeder Coder-Agent wird im Loop mit seinem Reviewer betrieben, bis keine
Critical/Important-Befunde mehr offen sind. **Der Coder kann seinen Reviewer NICHT selbst
starten** (kein `Agent`-Tool, und Sub-Agenten dürfen in Claude Code keine Sub-Agenten
spawnen) — der **Orchestrator** (die Haupt-Session, die den Coder dispatcht) treibt den Loop:

1. Coder implementiert + self-testet, endet mit `Review-Handoff: REVIEW REQUIRED → <reviewer>`
   (bzw. dem `## Review handoff`-Block bei flutter-coder / web-designer).
2. Orchestrator startet den passenden Reviewer auf den Änderungen.
3. Reviewer liefert Befunde + eine `Review-Gate: PASS | CHANGES-REQUIRED`-Zeile.
4. Bei `CHANGES-REQUIRED`: Critical + Important als Arbeitsauftrag zurück an den Coder
   → fixen → zurück zu Schritt 1. Suggestions sind optional.
5. Loop endet bei `Review-Gate: PASS` (null Critical, null Important offen).

**Schleifen-Schutz:** Überlebt derselbe Critical/Important 3 Iterationen (Coder kommt nicht
weiter, oder Coder ↔ Reviewer sind echt uneins), Loop abbrechen und den offenen Befund dem
User vorlegen — nicht endlos drehen.

**Paare:** `cicd`, `dba`, `flutter`, `proxy`, `web-designer` (Coder ↔ `*-reviewer`; bei
web-designer: `web-designer` ↔ `web-designer-reviewer`). `flutter-tester` ist KEIN Reviewer
und nicht Teil dieses Gates.

Die vollständigen Loop-Pflichten stehen redundant in jeder Agent-Definition selbst
(`.claude/agents/*-coder.md` → Abschnitt „Review-Loop"; `.claude/agents/*-reviewer.md` →
Abschnitt „Review-Gate"), damit ein Agent seine Rolle auch ohne diese Datei kennt.
