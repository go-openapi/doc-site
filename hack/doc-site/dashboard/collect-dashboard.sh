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
  local owner=$1 name=$2 branch=$3
  gh api --paginate "/repos/${owner}/${name}/commits?sha=${branch}&since=${YEAR_START}&per_page=100" 2>/dev/null \
    | jq -s --arg month "${MONTH_START}" '
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
          }' 2>/dev/null || echo '{"commitsYTD":0,"commitsYTDNoBot":0,"commitsMTD":0,"commitsMTDNoBot":0}'
}

# number of releases published since the start of the year.
gql_releases_ytd() {
  local owner=$1 name=$2
  gh api graphql -f query="${RELEASES_QUERY}" -F owner="${owner}" -F name="${name}" 2>/dev/null \
    | jq --arg ys "${YEAR_START}" \
        '[.data.repository.releases.nodes[] | select(.publishedAt != null and .publishedAt >= $ys)] | length' \
        2>/dev/null || echo 0
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
  local owner=$1 name=$2
  gh api --paginate "/repos/${owner}/${name}/contributors?per_page=100" 2>/dev/null \
    | jq -s '[ (add // []) | .[] | .login // empty ]' 2>/dev/null || echo '[]'
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

  # Contributors: per-repo count from the login list; accumulate logins so the
  # subtotal/total rows can report DISTINCT contributors over the scope.
  logins="$(rest_contributor_logins "${org}" "${name}")"
  contributors="$(jq 'length' <<<"${logins}")"
  jq -r '.[]' <<<"${logins}" | grep . >> "${logins_dir}/${org}" || true
  jq -r '.[]' <<<"${logins}" | grep . >> "${logins_dir}/_all"  || true

  jq -c \
    --argjson csr "${csr:-0}" \
    --argjson windows "${windows}" \
    --argjson releasesYTD "${releases_ytd:-0}" \
    --argjson deferred "${deferred:-0}" \
    --argjson contributors "${contributors:-0}" \
    --arg lint "${lint:-unknown}" \
    '. + $windows
       + { commitsSinceRelease: $csr,
           releasesYTD: $releasesYTD,
           openIssuesDeferred: $deferred,
           contributors: $contributors,
           lint: $lint }' \
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
