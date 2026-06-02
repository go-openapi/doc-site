#!/usr/bin/env bash
#
# collect-dashboard.sh — collect the repository status dashboard data.
#
# Aggregates public-repo metadata across the go-openapi and go-swagger orgs into
# a single Hugo data file (hack/doc-site/hugo/data/dashboard.json) consumed by
# the `dashboard` shortcode. Pure mechanical aggregation: GitHub API -> jq.
#
# See .claude/plans/repo-dashboard.md (§4.2, §4.3) for the design.
#
# Two phases:
#   1. Discovery — one paginated GraphQL query per org for the repo list + cheap
#      metadata (release, open counts, total commits, last commit, stars, ...).
#   2. Enrichment — per repo: commits-since-release, commit windows (MTD/YTD,
#      with/without bots), releases YTD, contributors, deferred-issue count and
#      lint job status. Each enrichment is non-fatal: failures fall back to a
#      neutral default so one flaky repo never aborts the run.
#
# Usage:
#   GH_TOKEN=<read-token> ./collect-dashboard.sh [-o OUTPUT] [-x EXCLUDE]...
#
# Requires: gh (authenticated, or GH_TOKEN set), jq.
# The data file is ephemeral and gitignored; this script is the source of truth.

set -euo pipefail

# --- configuration -----------------------------------------------------------

# Orgs to aggregate, in display order (drives per-org grouping).
ORGS=(go-openapi go-swagger)

# Repos to skip regardless of org (special/meta repos). Repeatable via -x.
EXCLUDES=(.github)

# GitHub forks are dropped by default (the fork filter avoids surfacing random
# personal forks). These forks are first-party projects we keep anyway — e.g.
# testify is the maintained go-openapi testify/v2 fork. Repeatable via -i.
FORK_INCLUDES=(testify)

# Workflow filenames behind the CI / cut-release / CodeQL badges. Most repos
# follow the conventional names (defaults); a few diverge (overrides). A `null`
# means "not applicable" — the template renders N/A instead of a broken badge.
WF_DEFAULTS='{"ci":"go-test.yml","release":"bump-release.yml","codeql":"codeql.yml"}'
WF_OVERRIDES='{
  "ci-workflows":         {"ci":"local-go-test.yml","release":"local-bump-release.yml","codeql":"local-codeql.yml"},
  "gh-actions":           {"ci":"test.yml"},
  "doc-site":             {"ci":"update-doc.yml","release":null},
  "go-swagger":           {"ci":"test.yaml"},
  "dockerctl":            {"ci":null,"release":null},
  "homebrew-go-swagger":  {"ci":null,"release":null},
  "scan-repo-boundary":   {"ci":null,"release":null},
  "go-swagger.github.io": {"ci":null,"release":null}
}'

# Issue labels that mark a backlog item as deferred (not part of the actionable
# open-issue count). Matched with GitHub search OR semantics.
DEFERRED_LABELS='v2,"future/maybe"'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/../hugo/data/dashboard.json"

while getopts ":o:x:i:" opt; do
  case "${opt}" in
    o) OUTPUT="${OPTARG}" ;;
    x) EXCLUDES+=("${OPTARG}") ;;
    i) FORK_INCLUDES+=("${OPTARG}") ;;
    *) echo "usage: $0 [-o OUTPUT] [-x EXCLUDE]... [-i FORK_INCLUDE]..." >&2; exit 2 ;;
  esac
done

# --- preflight ---------------------------------------------------------------

for tool in gh jq; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "::error::${tool} is required but not installed" >&2; exit 1; }
done
if [ -z "${GH_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
  echo "::error::no GitHub credentials: set GH_TOKEN or run 'gh auth login'" >&2
  exit 1
fi

# The security-alert / advisory reads are not public (cross-repo, see D-h) and a
# GitHub App installation token is scoped to a SINGLE org — but the dashboard
# spans two. So the token is resolved PER ORG (see security_token_for): an env
# var SECURITY_TOKEN_<ORG> (e.g. SECURITY_TOKEN_GO_OPENAPI), then a shared
# SECURITY_TOKEN, then GH_TOKEN. In CI, mint one App token per org and export
# each as SECURITY_TOKEN_<ORG>; locally a single SECURITY_TOKEN (a PAT with
# repo + security_events, member of both orgs) covers both. When the resolved
# token lacks scope the helpers return "unknown" and the columns degrade to ⚠️.

# Time windows. ISO timestamps compare lexicographically (same format + Z).
GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
YEAR_START="$(date -u +"%Y-01-01T00:00:00Z")"
MONTH_START="$(date -u +"%Y-%m-01T00:00:00Z")"

# --- GraphQL queries ---------------------------------------------------------

read -r -d '' DISCOVERY_QUERY <<'GRAPHQL' || true
query($org: String!, $endCursor: String) {
  organization(login: $org) {
    repositories(first: 100, after: $endCursor, privacy: PUBLIC, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        url
        description
        isArchived
        archivedAt
        isFork
        parent { nameWithOwner defaultBranchRef { name } }
        stargazerCount
        forkCount
        licenseInfo { spdxId }
        repositoryTopics(first: 20) { nodes { topic { name } } }
        defaultBranchRef {
          name
          target { ... on Commit { history { totalCount } committedDate } }
        }
        releases(first: 1, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { tagName publishedAt }
        }
        openIssues: issues(states: OPEN) { totalCount }
        openPRs: pullRequests(states: OPEN) { totalCount }
      }
    }
  }
}
GRAPHQL

read -r -d '' SINCE_QUERY <<'GRAPHQL' || true
query($owner: String!, $name: String!, $since: GitTimestamp!) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef {
      target { ... on Commit { history(since: $since) { totalCount } } }
    }
  }
}
GRAPHQL

read -r -d '' RELEASES_QUERY <<'GRAPHQL' || true
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    releases(first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes { publishedAt }
    }
  }
}
GRAPHQL

read -r -d '' SEARCH_QUERY <<'GRAPHQL' || true
query($q: String!) { search(query: $q, type: ISSUE) { issueCount } }
GRAPHQL

# --- jq transforms -----------------------------------------------------------

# Raw GraphQL repo node -> dashboard schema (§4.3). $org, $defaults, $overrides
# injected. Enrichment fields start at neutral defaults and are overwritten in
# phase 2. Badge URLs are NOT stored — the Hugo partials template them.
read -r -d '' NODE_TO_REPO <<'JQ' || true
{
  org: $org,
  name: .name,
  url: .url,
  description: (.description // ""),
  archived: .isArchived,
  archivedAt: (.archivedAt // null),
  isFork: .isFork,
  forkParent: (
    if .isFork and .parent then {
      owner:  (.parent.nameWithOwner | split("/")[0]),
      name:   (.parent.nameWithOwner | split("/")[1]),
      branch: (.parent.defaultBranchRef.name // "")
    } else null end
  ),
  defaultBranch: (.defaultBranchRef.name // ""),
  topics: [.repositoryTopics.nodes[].topic.name],
  license: (.licenseInfo.spdxId // ""),
  lastCommitAt: (.defaultBranchRef.target.committedDate // null),
  hasRelease: ((.releases.nodes | length) > 0 and (.releases.nodes[0].publishedAt != null)),
  release: (
    if (.releases.nodes | length) > 0 and (.releases.nodes[0].publishedAt != null)
    then {
      tag: .releases.nodes[0].tagName,
      publishedAt: .releases.nodes[0].publishedAt,
      ageDays: ((now - (.releases.nodes[0].publishedAt | fromdateiso8601)) / 86400 | floor)
    }
    else null
    end
  ),
  workflows: ($defaults + ($overrides[.name] // {})),
  openPRs: .openPRs.totalCount,
  openIssues: .openIssues.totalCount,
  openIssuesDeferred: 0,
  commitsSinceRelease: 0,
  commitsMTD: 0, commitsMTDNoBot: 0,
  commitsYTD: 0, commitsYTDNoBot: 0,
  releasesYTD: 0,
  totalCommits: (.defaultBranchRef.target.history.totalCount // 0),
  contributors: 0,
  lint: "unknown",
  securityAlerts: 0,
  securityAlertsUnknown: [],
  securityReports: 0,
  securityReportsUnknown: false,
  stars: .stargazerCount,
  forks: .forkCount
}
JQ

# --- helper functions (each returns a value on stdout, never aborts) ----------

# commits on the default branch since a timestamp (commits-since-release).
gql_commits_since() {
  local owner=$1 name=$2 since=$3
  gh api graphql -f query="${SINCE_QUERY}" -F owner="${owner}" -F name="${name}" -F since="${since}" \
    --jq '.data.repository.defaultBranchRef.target.history.totalCount' 2>/dev/null || echo 0
}

# {commitsMTD,commitsMTDNoBot,commitsYTD,commitsYTDNoBot} from the REST commit
# list since the start of the year. MTD is the subset since the start of month.
rest_commit_windows() {
  local owner=$1 name=$2 branch=$3 raw
  # Capture first, then transform: piping `gh | jq || echo` double-emits (jq's
  # output AND the fallback) when gh exits non-zero under `pipefail` but jq still
  # prints — yielding two concatenated JSON values that break the merge below.
  raw="$(gh api --paginate "/repos/${owner}/${name}/commits?sha=${branch}&since=${YEAR_START}&per_page=100" 2>/dev/null || true)"
  jq -s --arg month "${MONTH_START}" '
        (add // [])
        | map({
            date: .commit.author.date,
            bot: ((.author.type == "Bot")
                  or ((.author.login // "")     | ascii_downcase | endswith("[bot]"))
                  or ((.commit.author.name // "") | ascii_downcase | endswith("[bot]")))
          })
        | {
            commitsYTD:      length,
            commitsYTDNoBot: (map(select(.bot | not)) | length),
            commitsMTD:      (map(select(.date >= $month)) | length),
            commitsMTDNoBot: (map(select(.date >= $month and (.bot | not))) | length)
          }' <<<"${raw}" 2>/dev/null \
    || echo '{"commitsYTD":0,"commitsYTDNoBot":0,"commitsMTD":0,"commitsMTDNoBot":0}'
}

# number of releases published since the start of the year.
gql_releases_ytd() {
  local owner=$1 name=$2 raw
  raw="$(gh api graphql -f query="${RELEASES_QUERY}" -F owner="${owner}" -F name="${name}" 2>/dev/null || true)"
  jq --arg ys "${YEAR_START}" \
      '[.data.repository.releases.nodes[] | select(.publishedAt != null and .publishedAt >= $ys)] | length' \
      <<<"${raw}" 2>/dev/null || echo 0
}

# count of open issues bearing a deferred label (v2 / future-maybe), OR semantics.
gql_deferred_issues() {
  local owner=$1 name=$2
  local q="repo:${owner}/${name} is:issue is:open label:${DEFERRED_LABELS}"
  gh api graphql -f query="${SEARCH_QUERY}" -F q="${q}" \
    --jq '.data.search.issueCount' 2>/dev/null || echo 0
}

# contributor logins (real GitHub users) as a JSON array. Used both for the
# per-repo count and to union into per-org / overall *distinct* totals — counts
# are not summable across repos (a person contributes to many).
rest_contributor_logins() {
  local owner=$1 name=$2 raw
  raw="$(gh api --paginate "/repos/${owner}/${name}/contributors?per_page=100" 2>/dev/null || true)"
  jq -s '[ (add // []) | .[] | .login // empty ]' <<<"${raw}" 2>/dev/null || echo '[]'
}

# Fork-aware own work: for a fork, GitHub reports the WHOLE fork network for
# total commits and contributors (e.g. go-openapi/testify carries stretchr/testify's
# lineage: 1483 commits / 258 contributors vs ~227 / 7 of our own). The cross-fork
# compare API (parent_default...fork_default) yields exactly the commits unique to
# the fork — our own work since the fork point. Returns
# {"totalCommits": <ahead count>, "logins": [<distinct author logins>]}.
# (Time-windowed metrics — MTD/YTD, commits-since-release — need no adjustment:
# the fork's history holds only shared ancestry, all dated before the fork point,
# plus our own commits, so the `since=` filters already exclude upstream.)
# Non-fatal; the compare commit list caps at 250, but ahead_by (the count) is exact.
fork_own_commits() {
  local powner=$1 pname=$2 pbranch=$3 fowner=$4 fbranch=$5 raw ahead logins
  raw="$(gh api --paginate "/repos/${powner}/${pname}/compare/${pbranch}...${fowner}:${fbranch}?per_page=100" 2>/dev/null || true)"
  ahead="$(jq -s '.[0].ahead_by // 0' <<<"${raw}" 2>/dev/null || echo 0)"
  logins="$(jq -s '[ (map(.commits) | add // []) | .[] | .author.login // empty ] | unique' <<<"${raw}" 2>/dev/null || echo '[]')"
  jq -c -n --argjson c "${ahead:-0}" --argjson l "${logins:-[]}" '{totalCommits: $c, logins: $l}'
}

# conclusion of the "lint" job in the latest completed CI run on the branch.
rest_lint_status() {
  local owner=$1 name=$2 ci_file=$3 branch=$4 run_id concl
  [ -n "${ci_file}" ] && [ "${ci_file}" != "null" ] || { echo "unknown"; return; }
  run_id="$(gh api "/repos/${owner}/${name}/actions/workflows/${ci_file}/runs?branch=${branch}&status=completed&per_page=1" \
              --jq '.workflow_runs[0].id // empty' 2>/dev/null || true)"
  [ -n "${run_id}" ] || { echo "unknown"; return; }
  concl="$(gh api "/repos/${owner}/${name}/actions/runs/${run_id}/jobs" \
             --jq 'first(.jobs[] | select(.name | ascii_downcase | test("lint")) | .conclusion) // empty' \
             2>/dev/null || true)"
  echo "${concl:-unknown}"
}

# Classify a *failed* `gh api` security call from its captured stderr as either
# "off" (the feature is simply not enabled — count as 0) or "unknown" (a genuine
# read failure: no access / missing scope / 5xx / transport — surfaced as ⚠️ so a
# maintainer checks). `gh` writes "gh: <message> (HTTP <code>)" to stderr.
# Decided by HTTP status (validated against live responses, plan §5):
#   404                              -> off  (no analysis / feature off; public-only dataset, so not a private 404)
#   403 + a "feature disabled" message -> off
#   any other 403 / 401 / 5xx / none -> unknown
# NOTE: the advisories endpoint returns 200 with an EMPTY list when the token
# lacks advisory-read scope, so a clean 0 there is only trustworthy with a token
# that can read unpublished advisories (App token / `repo` scope) — see README.
SEC_OFF_RE='not enabled|disabled|not available|no analysis|archived'

# Resolve the security-read token for an org: SECURITY_TOKEN_<ORG> (org upper-cased
# with '-'/'.' -> '_'), else the shared SECURITY_TOKEN, else GH_TOKEN. See the
# preflight note for why this is per-org (App tokens are single-org).
security_token_for() {
  local owner=$1 var
  var="SECURITY_TOKEN_$(printf '%s' "${owner}" | tr 'a-z.-' 'A-Z__')"
  printf '%s' "${!var:-${SECURITY_TOKEN:-${GH_TOKEN:-}}}"
}

_sec_classify() {
  local errfile=$1 code
  # `|| true`: a no-match grep must not trip `set -o pipefail` and abort the caller.
  code="$(grep -oE 'HTTP [0-9]+' "${errfile}" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)"
  if [ "${code}" = "404" ]; then
    echo off
  elif [ "${code}" = "403" ] && grep -qiE "${SEC_OFF_RE}" "${errfile}"; then
    echo off
  else
    echo unknown
  fi
}

# Open security alerts across all flavors, using the per-org token -> a JSON object
# {"count": <int>, "unknown": [<flavor>...]}. Per flavor: a clean read adds its
# open-alert count; an "off" feature contributes 0; an "unknown" failure marks
# the flavor (⚠️ in the template). Counts are small, but paginate anyway.
security_alerts() {
  local owner=$1 name=$2
  local total=0 unknown='[]' tok
  local flavor path out err count cls
  tok="$(security_token_for "${owner}")"
  for flavor in code-scanning dependabot secret-scanning; do
    path="/repos/${owner}/${name}/${flavor}/alerts?state=open&per_page=100"
    err="$(mktemp)"
    if out="$(GH_TOKEN="${tok}" gh api --paginate "${path}" 2>"${err}")"; then
      cls=ok
    else
      cls="$(_sec_classify "${err}")"
    fi
    rm -f "${err}"
    case "${cls}" in
      ok)      count="$(jq -s '(add // []) | length' <<<"${out}" 2>/dev/null || echo 0)"; total=$(( total + count )) ;;
      off)     : ;;
      unknown) unknown="$(jq -c --arg f "${flavor}" '. + [$f]' <<<"${unknown}")" ;;
    esac
  done
  jq -c -n --argjson c "${total}" --argjson u "${unknown}" '{count: $c, unknown: $u}'
}

# Open repository security advisories (privately-reported / draft vulns), using
# the per-org token -> {"count": <int>, "unknown": <bool>}. "Open" = state triage or
# draft (not published, not closed). A read failure -> unknown:true (flagged).
security_reports() {
  local owner=$1 name=$2 out err count cls tok
  tok="$(security_token_for "${owner}")"
  err="$(mktemp)"
  if out="$(GH_TOKEN="${tok}" gh api --paginate \
             "/repos/${owner}/${name}/security-advisories?per_page=100" 2>"${err}")"; then
    cls=ok
  else
    cls="$(_sec_classify "${err}")"
  fi
  rm -f "${err}"
  case "${cls}" in
    ok)  count="$(jq -s '[ (add // [])[] | select(.state == "triage" or .state == "draft") ] | length' \
                    <<<"${out}" 2>/dev/null || echo 0)"
         jq -c -n --argjson c "${count}" '{count: $c, unknown: false}' ;;
    off) jq -c -n '{count: 0, unknown: false}' ;;
    *)   jq -c -n '{count: 0, unknown: true}' ;;
  esac
}

# --- phase 1: discover + collect metadata ------------------------------------

excludes_json="$(printf '%s\n' "${EXCLUDES[@]}" | jq -R . | jq -s .)"
fork_includes_json="$(printf '%s\n' "${FORK_INCLUDES[@]}" | jq -R . | jq -s .)"

all_repos='[]'
for org in "${ORGS[@]}"; do
  echo "==> discovering ${org}" >&2
  org_repos="$(
    gh api graphql --paginate -f query="${DISCOVERY_QUERY}" -F org="${org}" \
      | jq --arg org "${org}" \
           --argjson excludes "${excludes_json}" \
           --argjson forkIncludes "${fork_includes_json}" \
           --argjson defaults "${WF_DEFAULTS}" \
           --argjson overrides "${WF_OVERRIDES}" \
          '.data.organization.repositories.nodes[]
             | select((.isFork | not) or (.name as $n | $forkIncludes | index($n)))
             | select(.name as $n | $excludes | index($n) | not)
             | '"${NODE_TO_REPO}" \
      | jq -s .
  )"
  all_repos="$(jq -n --argjson a "${all_repos}" --argjson b "${org_repos}" '$a + $b')"
done

total="$(jq 'length' <<<"${all_repos}")"
active="$(jq '[.[] | select(.archived | not)] | length' <<<"${all_repos}")"
echo "==> ${total} repos (${active} active); enriching active repos..." >&2

# --- phase 2: per-repo enrichment --------------------------------------------

tmp_enriched="$(mktemp)"
logins_dir="$(mktemp -d)"   # one file of contributor logins per org, plus _all
trap 'rm -rf "${tmp_enriched}" "${logins_dir}"' EXIT

count="$(jq 'length' <<<"${all_repos}")"
for ((i = 0; i < count; i++)); do
  repo="$(jq -c ".[${i}]" <<<"${all_repos}")"
  org="$(jq -r '.org'           <<<"${repo}")"
  name="$(jq -r '.name'         <<<"${repo}")"
  branch="$(jq -r '.defaultBranch' <<<"${repo}")"
  has_release="$(jq -r '.hasRelease' <<<"${repo}")"
  ci_file="$(jq -r '.workflows.ci // empty' <<<"${repo}")"

  # Archived repos appear only on the Github tab's archived table — they carry
  # the neutral enrichment defaults and cost no API calls.
  if [ "$(jq -r '.archived' <<<"${repo}")" = "true" ]; then
    echo "    - ${org}/${name} (archived; skipping enrichment)" >&2
    printf '%s\n' "${repo}" >> "${tmp_enriched}"
    continue
  fi
  echo "    - ${org}/${name}" >&2

  csr=0
  if [ "${has_release}" = "true" ]; then
    since="$(jq -r '.release.publishedAt' <<<"${repo}")"
    csr="$(gql_commits_since "${org}" "${name}" "${since}")"
  fi
  windows="$(rest_commit_windows "${org}" "${name}" "${branch}")"
  releases_ytd="$(gql_releases_ytd "${org}" "${name}")"
  deferred="$(gql_deferred_issues "${org}" "${name}")"
  lint="$(rest_lint_status "${org}" "${name}" "${ci_file}" "${branch}")"
  secalerts="$(security_alerts "${org}" "${name}")"
  secreports="$(security_reports "${org}" "${name}")"
  # Non-fatal guard: never let an empty helper result abort the merge below.
  [ -n "${secalerts}" ]  || secalerts='{"count":0,"unknown":[]}'
  [ -n "${secreports}" ] || secreports='{"count":0,"unknown":false}'

  # Contributors: per-repo count from the login list; accumulate logins so the
  # subtotal/total rows can report DISTINCT contributors over the scope. Forks
  # with an upstream parent count only their OWN commits/contributors since the
  # fork point (else GitHub's whole-network totals — e.g. testify's stretchr
  # lineage — inflate both the per-repo figure and the distinct unions); this
  # also overrides the discovery totalCommits. Non-forks use the plain endpoint.
  total_commits_own="null"
  if [ "$(jq -r '.isFork and (.forkParent != null)' <<<"${repo}")" = "true" ]; then
    p_owner="$(jq -r '.forkParent.owner'  <<<"${repo}")"
    p_name="$(jq -r '.forkParent.name'    <<<"${repo}")"
    p_branch="$(jq -r '.forkParent.branch' <<<"${repo}")"
    own="$(fork_own_commits "${p_owner}" "${p_name}" "${p_branch}" "${org}" "${branch}")"
    logins="$(jq -c '.logins' <<<"${own}")"
    total_commits_own="$(jq '.totalCommits' <<<"${own}")"
  else
    logins="$(rest_contributor_logins "${org}" "${name}")"
  fi
  contributors="$(jq 'length' <<<"${logins}")"
  jq -r '.[]' <<<"${logins}" | grep . >> "${logins_dir}/${org}" || true
  jq -r '.[]' <<<"${logins}" | grep . >> "${logins_dir}/_all"  || true

  jq -c \
    --argjson csr "${csr:-0}" \
    --argjson windows "${windows}" \
    --argjson releasesYTD "${releases_ytd:-0}" \
    --argjson deferred "${deferred:-0}" \
    --argjson contributors "${contributors:-0}" \
    --argjson totalCommitsOwn "${total_commits_own:-null}" \
    --arg lint "${lint:-unknown}" \
    --argjson secalerts "${secalerts}" \
    --argjson secreports "${secreports}" \
    '. + $windows
       + { commitsSinceRelease: $csr,
           releasesYTD: $releasesYTD,
           openIssuesDeferred: $deferred,
           contributors: $contributors,
           lint: $lint,
           securityAlerts: $secalerts.count,
           securityAlertsUnknown: $secalerts.unknown,
           securityReports: $secreports.count,
           securityReportsUnknown: $secreports.unknown }
       + (if $totalCommitsOwn != null then { totalCommits: $totalCommitsOwn } else {} end)' \
    <<<"${repo}" >> "${tmp_enriched}"
done

all_repos="$(jq -s . "${tmp_enriched}")"

# --- distinct contributors per scope (union of logins, not a sum) ------------

contributors_distinct='{}'
for org in "${ORGS[@]}"; do
  n=0
  [ -f "${logins_dir}/${org}" ] && n="$(sort -u "${logins_dir}/${org}" | grep -c . || true)"
  contributors_distinct="$(jq -n --argjson m "${contributors_distinct}" --arg k "${org}" --argjson v "${n:-0}" '$m + {($k): $v}')"
done
n_all=0
[ -f "${logins_dir}/_all" ] && n_all="$(sort -u "${logins_dir}/_all" | grep -c . || true)"
contributors_distinct="$(jq -n --argjson m "${contributors_distinct}" --argjson v "${n_all:-0}" '$m + {"all": $v}')"

# --- assemble + write --------------------------------------------------------

orgs_json="$(printf '%s\n' "${ORGS[@]}" | jq -R . | jq -s .)"
mkdir -p "$(dirname "${OUTPUT}")"
jq -n \
  --arg generatedAt "${GENERATED_AT}" \
  --argjson orgs "${orgs_json}" \
  --argjson contributorsDistinct "${contributors_distinct}" \
  --argjson repos "${all_repos}" \
  '{ generatedAt: $generatedAt, orgs: $orgs, contributorsDistinct: $contributorsDistinct, repos: ($repos | sort_by(.org, .name)) }' \
  > "${OUTPUT}"

echo "==> wrote ${OUTPUT} (${total} repos, generated ${GENERATED_AT})" >&2
