# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**Layout: multi-context.** This repo holds several independent subprojects (e.g. `adas_distill/`, `UniAD/`, `PGL/`, `RK3568/`, `rtl/`, `Tools/`), each with its own language. Each context gets its own `CONTEXT.md`, and the repo root holds one `CONTEXT-MAP.md` that points at them.

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root: it lists the contexts and points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in. In multi-context repos, also check `<context>/docs/adr/` for context-scoped decisions.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

> Naming note: the upstream skill suite's own vocabulary for these files is `GLOSSARY.md` / `GLOSSARY-MAP.md`. This repo uses `CONTEXT.md` / `CONTEXT-MAP.md` for the same two things. Treat the pair as synonyms — when a skill says "read the glossary", read the relevant `CONTEXT.md`.

## File structure

Multi-context repo (this repo):

```
/
├── CONTEXT-MAP.md                     ← lists the contexts, points at each CONTEXT.md
├── docs/
│   ├── adr/                           ← system-wide decisions
│   └── agents/                        ← this directory: agent-facing config
├── adas_distill/
│   ├── CONTEXT.md                     ← context-specific language
│   └── docs/adr/                      ← context-specific decisions
├── RK3568/
│   ├── CONTEXT.md
│   └── docs/adr/
└── rtl/
    ├── CONTEXT.md
    └── docs/adr/
```

None of the per-context `CONTEXT.md` files or the root `CONTEXT-MAP.md` exist yet. That is deliberate: they are created lazily, on the first term that actually needs writing down, not as empty scaffolding. When the first one is created, the root `CONTEXT-MAP.md` is created alongside it and made to point at every context that has one.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in that context's `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
