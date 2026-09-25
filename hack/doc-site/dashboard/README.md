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
# Optional: a security-read token for the alert/advisory columns (see Tokens).
export SECURITY_TOKEN=<security-read>
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
`future/maybe` labels); total contributors (REST Link-header count); the
`lint` job's conclusion in the latest CI run (Actions runs+jobs API); and the
**security metrics** below.

**Fork-aware totals.** For a repo that is a fork of an upstream parent
(`testify`, our testify/v2 fork of `stretchr/testify`), GitHub reports the whole
fork network for **Total commits** and **Total contributors** (testify carries
stretchr's lineage — ~1483 commits / 258 contributors). The generator instead
counts only the fork's **own** work since the fork point via the cross-fork
compare API (`parent_default...fork_default` → commits unique to the fork — ~227
/ 7 for testify), overriding `totalCommits` and the contributor list (so the
per-org / overall *distinct* totals are no longer inflated either). Time-windowed
metrics (MTD/YTD, commits-since-release) need no adjustment — the fork's history
holds only shared ancestry (dated before the fork point) plus our own commits,
so the `since=` filters already exclude upstream.

**Security metrics** (Github tab — needs `SECURITY_TOKEN`, see below):
- `securityAlerts` — combined count of *open* alerts across code scanning,
  Dependabot and secret scanning. `securityAlertsUnknown` lists any flavor whose
  API could not be read (so the page can flag it with `⚠️` rather than report a
  false `0`). A flavor that is simply *disabled* on the repo counts as `0`.
- `securityReports` / `securityReportsUnknown` — count of open (triage / draft)
  repository security advisories, and whether the advisories API was unreadable.

## Tokens

The bulk of the collection runs under `GH_TOKEN` and reads only **public** data,
so the default Actions token (or any read token) suffices.

Security alerts and advisories are **not public**, and the dashboard reads them
*across* the go-openapi / go-swagger repos. Those four calls therefore use a
separate **`SECURITY_TOKEN`** (falls back to `GH_TOKEN`):

```sh
export GH_TOKEN=<public-read>
export SECURITY_TOKEN=<security-read>   # see scopes below
./collect-dashboard.sh
```

`SECURITY_TOKEN` must be able to read, across both orgs:
*code scanning alerts*, *Dependabot alerts*, *secret scanning alerts* and
*repository security advisories*. In CI this is a **go-openapi-bot GitHub App
installation token** (minted via the shared `go-openapi/gh-actions` action) — the
App must be **installed on both orgs** with those four read permissions. For a
local run, a classic PAT with `repo` + `security_events` works too. If the token
lacks a scope, the affected cells degrade to `⚠️` (unreadable) instead of `0`.

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
`dashboard.json` to the Hugo build via an artifact. It needs `contents: read`
plus a `SECURITY_TOKEN` (the go-openapi-bot App installation token — see
**Tokens**) for the security columns.

## Security page (`collect-security.sh`)

A sibling script collects `../hugo/data/security.json`, consumed by the
`advisories` shortcode to render the
[security advisories page](../../../docs/doc-site/security/_index.md). It takes
the same options (`-o`, `-x`, `-i`), plus `-c` and `-f` (see **Cache**), and the same per-org tokens as the
dashboard. It uses them for **all** its calls, not just the security reads:
the fix-release lookups add a few hundred API calls.

Per public, non-archived repo:

- **Repository security advisories.** Every *published* advisory, with its
  title, reporters (`credits_detailed` of type `reporter`, else the author of a
  privately reported advisory), severity and patched versions. Advisories in
  *triage* or *draft* are only counted. *Closed* advisories are skipped.
- **Code scanning alerts**, from every tool except Scorecard (`EXCLUDED_TOOLS`).
  Scorecard reports best-practice compliance, not releasable fixes.
- **Dependabot alerts.**

Fixed alerts are listed with the release that shipped the fix:

- **Code scanning:** the alert's default-branch instances in state `fixed` carry
  the commit of the analysis that first saw the alert gone. The fix release is
  the first release whose tag contains that commit (compare API). If several
  analysis categories were fixed by different commits, the latest release wins.
- **Dependabot:** alerts carry no commit, so the fix release is *inferred* as
  the first release published after `fixed_at`. The page marks it `≈`.

Monorepos: an advisory's fixed version is the `patched_versions` typed in the
advisory, per package. An alert's fix release is the GitHub release on the root
tag (`v0.27.1`): nested module tags (`yamlutils/v0.27.1`) point at the same
commit, since modules are released in lockstep.

The page lists, per repo, advisories under analysis (one count per state:
`triage`, `draft`), then published advisories and fixed alerts in one list
(`details`): newest release first, advisories before alerts within a release.
An advisory sorts by the release of its patched version, else by its
publication date. The summary table carries per-org subtotals and a grand total.

Dismissed alerts are counted by reason. Open alerts are counted by severity and
never detailed. On the page, alert ids link to their public reference (NVD,
pkg.go.dev/vuln, GitHub advisories, CodeQL query help), because alert pages are
only visible to maintainers.

### Cache

Resolving fix releases costs about 2 API calls per fixed code scanning alert:
a full run takes ~10 minutes. A resolved release never changes, so the output
records each one per repo (`alertReleases`: alert number → `fixedAt`, `release`,
`inferred`) and the next run reuses them from the previous output:

- `-c FILE` reads the cache from `FILE` (default: the output file itself, so a
  local re-run is warm).
- `-f` ignores the cache (full refresh, e.g. after fixing a release).

An entry is reused while the alert's `fixed_at` is unchanged (a reopened, then
re-fixed alert is looked up again) and its release still exists. Fixed alerts
not yet released are never cached. A warm run takes seconds.

In CI, the `collect-dashboard` job runs both scripts and ships both files in
the `dashboard-data` artifact. The security step is non-fatal on its own.
`actions/cache` carries `security.json` from one run to the next (key
`security-data-<run id>`, restored by the `security-data-` prefix). Pull
requests read it but don't save it. The first run, or any run after the cache
is evicted (7 days unused), is a full ~10 minute run. If the collection fails,
the restored file from the previous run ships instead.
