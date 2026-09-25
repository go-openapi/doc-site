#!/usr/bin/env bash
#
# collect-security.sh — collect the security advisories & alerts page data.
#
# Aggregates, per public repo across the go-openapi and go-swagger orgs, into a
# single Hugo data file (hack/doc-site/hugo/data/security.json) consumed by the
# `advisories` shortcode:
#
#   - published repository security advisories (title, reporters, severity,
#     fixed versions) + counts of advisories under analysis (triage / draft).
#     Closed advisories are skipped.
#   - code scanning alerts (all tools but Scorecard, which reports best-practice
#     compliance rather than releasable vulnerabilities) and Dependabot alerts:
#     fixed alerts with the release that shipped the fix; dismissed alerts
#     counted by reason; open alerts counted only (never disclosed in detail).
#
# Fix release of a code scanning alert: the alert's default-branch instances in
# state "fixed" carry the commit of the analysis that saw it gone. The fix
# release is the first release whose tag contains that commit (compare API).
# Dependabot alerts carry no commit: the fix release is inferred as the first
# release published after `fixed_at` (flagged `inferred`).
#
# Cache: these lookups cost ~2 API calls per fixed alert (~10 minutes for a full
# run), but a resolved fix release never changes. The output records them per
# repo (`alertReleases`: alert number -> fixedAt, release, inferred) and the
# next run reuses them from the previous output (-c, default: OUTPUT itself).
# An entry is reused while the alert's fixed_at is unchanged (a reopened then
# re-fixed alert is looked up again) and its release still exists. Fixed but
# not yet released alerts are never cached. -f ignores the cache.
#
# Usage:
#   GH_TOKEN=<token> ./collect-security.sh [-o OUTPUT] [-c CACHE] [-f] [-x EXCLUDE]... [-i FORK_INCLUDE]...
#
# Token resolution is per org, as in collect-dashboard.sh: SECURITY_TOKEN_<ORG>,
# then SECURITY_TOKEN, then GH_TOKEN. ALL calls for an org's repos use that token
# (not just the security reads): the compare lookups add a few hundred calls and
# the default Actions token is rate-limited to 1000/hour.
#
# Requires: gh, jq. The data file is ephemeral and gitignored.

set -euo pipefail

# --- configuration -----------------------------------------------------------

ORGS=(go-openapi go-swagger)
EXCLUDES=(.github)
FORK_INCLUDES=(testify go-yaml)

# Code scanning tools left out of the page (jq array literal).
EXCLUDED_TOOLS='["Scorecard"]'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/../hugo/data/security.json"

CACHE=""
NO_CACHE=false

while getopts ":o:c:fx:i:" opt; do
  case "${opt}" in
    o) OUTPUT="${OPTARG}" ;;
    c) CACHE="${OPTARG}" ;;
    f) NO_CACHE=true ;;
    x) EXCLUDES+=("${OPTARG}") ;;
    i) FORK_INCLUDES+=("${OPTARG}") ;;
    *) echo "usage: $0 [-o OUTPUT] [-c CACHE] [-f] [-x EXCLUDE]... [-i FORK_INCLUDE]..." >&2; exit 2 ;;
  esac
done
CACHE="${CACHE:-${OUTPUT}}"

# --- preflight ---------------------------------------------------------------

for tool in gh jq; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "::error::${tool} is required but not installed" >&2; exit 1; }
done
if [ -z "${GH_TOKEN:-}${SECURITY_TOKEN:-}" ] && ! gh auth status >/dev/null 2>&1; then
  echo "::error::no GitHub credentials: set GH_TOKEN / SECURITY_TOKEN or run 'gh auth login'" >&2
  exit 1
fi

GENERATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# --- helpers -----------------------------------------------------------------

security_token_for() {
  local owner=$1 var
  var="SECURITY_TOKEN_$(printf '%s' "${owner}" | tr 'a-z.-' 'A-Z__')"
  printf '%s' "${!var:-${SECURITY_TOKEN:-${GH_TOKEN:-}}}"
}

# TOKEN is set per org in the main loop.
TOKEN=""
api() { GH_TOKEN="${TOKEN}" gh api "$@"; }

# Same classification as collect-dashboard.sh: a feature that is simply off
# (404, or 403 with a "disabled" message) counts as empty; anything else is
# "unknown" and flagged on the page rather than shown as a clean zero.
SEC_OFF_RE='not enabled|must be enabled|disabled|not available|no analysis|archived'

# fetch_list PATH OUTFILE -> prints ok|off|unknown; on ok, OUTFILE holds the
# concatenated array of all pages.
fetch_list() {
  local path=$1 outfile=$2 err raw code
  err="$(mktemp)"; raw="$(mktemp)"
  if api --paginate "${path}" >"${raw}" 2>"${err}" && jq -s 'add // []' "${raw}" > "${outfile}" 2>/dev/null; then
    rm -f "${err}" "${raw}"; echo ok; return
  fi
  echo '[]' > "${outfile}"
  code="$(grep -oE 'HTTP [0-9]+' "${err}" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)"
  if [ "${code}" = "404" ] || { [ "${code}" = "403" ] && grep -qiE "${SEC_OFF_RE}" "${err}"; }; then
    echo off
  else
    echo unknown
  fi
  rm -f "${err}" "${raw}"
}

# flag_alerts STATUS SOURCE: record a code-scanning / dependabot read that is off
# (feature disabled) or unknown (unreadable) in alerts_off / alerts_unknown.
flag_alerts() {
  case "$1" in
    off)     alerts_off="$(jq -c --arg s "$2" '. + [$s]' <<<"${alerts_off}")" ;;
    unknown) alerts_unknown="$(jq -c --arg s "$2" '. + [$s]' <<<"${alerts_unknown}")" ;;
  esac
}

# Per-repo cache of commit sha -> fix release tag ("" = not released yet).
declare -A RELEASE_OF

# release_containing OWNER NAME BRANCH SHA RELEASES_FILE -> tag, "" if no
# release contains the commit yet, or "?" if the commit is no longer on the
# default branch (history rewritten since the analysis): the caller then falls
# back to the fix date. Releases are sorted oldest first. One compare against
# the latest release tells whether the fix shipped at all, and gives the commit
# date; the scan then starts at the first release published after that date
# (usually a hit on the first try).
release_containing() {
  local owner=$1 name=$2 branch=$3 sha=$4 rfile=$5 latest raw status since tag
  if [ -n "${RELEASE_OF[${sha}]+x}" ]; then printf '%s' "${RELEASE_OF[${sha}]}"; return; fi
  latest="$(jq -r 'last.tag // empty' "${rfile}")"
  RELEASE_OF[${sha}]=""
  [ -n "${latest}" ] || return 0
  raw="$(api "/repos/${owner}/${name}/compare/${sha}...${latest}?per_page=1" 2>/dev/null || true)"
  status="$(jq -r '.status // empty' <<<"${raw}" 2>/dev/null || true)"
  case "${status}" in
    ahead|identical) ;;
    *)
      status="$(api "/repos/${owner}/${name}/compare/${sha}...${branch}?per_page=1" --jq '.status' 2>/dev/null || true)"
      if [ "${status}" != "ahead" ] && [ "${status}" != "identical" ]; then RELEASE_OF[${sha}]="?"; fi
      printf '%s' "${RELEASE_OF[${sha}]}"
      return 0 ;;
  esac
  since="$(jq -r '.base_commit.commit.committer.date // ""' <<<"${raw}")"
  RELEASE_OF[${sha}]="${latest}"
  for tag in $(jq -r --arg s "${since}" '.[] | select(.publishedAt >= $s) | .tag' "${rfile}"); do
    [ "${tag}" = "${latest}" ] && break
    status="$(api "/repos/${owner}/${name}/compare/${sha}...${tag}?per_page=1" --jq '.status' 2>/dev/null || true)"
    if [ "${status}" = "ahead" ] || [ "${status}" = "identical" ]; then
      RELEASE_OF[${sha}]="${tag}"; break
    fi
  done
  printf '%s' "${RELEASE_OF[${sha}]}"
}

# --- jq transforms -----------------------------------------------------------

# Repository advisories -> page schema. Reporters come from the credits; for a
# privately reported advisory without reporter credit, the author is the reporter.
read -r -d '' ADVISORIES <<'JQ' || true
{
  published: [ .[] | select(.state == "published") | {
      ghsaId: .ghsa_id,
      url: .html_url,
      title: (.summary | sub("^#+\\s*"; "")),
      severity: (.severity // null),
      publishedAt: .published_at,
      reporters: (
        [ .credits_detailed[]? | select(.type == "reporter") | .user.login ] as $r
        | if ($r | length) > 0 then $r
          elif .submission != null and .author != null then [ .author.login ]
          else [] end
      ),
      fixes: [ .vulnerabilities[]? | {
          package: ((.package.name // "") | sub("^github\\.com/"; "")),
          patched: (.patched_versions // "")
        }
        # Release to link: the version in the free-text patched_versions, tagged
        # in the repo owning the package (go-openapi/swag/jsonutils -> go-openapi/swag).
        | . + {
          releaseRepo: (.package | split("/") | if length >= 2 then .[0:2] | join("/") else null end),
          releaseTag: ((.patched | capture("(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)")? | "v" + .v) // null)
        }
      ]
    } ] | sort_by(.publishedAt) | reverse,
  triage: ([ .[] | select(.state == "triage") ] | length),
  draft:  ([ .[] | select(.state == "draft") ] | length)
}
JQ

# Code scanning alerts (excluded tools removed) -> normalized alerts.
read -r -d '' CODE_SCANNING <<'JQ' || true
[ .[] | select(.tool.name as $t | $excluded | index($t) | not) | {
    source: "code-scanning",
    tool: .tool.name,
    number: .number,
    url: .html_url,
    id: .rule.id,
    title: ((.rule.description // .rule.name // "") | sub("^\\[[A-Z0-9-]+\\] "; "")),
    severity: (.rule.security_severity_level // null),
    state: .state,
    reason: (.dismissed_reason // null),
    fixedAt: (.fixed_at // null)
} ]
JQ

read -r -d '' DEPENDABOT <<'JQ' || true
[ .[] | {
    source: "dependabot",
    tool: "Dependabot",
    number: .number,
    url: .html_url,
    id: (.security_advisory.cve_id // .security_advisory.ghsa_id),
    title: ((.security_vulnerability.package.name // "") + ": " + (.security_advisory.summary // "")),
    severity: (.security_advisory.severity // null),
    state: (if .state == "auto_dismissed" then "dismissed" else .state end),
    reason: (if .state == "auto_dismissed" then "auto-dismissed"
             else (.dismissed_reason // null | if . then gsub("_"; " ") else . end) end),
    fixedAt: (.fixed_at // null)
} ]
JQ

# Assemble a repo entry. Fixed alerts are grouped by fix release, most recent
# first, with not-yet-released fixes on top. Within a release, alerts reporting
# the same vulnerability id from several tools (e.g. Trivy + Dependabot) are
# merged. Each id links to its public reference: alert pages themselves are only
# visible to maintainers.
read -r -d '' ASSEMBLE <<'JQ' || true
def rank: {"critical": 4, "high": 3, "medium": 2, "moderate": 2, "low": 1}[. // ""] // 0;
def link:
  if test("^CVE-") then "https://nvd.nist.gov/vuln/detail/" + .
  elif test("^GO-") then "https://pkg.go.dev/vuln/" + .
  elif test("^GHSA-") then "https://github.com/advisories/" + .
  elif test("^[a-z]+/") then "https://codeql.github.com/codeql-query-help/" + split("/")[0] + "/" + gsub("/"; "-") + "/"
  else null end;
($releases | map({(.tag): .publishedAt}) | add // {}) as $relDate
| ($alerts | map(select(.state == "fixed"))) as $fixed
| {
    org: $org, name: $name, url: $url,
    hasReleases: (($releases | length) > 0),
    # An advisory sorts by the release of its patched version for a module of
    # this repo (root or nested, e.g. swag/jsonutils: modules are released in
    # lockstep under the root tag), else by its publication date.
    advisories: [ $adv.published[] | . as $a | . + {
      releaseAt: (
        [ .fixes[] | select(.package == ($org + "/" + $name) or (.package | startswith($org + "/" + $name + "/")))
          | (.patched | capture("(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)")? | .v) | $relDate["v" + .] // empty ]
        | max
      )
    } ],
    advisoriesTriage: $adv.triage,
    advisoriesDraft: $adv.draft,
    advisoriesUnknown: $advUnknown,
    fixedAlerts: ($fixed | length),
    fixedUnreleased: ($fixed | map(select(.release == null)) | length),
    fixedByRelease: (
      $fixed
      | group_by(.release // "")
      | map({
          release: (.[0].release // null),
          publishedAt: (if .[0].release then $relDate[.[0].release] else null end),
          lastFixedAt: (map(.fixedAt) | max),
          inferred: all(.[]; .inferred),
          count: length,
          tools: (map(.tool) | unique),
          maxSeverity: (map(.severity) | max_by(rank) | if rank > 0 then . else null end),
          vulns: (
            group_by(.id) | map({
              id: .[0].id,
              count: length,
              link: (.[0].id | link),
              title: .[0].title,
              severity: (map(.severity) | max_by(rank)),
              tools: (map(.tool) | unique)
            }) | sort_by(-(.severity | rank), .id)
          )
        })
      | sort_by(.publishedAt // "9999") | reverse
    ),
    dismissed: (
      $alerts | map(select(.state == "dismissed") | .reason // "unspecified")
      | group_by(.) | map({reason: .[0], count: length})
    ),
    dismissedCount: ($alerts | map(select(.state == "dismissed")) | length),
    open: ($alerts | map(select(.state == "open")) | length),
    openCodeScanning: ($alerts | map(select(.state == "open" and .source == "code-scanning")) | length),
    openDependabot: ($alerts | map(select(.state == "open" and .source == "dependabot")) | length),
    openBySeverity: (
      $alerts | map(select(.state == "open") | .severity // "unrated")
      | group_by(.) | map({severity: .[0], count: length}) | sort_by(-(.severity | rank))
    ),
    alertsUnknown: $alertsUnknown,
    alertsOff: $alertsOff,
    alertReleases: ($fx | map({(.number | tostring): {fixedAt, release, inferred}}) | add // {})
  }
# One list for the detail table: newest release first (not-yet-released fixes
# on top), and within a release the advisories before the alerts.
| . + { details: (
    [ (.advisories[] | {kind: "advisory", sortAt: (.releaseAt // .publishedAt), rank: 0,
                         releasedAt: .releaseAt, year: ((.releaseAt // .publishedAt)[0:4])} + .),
      (.fixedByRelease[] | {kind: "alerts", sortAt: (.publishedAt // "9999"), rank: 1,
                            releasedAt: .publishedAt, year: ((.publishedAt // .lastFixedAt)[0:4])} + .) ]
    | sort_by(.sortAt, -.rank) | reverse
  ) }
| . + { empty: ((.advisories | length) == 0 and .advisoriesTriage == 0 and .advisoriesDraft == 0
                and .fixedAlerts == 0 and .dismissedCount == 0 and .open == 0
                and (.alertsUnknown | length) == 0 and (.advisoriesUnknown | not)) }
JQ

# --- main --------------------------------------------------------------------

excludes_json="$(printf '%s\n' "${EXCLUDES[@]}" | jq -R . | jq -s .)"
fork_includes_json="$(printf '%s\n' "${FORK_INCLUDES[@]}" | jq -R . | jq -s .)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
: > "${work}/repos.jsonl"

# Previous fix releases, as {"org/name": {"<alert number>": {fixedAt, release, inferred}}}.
echo '{}' > "${work}/cache.json"
if [ "${NO_CACHE}" = false ] && [ -s "${CACHE}" ]; then
  jq '[ .repos[]? | {key: "\(.org)/\(.name)", value: (.alertReleases // {})} ] | from_entries' \
    "${CACHE}" > "${work}/cache.json" 2>/dev/null || echo '{}' > "${work}/cache.json"
  echo "==> reusing fix releases from ${CACHE}" >&2
fi

for org in "${ORGS[@]}"; do
  TOKEN="$(security_token_for "${org}")"
  echo "==> ${org}" >&2
  repos="$(api --paginate "/orgs/${org}/repos?type=public&per_page=100" \
    | jq -s -c --argjson excludes "${excludes_json}" --argjson forkIncludes "${fork_includes_json}" '
        add // [] | map(select(
          (.archived | not) and (.private | not)
          and ((.fork | not) or (.name as $n | $forkIncludes | index($n)))
          and (.name as $n | $excludes | index($n) | not)))
        | sort_by(.name) | map({name, url: .html_url, branch: .default_branch})')"

  while IFS= read -r repo <&3; do
    name="$(jq -r .name <<<"${repo}")"
    url="$(jq -r .url <<<"${repo}")"
    branch="$(jq -r .branch <<<"${repo}")"
    echo "    - ${org}/${name}" >&2
    RELEASE_OF=()

    # Releases, oldest first (drafts excluded).
    api --paginate "/repos/${org}/${name}/releases?per_page=100" 2>/dev/null \
      | jq -s '[ add // [] | .[] | select(.draft | not) | select(.published_at != null)
                 | {tag: .tag_name, publishedAt: .published_at} ] | sort_by(.publishedAt)' \
      > "${work}/releases.json" 2>/dev/null || echo '[]' > "${work}/releases.json"

    # Advisories.
    st="$(fetch_list "/repos/${org}/${name}/security-advisories?per_page=100" "${work}/adv.json")"
    jq "${ADVISORIES}" "${work}/adv.json" > "${work}/adv.out.json"
    adv_unknown=false; [ "${st}" = unknown ] && adv_unknown=true

    alerts_unknown='[]'; alerts_off='[]'

    # Code scanning alerts, with the fix release of each fixed alert.
    st="$(fetch_list "/repos/${org}/${name}/code-scanning/alerts?per_page=100" "${work}/cs.json")"
    flag_alerts "${st}" code-scanning
    jq --argjson excluded "${EXCLUDED_TOOLS}" "${CODE_SCANNING}" "${work}/cs.json" > "${work}/cs.out.json"

    # Cache hits: same fixed_at, release still published. The rest is looked up.
    jq -c --arg k "${org}/${name}" --slurpfile c "${work}/cache.json" --slurpfile rel "${work}/releases.json" '
        ($c[0][$k] // {}) as $cache | ($rel[0] | map(.tag)) as $tags
        | .[] | select(.state == "fixed")
        | ($cache[.number | tostring]) as $hit
        | select($hit != null and $hit.fixedAt == .fixedAt and $hit.release != null
                 and ($tags | index($hit.release)) != null)
        | {number, fixedAt} + ($hit | {release, inferred})' \
      "${work}/cs.out.json" > "${work}/cs.fixed.jsonl"
    hits="$(grep -c . "${work}/cs.fixed.jsonl" || true)"
    jq -s 'map(.number)' "${work}/cs.fixed.jsonl" > "${work}/cs.hits.json"
    misses=0
    # A repo without releases has no fix release to find: skip the lookups.
    n_releases="$(jq length "${work}/releases.json")"
    while IFS=$'\t' read -r number fixed_at <&4; do
      misses=$((misses + 1))
      if [ "${n_releases}" = 0 ]; then
        jq -c -n --argjson n "${number}" --arg f "${fixed_at}" \
          '{number: $n, fixedAt: $f, release: null, inferred: false}' >> "${work}/cs.fixed.jsonl"
        continue
      fi
      shas="$(api --paginate "/repos/${org}/${name}/code-scanning/alerts/${number}/instances?per_page=100" \
                --jq ".[] | select(.ref == \"refs/heads/${branch}\" and .state == \"fixed\") | .commit_sha" \
                2>/dev/null | sort -u || true)"
      release=""; exact=false
      if [ -n "${shas}" ]; then
        # Instances of several analysis categories may be fixed by different
        # commits: the alert is fixed once all are, i.e. in the latest of their
        # fix releases (releases are sorted oldest first).
        exact=true; best=-1
        for sha in ${shas}; do
          tag="$(release_containing "${org}" "${name}" "${branch}" "${sha}" "${work}/releases.json")"
          if [ "${tag}" = "?" ]; then exact=false; break; fi
          if [ -z "${tag}" ]; then best=-1; break; fi
          idx="$(jq --arg t "${tag}" 'map(.tag) | index($t)' "${work}/releases.json")"
          [ "${idx}" -gt "${best}" ] && best="${idx}"
        done
        [ "${best}" -ge 0 ] && release="$(jq -r ".[${best}].tag" "${work}/releases.json")"
      fi
      if [ "${exact}" = false ]; then
        release="$(jq -r --arg d "${fixed_at}" 'first(.[] | select(.publishedAt >= $d)) | .tag // empty' "${work}/releases.json")"
      fi
      jq -c -n --argjson n "${number}" --arg f "${fixed_at}" --arg r "${release}" --argjson e "${exact}" \
        '{number: $n, fixedAt: $f, release: (if $r == "" then null else $r end), inferred: ($e | not)}' >> "${work}/cs.fixed.jsonl"
    done 4< <(jq -r --slurpfile hit "${work}/cs.hits.json" \
                '.[] | select(.state == "fixed") | select(.number as $n | $hit[0] | index($n) | not)
                 | [.number, .fixedAt] | @tsv' "${work}/cs.out.json")
    [ "${hits}${misses}" = "00" ] || echo "      fixed code scanning alerts: ${hits} cached, ${misses} looked up" >&2
    jq --slurpfile fx "${work}/cs.fixed.jsonl" '
        ($fx | map({(.number | tostring): .}) | add // {}) as $m
        | map(if .state == "fixed" then . + (($m[.number | tostring] // {release: null, inferred: true}) | {release, inferred}) else . end)' \
      "${work}/cs.out.json" > "${work}/cs.final.json"

    # Dependabot alerts: fix release inferred from the fix date.
    st="$(fetch_list "/repos/${org}/${name}/dependabot/alerts?per_page=100" "${work}/dep.json")"
    flag_alerts "${st}" dependabot
    jq --slurpfile rel "${work}/releases.json" "${DEPENDABOT}"' | map(
          if .state == "fixed" then
            .fixedAt as $d | . + {release: ((first($rel[0][] | select(.publishedAt >= $d)) | .tag) // null), inferred: true}
          else . end)' "${work}/dep.json" > "${work}/dep.final.json"

    jq -c -n \
      --arg org "${org}" --arg name "${name}" --arg url "${url}" \
      --slurpfile releases "${work}/releases.json" \
      --slurpfile adv "${work}/adv.out.json" \
      --argjson advUnknown "${adv_unknown}" \
      --slurpfile cs "${work}/cs.final.json" \
      --slurpfile dep "${work}/dep.final.json" \
      --argjson alertsUnknown "${alerts_unknown}" \
      --argjson alertsOff "${alerts_off}" \
      --slurpfile fx "${work}/cs.fixed.jsonl" \
      '$releases[0] as $releases | $adv[0] as $adv | ($cs[0] + $dep[0]) as $alerts | '"${ASSEMBLE}" \
      >> "${work}/repos.jsonl"
  done 3< <(jq -c '.[]' <<<"${repos}")
done

orgs_json="$(printf '%s\n' "${ORGS[@]}" | jq -R . | jq -s .)"
mkdir -p "$(dirname "${OUTPUT}")"
jq -s --arg generatedAt "${GENERATED_AT}" --argjson orgs "${orgs_json}" --argjson excludedTools "${EXCLUDED_TOOLS}" \
  '{ generatedAt: $generatedAt, orgs: $orgs, excludedTools: $excludedTools, repos: . }' \
  "${work}/repos.jsonl" > "${work}/security.json"
# Replace the output only once complete: it is also the next run's cache.
mv "${work}/security.json" "${OUTPUT}"

echo "==> wrote ${OUTPUT} ($(jq '.repos | length' "${OUTPUT}") repos, generated ${GENERATED_AT})" >&2
