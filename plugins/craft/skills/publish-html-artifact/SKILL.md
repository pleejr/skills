---
name: publish-html-artifact
description: This skill should be used whenever a document, plan, runbook, report, write-up, tracker or any other readable page is to be published as a claude.ai Artifact — build it as a plain HTML page from the house template, never as a Claude Docs (Docs viewer) document. Produces one-column HTML where prose, tables and figures share a single width, and for a runbook adds phased step tables whose Status column lives in the page's shared db so the text never goes stale. Triggers: "make an artifact", "publish this as a page", "write up the plan", "make a runbook", "turn this into a doc", "put this in an artifact", "share this as a page", "rewrite the plan doc", "make a tracker for this", "fix the layout of the artifact", "make the tables the same width". Distinct from the built-in `docs` skill and the Docs Artifact type (Claude Docs viewer, fixed text column, content-sized tables) — this replaces them for every document, by the user's standing instruction. Distinct from `artifact-design` (generic page design guidance, which this applies through its template) and from `confluence-page` (a page on Confluence, not claude.ai). NOT for slides, a canvas design or a dashboard of live metrics — use those Artifact types; NOT for a .docx/.pdf file the user asks for by format.
version: 1.0.0
summary: Publishes documents, plans, runbooks and reports as plain HTML Artifacts from one adjustable house template — never the Claude Docs viewer — with a db-backed Status column so runbooks never go stale.
---

# publish-html-artifact — documents as HTML pages, never the Docs viewer

Every document that becomes a claude.ai Artifact is a plain HTML page built from `assets/template.html`. The Claude Docs viewer is not used: it fixes the text column and sizes each table to its content, so widths cannot be made consistent, and its layout cannot be adjusted. This is the user's standing instruction; it outranks the Artifact tool's preference for the Docs type and the `docs` skill's "default for any document".

## 1. Before writing

1. Run `Artifact(action: "quickstart", intent: "other", design_systems: false)` once per new page. It carries the page contract (skeleton, CSP, theme, size). Ignore the Docs type it lists; take the plain-page path.
2. A runbook keeps shared state, so load `artifact-capabilities` before writing it (the tool requires this for any `capabilities`). A static page does not need it.
3. Decide the shape:
   - **Runbook** — work to be followed to completion (a migration, a rollout, a cutover). Phased steps, owners, checks, live status. §3.
   - **Static page** — a plan, report, decision record or explainer that is read, not worked. Same template minus the runbook blocks.

## 2. Build from the template

Copy `assets/template.html` to the scratchpad (one folder per page, `index.html`), then fill it. Keep the template's structure and tokens: that is what makes every page share one layout, and what lets the layout be changed in one place.

- **One width.** Everything — paragraphs, lists, tables, figures — spans `--w`. Tables use `width: 100%` and `table-layout: fixed`, with `<colgroup>` classes (`c-num`, `c-owner`, `c-status`, `c-date`) for the narrow columns, so every table on the page lines up.
- **Layout changes go to the tokens**, not per element: `--w`, `--gap-section`, `--gap-block`, `--radius`, the fonts and the palette. When the user asks for a layout change (wider, tighter, different spacing), change the token in this page and, if it should hold for future pages, in `assets/template.html` too.
- **Placeholders** are `{{…}}`. Replace every one; a page that ships with a `{{` is unfinished (`grep -c '{{' index.html` must be 0).
- **Figures** are inline SVG drawn with the tokens (`var(--fg)`, `var(--muted)`, `var(--accent)`), inside `.figure`. Words in the drawing are only facts stated elsewhere on the page.
- **Header:** the lead states the goal in one or two plain sentences, with no links and no current state. Tickets go in the `.refs` list beneath it, one row each: the key as a link, then what that ticket covers in a few words. Never thread ticket links through the lead's prose.
- **Self-explanatory tables.** Column headers, plain actions, and checks that name their value carry the page; when a step is unclear, simplify the table.
- **Voice:** briefing register — sections open with their point, specifics over adjectives. No status prose (below).
- **Title:** `<title>` is the page's name, two to four words; the explanation goes in the publish `description`.

## 3. Runbooks: written to be followed, never to go stale

A runbook's text says what to do and how to know it is done; it never says how far along the work is. Every sentence that narrates progress ("the stack is built", "waiting on X", "as of today") is wrong the moment work moves, which is why such pages rot.

- **Steps live in `#runbook-data`** (JSON in the page): phases, each with `id`, `title`, `note`, and steps as `[number, action, owner, check]`.
  - **Action** — an imperative ("Raise the service to desired 1").
  - **Owner** — a person's first name or role, plain text.
  - **Check** — an observable value read from the running system ("the service runs 1/1 and `/health/ready` returns 200"), never "merged" or "applied".
  - The last step of a phase that ends a ticket is "Close <ticket>", checked by every row above it reading Done.
- **Status lives only in the db**, collection `steps`, document id `s<phase>-<n>` (`1.10` → `s1-10`), body `{status, updatedAt}`, status one of `not_started`, `in_progress`, `blocked`, `done`. No document means **not set** (dashed): blank is unknown, not "not started". The progress bar and per-phase counts are computed from it — never write a count into the text.
- **Publish with** `capabilities: {db: {rules: [{path: "steps", read: "view", write: "admin"}]}, user: {}}` so viewers read status and editors change it.
- **Seed after the first publish** with one `ArtifactData` `batch` of `set` writes: only statuses verified from the running system, or the user's own; leave others unset. A later status change is an `ArtifactData` write (pinned with `if_version`), never a republish.
- **Verify once:** `ArtifactData list` of `steps` at `as_level: "interact"` (reads succeed), and one `set` at `as_level: "interact"` (must be refused). Report both in one line.
- **Below the phases** only stable material: the design figure and a Decisions table (`Decision · By · Date`). A new decision is a new row.

## 4. Publish and hand over

- Publish with `icon` (one generic word, first publish only) and a one-sentence `description`.
- Rewriting a page published earlier: republish the same file path, or pass its `url` after a `read`. A page that started life as a Docs doc cannot become HTML at the same link: publish a new page, then replace the doc's content with one line pointing to it.
- A page with `db` is organization-internal and private until shared: tell the user who needs it shared, and with what access (edit, to set statuses).
- Say plainly what was not checked (the page was not viewed in a browser, unless it was).

## 5. Checklist

- [ ] Built from `assets/template.html`; no `{{` left.
- [ ] Lead is the goal alone, no links; tickets sit in the `.refs` list.
- [ ] Every table full width with `<colgroup>`; no element narrower or wider than `--w`.
- [ ] No status prose, counts or "as of" lines in the text.
- [ ] Runbook: checks are observable values; db rules declared; seeded statuses verified; rules verified at `interact`.
- [ ] Never the Docs type, the `docs` skill, or the Claude Docs connector.
