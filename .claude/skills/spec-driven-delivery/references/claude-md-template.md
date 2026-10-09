# CLAUDE.md template & guidance (per-repo memory)

`CLAUDE.md` lives at the **root of each repository** and is durable memory for
any AI session working there. It loads automatically, so keep it the concise
"rules of the house" — the detailed reasoning stays in `docs/SDD_*.md`.

Update it whenever a new convention, architectural decision, or "don't regress
this" lesson emerges. In a multi-repo product (e.g. separate frontend/backend),
give **each** repo its own `CLAUDE.md` and have them reference each other.

## Starter template

```markdown
# CLAUDE.md — <repo name> (<role: frontend / backend / lib>)

Permanent instructions for any AI assistant in this repo. Read before any task.
(Companion file: <other-repo>/CLAUDE.md.)

## 0. Non-negotiable rules (every task)
1. **SDD spec BEFORE coding** — write `docs/SDD_<NAME>.md` (problem, root cause,
   goal, solution, non-goals, validation), then implement.
2. **Validate before commit** — run `<the build/typecheck/test command>` (from
   `<the correct directory>`); must be green.
3. **Commit + push at the end.** Push to `main` is <authorized / not authorized>.
4. Commit messages end with:
   `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
5. **i18n always** (if applicable) — no hardcoded UI strings; keep all locale
   catalogs at parity; default locale is `<e.g. pt-BR>`.
6. Keep this `CLAUDE.md` and `docs/SDD_*.md` updated.
7. Reply to the user in `<language, e.g. pt-BR>`.

## 1. Quality / brand bar
<e.g. premium SaaS B2B: professional, elegant, light, rigorous UX/UI.>

## 2. Stack & architecture
<frameworks, key libs, routing, repo URL, deploy target.>

## 3. Consolidated decisions (do NOT regress)
<bullet the hard-won choices: integrations, data flows, patterns.>

## 4. Component / code patterns (gotchas learned)
<e.g. Dialog uses open/onOpenChange; Input has no `icon` prop; portal for
floating menus; idempotent migrations; etc.>

## 5. Security & limits
<authz rules, multi-tenant scoping, secrets handling.>

## 6. Where to look
<key directories and the SDD docs index.>
```

## Tips
- Keep it scannable — short bullets beat prose.
- Record *why*, not just *what*, for decisions that future sessions might undo.
- When you finish a task that established a rule, add it here in the same commit.
