---
name: sort-imports
description: This skill should be used when imports need ordering or grouping in source files — a new file, a messy diff, a lint failure about import order, or a request to tidy imports across a file, directory or changeset. Detects the language and the project's own import tool and config (ruff/isort, eslint/prettier/biome, goimports/gci, rustfmt, google-java-format, etc.), runs that, and verifies nothing but import order changed. Triggers: "sort imports", "organize imports", "fix import order", "group the imports", "isort this", "imports are a mess", "lint says imports unsorted". Distinct from `safe-tfsort` (Terraform variable/output blocks, not language imports) and `simplify` (removes unused code, does not reorder). NOT for removing unused imports alone, renaming modules, or reformatting whole files.
version: 1.0.0
summary: Sort and group imports using the project's own configured tool (never a hand-written ordering), scoped to the requested files, then verify the diff touched only import lines and the build still resolves.
---

# sort-imports

Order imports the way the project already orders them. The project's tool and config define "sorted"; a hand-picked order fights the linter and churns diffs.

## 1. Find the project's convention

Look for config before choosing a tool, in this order:

| Language | Config / tool signals | Run |
|---|---|---|
| Python | `[tool.ruff]` with `I` rules, `[tool.isort]`, `.isort.cfg`, `setup.cfg` | `ruff check --select I --fix <paths>` or `isort <paths>` |
| JS/TS | `biome.json` (organizeImports), eslint `import/order` or `simple-import-sort`, prettier plugin | `biome check --write`, or `eslint --fix --rule`-scoped to the import rule, or `prettier --write` |
| Go | always `goimports`; `gci`/`.golangci.yml` if present | `goimports -w <paths>` or `gci write <paths>` |
| Rust | `rustfmt.toml` (`group_imports`, `imports_granularity`) | `cargo fmt` (scope with `rustfmt <files>`) |
| Java/Kotlin | spotless, google-java-format, ktlint, `.editorconfig` | the build's formatter task |
| Other | `.editorconfig`, a pre-commit hook, a Makefile `fmt` target | whatever the repo already runs |

If a pre-commit config or CI lint step names the tool, that tool wins over anything above. Match the version the repo pins (`uv run`, `npx`, `go run`) rather than a global binary, because versions differ in grouping rules.

If no config exists, say so and use the language's community default (stdlib, third-party, local; alphabetical within a group; one blank line between groups) rather than inventing a scheme. Mention that no project convention was found.

## 2. Scope the run

Default to the files the user named, or the files in the current diff (`git diff --name-only`, plus untracked). Do not run repo-wide unless asked: a repo that was never sorted turns into a thousand-file diff that buries the change. If the tool can only run repo-wide, confirm first.

## 3. Run and verify

1. Run the tool on the scoped paths.
2. Inspect `git diff` for the touched files. Every changed hunk should be an import line or the blank lines between them. A hunk elsewhere means the tool also reformatted code; revert that file and rerun with the import rule only.
3. Check that order-sensitive imports survived. Side-effect imports (`import "./polyfill"`, `import _ "pkg"`, Python `sys.path` edits before an import, `# isort: skip`, `// eslint-disable` markers) can break if moved; confirm they are still honored by the tool.
4. Run the project's quick check (type check, `go build`, `cargo check`, import lint) if one exists, because a reorder can expose a circular import that happened to work before.

## 4. Report

State the tool and config used, the files touched, and whether the diff was imports-only. If the tool reordered something unexpected or no convention existed, say so; otherwise stay short.

## Hand sorting (last resort)

Only when no tool is installable. Keep the groups, preserve comments attached to an import (they move with it), keep side-effect imports in place, and sort case-insensitively unless the language's convention differs. Say the result is unverified by a tool.
