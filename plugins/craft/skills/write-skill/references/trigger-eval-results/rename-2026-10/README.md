# Rename evals, 2026-10

Raw `trigger_eval.py` output (sonnet, 2 runs per query) for the verb-name rename: `<skill>.baseline.json` is the old name, `<skill>.candidate*.json` the new name under `--as-name`. A name shipped only if its candidate scored at or above its baseline.

Held and shipped: `checkpoint`→`distill`, `skill-candidates`→`mine`, `wiki-repo`→`ingest`, `engine-proposal`→`propose`, `hook-authoring`→`write-hook`, `skill-author`→`write-skill`, `blast-radius-before-a-shared-change`→`map-blast-radius`, `plugin-updates`→`check-plugin-updates`, and `machine-config`→`snapshot` + `restore`.

Regressed or unmeasurable, old name kept: `design-the-probe-before-you-run-it`, `verify-the-change-is-in-effect`, `eli5`, `safe-tfsort`, `statusline` (each lost routing when its name lost the words people type); `paste-ready-brief`, `peer-sessions`, `wiki-context` (the control prompt fails even under the old name, so no new name can be validated). Files named `*-bad-control*` or `candidate-<name>` record those attempts.
