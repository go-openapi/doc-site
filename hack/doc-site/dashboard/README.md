# Dashboard data generator

Collects public-repo metadata across the **go-openapi** and **go-swagger** orgs
into `../hugo/data/dashboard.json`, consumed by the `dashboard` Hugo shortcode
to render the [dashboard page](../../../docs/doc-site/dashboard/_index.md).

This is pure mechanical aggregation — GitHub GraphQL → `jq`, no LLM involved.
See [`.claude/plans/repo-dashboard.md`](../../../.claude/plans/repo-dashboard.md)
for the full design.

## Run locally

```sh
# Needs a token with public read scope (or an authenticated `gh`).
export GH_TOKEN=<read-token>
./collect-dashboard.sh
```

Options:

- `-o OUTPUT` — write somewhere other than `../hugo/data/dashboard.json`.
- `-x EXCLUDE` — skip a repo by name (repeatable; `.github` is always skipped).
- `-i FORK_INCLUDE` — keep a fork that the fork filter would drop (repeatable;
  `testify`, the testify/v2 fork, is kept by default).

With a Hugo dev server running (`go run ../hugo/gendoc.go`), re-running the
script refreshes the dashboard live.

## What it collects

**Discovery** (one paginated GraphQL query per org): metadata, latest GitHub
release, open PR/issue counts, total commits, last-commit date, stars/forks,
topics, license. Forks and the excludes are dropped; **archived repos are kept**
(enrichment is skipped for them) so the Github tab can list them separately.

**Enrichment** (per repo, each step non-fatal): commits-since-release; commit
windows MTD/YTD with and without bot authors (REST `commits?since=` start of
year); releases YTD; deferred-issue count (GraphQL `search` for `v2` /
`future/maybe` labels); total contributors (REST Link-header count); and the
`lint` job's conclusion in the latest CI run (Actions runs+jobs API).

Per-repo **workflow filenames** (CI / cut-release / CodeQL) come from the
`WF_DEFAULTS` / `WF_OVERRIDES` table near the top of the script — edit it when a
repo diverges from the conventional names.

Badge URLs are **not** collected — the Hugo partials template them from
`org`/`name`. Phase 2 (plan §4.5): a Go tab, branch-protection / required-checks
on the Github tab, and Security/Shipping tabs.

## Output

The data file is **ephemeral and gitignored** (`hugo/.gitignore`) — regenerated
on every CI run; this script is the source of truth. Schema: plan §4.3.

## In CI

The `collect-dashboard` job in `update-doc.yml` runs this (non-fatal) and hands
`dashboard.json` to the Hugo build via an artifact. Requires `contents: read`.
