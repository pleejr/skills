---
name: sort-imports
description: This skill should be used when sorting or reorganizing import statements in source files — ordering and grouping imports in Python, JS/TS, Go, Rust, Java/Kotlin, Swift or similar, cleaning up a messy import block, or fixing import-order lint failures. Finds and runs the project's own configured sorter (isort, ruff, eslint, prettier plugin, goimports, rustfmt) so the result matches CI, and hand-sorts only when none exists, without changing side-effect imports or behavior. Triggers: "sort the imports", "organize imports", "fix import order", "group my imports", "imports are a mess", "isort this", "import/order lint error", "alphabetize imports". Distinct from `safe-tfsort` (Terraform variable/output blocks) — this covers language import statements. NOT for removing unused imports as a goal in itself, renaming modules, or general code formatting.
version: 1.0.0
summary: Sorts and groups import statements using the project's configured tool, falling back to a conventions-based manual sort that preserves side-effect ordering.
---

# sort-imports

Sort imports the way the project already does. A hand sort that disagrees with the configured tool gets reverted by the formatter or fails CI, so detect the tool before touching anything.

## 1. Find the project's sorter

Check config in the repo root, in this order, and use the first hit:

| Language | Look for | Run |
|---|---|---|
| Python | `[tool.ruff]` with `I` in `select`, `[tool.isort]`, `.isort.cfg` | `ruff check --select I --fix <paths>` / `isort <paths>` |
| JS/TS | eslint `import/order` or `simple-import-sort`, `prettier-plugin-organize-imports`, Biome `organizeImports` | `eslint --fix <paths>` / `biome check --write <paths>` |
| Go | always | `goimports -w <paths>` (or `gofmt`; `gci` if configured) |
| Rust | `rustfmt.toml` | `cargo fmt` (`reorder_imports` is on by default) |
| Java/Kotlin | spotless, ktlint, IDE config | the configured gradle/maven task |
| Swift | `.swiftformat`, `.swiftlint.yml` | `swiftformat <paths>` |

Confirm the tool is installed (`command -v`, or the project's runner such as `npx`, `uv run`) before running. Run it on the files in scope only, not the whole repo, unless asked. Scope defaults to files the user named, else files changed in git (`git diff --name-only`).

## 2. No tool configured: sort by hand

State that no sorter was found, then apply the language's conventional grouping, separated by one blank line:

1. Standard library / built-ins
2. Third-party packages
3. First-party / local (absolute project imports, then relative)

Within a group, sort alphabetically by module path, case-insensitive. Keep `import x` and `from x import y` ordering consistent with what the file already does; match the surrounding file over this table when they conflict. Sort the names inside a single `from x import (a, b, c)` too.

## 3. Preserve behavior

Reordering is only safe when imports are order-independent. Leave in place, and do not sort across:

- Side-effect imports (`import "./polyfills"`, `import 'reflect-metadata'`, Python `import matplotlib; matplotlib.use(...)` patterns) — order can matter.
- Imports guarded by `if TYPE_CHECKING:`, `try/except ImportError`, or conditional blocks. Sort within the block, never move imports in or out.
- Imports after executable code (e.g. `sys.path` edits before imports). Sort each contiguous run separately.
- Comments attached to an import (`# noqa`, `// eslint-disable-line`, `# type: ignore`) — they move with their line.
- Language-mandated positions: Go `import "C"`, Python `from __future__` first, Java `package` line, JS `"use strict"`/shebang.

Do not add, remove, or rewrite imports. Unused ones stay unless the user asked to remove them.

## 4. Verify

Run the project's check mode (`ruff check --select I`, `isort --check`, `eslint`, `cargo fmt --check`) and confirm it is clean. Then `git diff --stat`: the diff should contain only import-block changes. If other lines changed, the tool ran a broader fix than intended; revert those hunks. Report the tool used, files touched, and the check result in a line or two.
