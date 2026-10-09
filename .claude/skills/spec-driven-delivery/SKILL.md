---
name: spec-driven-delivery
description: >-
  Disciplined, spec-first engineering workflow for shipping production changes
  in any repository. Use this skill whenever the user asks you to implement a
  feature, fix a bug, refactor, or make any non-trivial code change — ESPECIALLY
  when they mention "SDD", "spec before coding", "apply the SDD rule", "commit
  and push at the end", a "premium/professional/elegant" UX bar, or
  internationalization (i18n / multi-language / default language). It enforces:
  write a docs/SDD_<NAME>.md spec first, then implement, validate the build,
  keep i18n catalogs at parity, update a per-repo CLAUDE.md memory, and commit +
  push with a Co-Authored-By trailer. Prefer this skill for substantive code
  tasks even when the user doesn't name it explicitly.
---

# Spec-Driven Delivery

A project-agnostic discipline for delivering changes that are correct,
documented, reviewable, and consistent — the way a senior engineer at a
high-bar SaaS company would work. It turns "just code it" into a repeatable
loop: **spec → implement → validate → record → ship**.

Apply it to any repo (frontend, backend, library, infra). Adapt the specific
commands to the stack you find; the *discipline* is what's constant.

## When to apply

Use this for any substantive change: a feature, a bug fix, a refactor, a
migration, a UX adjustment. Skip the full ceremony only for truly trivial,
zero-risk edits (a typo, a one-line copy tweak) — and even then, still validate
and commit cleanly.

## The loop

### 1. Understand before touching anything
Read the relevant code first. Find the real cause, not the symptom. Inspect how
existing, similar things are done in *this* repo and match those conventions
(component APIs, naming, error handling, file layout). Don't assume an API —
verify it in the source. If a decision genuinely belongs to the user (ambiguous
scope, product trade-off), ask; otherwise pick the sensible default and proceed.

### 2. Write the SDD spec FIRST
Before writing implementation code, create `docs/SDD_<SHORT_NAME>.md` (create
`docs/` if absent). This is the "rigorous SDD rule": the spec exists so the
change is intentional and reviewable, not so a template gets filled in. Keep it
tight and concrete. Structure:

```markdown
# SDD — <Title>

## Problem
What's wrong / what's needed (observable, specific).

## Root cause
Why it happens (for fixes) — the actual mechanism, not the surface.

## Goal
The outcome, in one or two sentences.

## Solution
Files to touch and the approach. Name components/functions/endpoints.
Call out reuse of existing patterns.

## Non-goals
What this deliberately does NOT do (prevents scope creep).

## Validation
How you'll prove it works (typecheck/build/tests/parity checks).
```

Write it, then re-read it with fresh eyes once before coding — most rework is
prevented here.

### 3. Implement
Follow the spec and the repo's existing patterns. Keep changes focused on the
stated scope; if you discover adjacent issues, note them rather than expanding
silently. Honor the **i18n discipline** (below) and the **quality bar** (below).

### 4. Validate (never skip)
Run the project's typecheck/build/test before committing. Find the right command
for the stack and run it from the correct directory — many toolchains fail when
invoked from the wrong path. Examples (adapt to what the repo uses):
- Next.js / TS frontend: `npx tsc --noEmit` (run from the app's own directory)
- NestJS / TS backend: `npx nest build`
- Generic: the repo's `build`, `typecheck`, `lint`, or `test` script
A green build is the gate. If it's red, fix the root cause — don't suppress.

### 5. Record memory
Keep a per-repo `CLAUDE.md` at the repo root as durable memory for future AI
sessions. Whenever a new convention, decision, or "don't regress this" emerges,
add it. The SDD docs in `docs/SDD_*.md` are the detailed history; `CLAUDE.md` is
the always-loaded summary of the rules. See `references/claude-md-template.md`.

### 6. Ship: commit and push
Commit with a clear, conventional message and push to the working branch (push
to `main` only when the user has authorized it — many of these workflows do).
**Always end commit messages and PR bodies with the Co-Authored-By trailer** the
user expects:

```
<concise summary line>

<why + what, a few lines; reference the SDD doc>

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

Then summarize for the user, in their language, what changed and how it was
validated.

## i18n discipline (when the project is multi-language)

If the repo has an i18n setup (e.g. next-intl, i18next, message catalogs), treat
it as a hard requirement, not an afterthought:

- **No hardcoded user-facing strings.** Every visible label, placeholder,
  tooltip, toast, alert, and aria-label goes through the translation function
  (`t('...')`), never a literal.
- **Catalog parity.** Add each new key to **all** locale files with the same
  namespace structure. A key present in one language but missing in another is a
  bug. Validate parity before committing (a tiny Node/script check over the JSON
  is efficient for many keys).
- **Respect the configured default locale.** If the product's default is
  Portuguese (pt-BR) — or whatever the config says — don't change it; just make
  sure every locale is complete and correct.
- Developer-only logs (`console.error`, internal exceptions) may stay in a fixed
  language; they're not UI.

When there is no i18n setup, don't invent one unless asked — but still avoid
scattering duplicated copy.

## Quality bar (premium SaaS UX)

When the work touches UI, hold a "high-tech, professional, elegant, light"
standard (the bar of a modern multinational SaaS): clear visual hierarchy,
consistent spacing, thoughtful empty/loading/error states, responsiveness, and
accessibility (labels, focus, keyboard). Reuse the design system / tokens
already in the repo rather than introducing one-off styles. Prefer fixing the
root layout cause over patching symptoms.

## Anti-patterns to avoid
- Coding before the SDD spec exists.
- Committing without running the build/typecheck.
- Hardcoded UI strings in an i18n project, or adding a key to only one locale.
- Expanding scope beyond the spec without saying so.
- Suppressing type/build errors instead of fixing them.
- Letting `CLAUDE.md` go stale after establishing a new rule.

## Reference files
- `references/claude-md-template.md` — starter template + guidance for the
  per-repo `CLAUDE.md` memory file. Read it when a repo has no `CLAUDE.md` yet
  or you need to extend one.
