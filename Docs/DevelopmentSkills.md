# Development Skills

These optional Codex skills support SnipSnipSnip development. They are developer
tools and are not bundled with either edition of the app.

## Repository Skill

The project-owned [SSS Validation skill](../.agents/skills/sss-validation/SKILL.md)
is checked in under `.agents/skills/sss-validation`. It covers repository guards,
serial app-hosted XCTest, single-instance safeguards, edition boundaries, and
documentation requirements. Use `$sss-validation` to request validation explicitly.
The current [AGENTS.md](../AGENTS.md) and repository tooling remain authoritative.

## Upstream Skills

The following revisions match the skills installed when this setup was added:

| Skill | Source | Pinned revision |
| --- | --- | --- |
| Swift Concurrency | [AvdLee/Swift-Concurrency-Agent-Skill](https://github.com/AvdLee/Swift-Concurrency-Agent-Skill) | `d5770817d2622e1585b1f7eaebc791a9cb0959c8` |
| SwiftUI Expert | [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) | `204dba7c67256a8b707ee3fbc5759a824191974f` |
| GitHub CI troubleshooting | [openai/skills](https://github.com/openai/skills) | `49f948faa9258a0c61caceaf225e179651397431` |

Install them using Codex's bundled skill-installer and Python 3. These commands
download the pinned sources into your personal Codex skills directory, using
`CODEX_HOME` when set or `~/.codex` otherwise:

```sh
python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-installer/scripts/install-skill-from-github.py" \
  --repo AvdLee/Swift-Concurrency-Agent-Skill \
  --ref d5770817d2622e1585b1f7eaebc791a9cb0959c8 \
  --path skills/swift-concurrency

python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-installer/scripts/install-skill-from-github.py" \
  --repo AvdLee/SwiftUI-Agent-Skill \
  --ref 204dba7c67256a8b707ee3fbc5759a824191974f \
  --path skills/swiftui-expert-skill

python3 "${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-installer/scripts/install-skill-from-github.py" \
  --repo openai/skills \
  --ref 49f948faa9258a0c61caceaf225e179651397431 \
  --path skills/.curated/gh-fix-ci
```

The installer refuses to overwrite an existing skill. If already installed,
inspect that version before deciding whether to replace it. Updated revisions
should be reviewed and recorded here so another developer can reproduce them.
Keep downloaded dependencies in the personal skills directory outside Git.

Swift Concurrency supports isolation, cancellation, and background-work reviews.
SwiftUI Expert supports UI state, composition, layout, and performance; apply it
alongside the project's Design Language and Workflow Lexicon. GitHub CI
troubleshooting uses the authenticated `gh` CLI to inspect GitHub Actions logs
and guide fixes. The upstream CI skill includes an explicit approval step before
implementing its proposed fix plan.
