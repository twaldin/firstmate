# PR Lifecycle Ledger

`bin/fm-pr-ledger.sh` owns the canonical generated PR lifecycle ledger.
The durable path is `data/pr-ledger.json` unless `FM_PR_LEDGER_PATH` or `--write <path>` selects another path.
The ledger is generated state and must not be hand edited.
Dashboard or review surfaces may render this file, but they are not a second source of truth.

## Refresh Contract

Run `bin/fm-pr-ledger.sh` to atomically refresh the durable JSON file.
Run `bin/fm-pr-ledger.sh --json` to print the same object without writing it.
The reducer scans `state/<id>.meta` for recorded `pr=` URLs, keeps one owner row per PR URL, and refreshes live PR data through `gh-axi pr view`.
If more than one task meta records the same PR URL, the first task id in sorted meta-file order owns the ledger row for that PR.
This deterministic tie-break keeps exactly one owner without adding a hand-maintained ownership file.

## Schema

The top-level schema id is `fm-pr-ledger.v1`.
`generated_at` is the UTC refresh time.
`fm_home` and `state_path` record the operational home and state directory that were scanned.
`stages` lists the complete stage enum accepted by the reducer.
`records` contains one object per PR URL.

Each record has `pr_url`, `repo`, `number`, `owner`, `stage`, `title`, `status_line`, and `live`.
`owner.task_id` is the one firstmate task that owns the PR or ticket stack.
`owner.meta_path` and `owner.status_path` point to the local files used for that owner.
`live.available` records whether the `gh-axi pr view` refresh succeeded.
`live.state`, `live.merged`, `live.draft`, `live.checks`, and `live.approved_review` are parsed from the live view output.

## Stages

The only valid stages are `build`, `review`, `waiting-named-human`, `approved-awaiting-Tim`, `MQ`, `deploy`, `fallout`, `retro`, `Done`, and `Closed`.
`Done` and `Closed` are derived from live PR state before any local status hint.
`deploy`, `fallout`, `retro`, and `MQ` are derived from the owner's latest status line when the PR is still open.
`approved-awaiting-Tim` is derived from an approved live review on an open non-draft PR.
`waiting-named-human` is derived from owner status that explicitly says a named human, Tim, or reviewer is being waited on.
`build` is used for draft PRs or live checks that are still pending, queued, or failing.
`review` is the default open-PR stage after the previous derivations do not match.
