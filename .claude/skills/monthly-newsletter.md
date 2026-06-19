---
name: monthly-newsletter
description: Generate a short, factual monthly activity report across all go-openapi and go-swagger repositories. Use when asked to produce the monthly newsletter/report for a given month, or when run unattended by the monthly-reports routine. The companion to quarterly-newsletter, but concise and autonomous.
---

# Monthly newsletter (go-openapi & go-swagger)

A **short, fact-led** report of the previous calendar month's activity across all
go-openapi and go-swagger repositories. It is the low-effort counterpart to
`quarterly-newsletter`: same scope, shorter window, **no strategy narrative**.

This skill is designed to run **unattended end-to-end** (e.g. from a scheduled cloud
routine). **Never ask the user a question** — if something is ambiguous, make the
conservative choice and report only what is verifiable. Omit, do not invent.

## Window

- The report covers the **previous calendar month**.
- Derive the bounds from today's date — do not hard-code:
  - `--since` = first day of last month, `00:00:00Z`
  - `--until` = first day of the current month, `00:00:00Z`
- Refer to the month in prose by name and year (e.g. "May 2026").

## Output file

- Path: `docs/doc-site/blog/monthly/<YYYY>-<MM>.md` (zero-padded month, e.g. `2026-05.md`).
- Hugo slug → `<YYYY>-<MM>`; published URL → `…/blog/monthly/<YYYY>-<MM>/index.html`.

## Length target

Roughly **a third of a quarterly** — skimmable in about a minute. If in doubt, cut.
Drop the quarterly's impact-assessment essay, risk rating, and long per-repo prose.

## Document structure

### 0. Front matter (Hugo) — two distinct summary fields

```yaml
---
title: May 2026
description: go-openapi & go-swagger activity in May 2026   # plain text — Hugo card text
weight: 797394                                              # 999999 - (YYYY*100 + MM); lower sorts first
discord_description: |-
  <~8-12 line Discord-flavored summary — see below>
---
```

- **`title`** — `<Month> <YYYY>` (e.g. `May 2026`).
- **`description`** — short **plain-text** one/two-liner. Hugo renders it as the page
  meta description and the blog-card text, so keep it free of markup (`•`, `**…**`
  would show literally on the cards).
- **`weight`** — `999999 - (YYYY*100 + MM)`. This sorts newest-first automatically with
  no shared state to maintain (e.g. `2026-05` → `999999 - 202605 = 797394`).
- **`discord_description`** — the rich **~8-12 line** summary, posted verbatim by the
  `announce-monthly.yml` workflow as the Discord embed body. Hugo ignores this custom
  field. Discord embeds render **markdown, not HTML** — use `• ` bullets, `**bold**`
  for repo/product names, `` `code` ``. Lead with one framing sentence, then the
  headline items. **Do not** include the title or the report URL — the workflow adds
  those. Keep it shorter and flatter than the quarterly's.

### 1. Intro (one paragraph)

A single short paragraph framing the month: the overall shape of activity and the one
or two things worth noticing. No grand strategy, no marketing language. State the
**overall effort** inline (e.g. "N commits across M repositories").

### 2. Themes (compact list)

A short bulleted list of the month's cross-cutting themes — group similar changes
across repos rather than listing per-repo. Typical buckets: features, bug fixes,
dependency/CI maintenance, docs, releases. **Keep it to the few themes that actually
mattered this month**; do not pad with boilerplate categories that saw no real change.

### 3. Repository highlights (short table)

A compact table, one row per repo that saw **notable** change (skip repos with only
routine dependabot/CI noise unless that was the whole month):

```markdown
| Repository | Latest release | Highlights |
|---|---|---|
| runtime | v0.30.1 | connection diagnostic; security pass |
```

Do **not** include per-repo commit counts.

### 4. Quarter-overlap note (only in quarter-end months)

If the reported month is the last month of a calendar quarter (Mar, Jun, Sep, Dec),
add a single line pointing readers to the quarterly for the strategic picture, e.g.:
"> A quarterly report covering this period in more depth will follow." Otherwise omit
this section entirely.

### 5. Thanks to our contributors

Close with a short, warm thank-you to the **external human contributors** for the month.

- **Include** anyone who authored a commit in the window across all go-openapi *and*
  go-swagger repos.
- **Exclude**: the maintainer(s) (`fredbi` / `Frédéric BIDON`), AI agents (Claude,
  `Copilot`), and bots (`dependabot[bot]`, `bot-go-openapi[bot]`, `go-openapi-bot`).
- List each by **GitHub handle** and the repo(s) they touched. Never list email
  addresses. Do **not** count individual contributions.
- If there were no external contributors this month, omit the section rather than
  writing an empty thank-you.

## Data collection (cloud environment)

The routine starts with **only `doc-site` checked out**, so prefer the **GitHub API**
over cloning ~18 repos. **All reads must be authenticated** — unauthenticated GitHub
API is 60 req/hour (far too low); authenticated is 5,000 req/hour. The `gh` CLI uses
the `GH_TOKEN` env var automatically.

1. **Enumerate repositories** in both orgs (skip archived repos and forks):
   ```bash
   gh repo list go-openapi --no-archived --source --limit 100 --json name,isArchived,isFork \
     --jq '.[] | select(.isArchived|not) | select(.isFork|not) | .name'
   gh repo list go-swagger  --no-archived --source --limit 100 --json name,isArchived,isFork \
     --jq '.[] | select(.isArchived|not) | select(.isFork|not) | .name'
   ```

2. **Per repo, over the window**, pull what you need via the API (replace `<owner>/<repo>`,
   `<since>`, `<until>`):
   - Commits on the default branch:
     ```bash
     gh api -X GET "repos/<owner>/<repo>/commits" \
       -f since=<since> -f until=<until> --paginate \
       --jq '.[] | {sha:.sha, msg:(.commit.message|split("\n")[0]), login:.author.login, name:.commit.author.name}'
     ```
   - Releases published in the window:
     ```bash
     gh api "repos/<owner>/<repo>/releases" --paginate \
       --jq '.[] | {tag:.tag_name, published:.published_at}'
     ```
   - Latest release tag (for the highlights table). **Do not** use `releases/latest` —
     it returns HTTP 404 for repos with no published release and `gh` leaks the error
     body to stdout. Ask for the newest release (or newest tag) instead, which yields an
     empty array, not a 404:
     ```bash
     tag=$(gh api "repos/<owner>/<repo>/releases?per_page=1" --jq '.[0].tag_name // empty' 2>/dev/null)
     [ -z "$tag" ] && tag=$(gh api "repos/<owner>/<repo>/tags?per_page=1" --jq '.[0].name // empty' 2>/dev/null)
     # repos with neither (e.g. codegen, doc-site) → leave the cell as "—"
     ```
   - Merged PRs in the window (optional, for richer highlights):
     ```bash
     gh api -X GET "search/issues" \
       -f q='repo:<owner>/<repo> is:pr is:merged merged:<since>..<until>' \
       --jq '.items[] | {n:.number, title:.title, user:.user.login}'
     ```

3. **Shallow-clone only if needed** for file-level inspection of one repo:
   `git clone --depth=50 --shallow-since=<since> https://github.com/<owner>/<repo>`.

4. **Contributor handles** come straight from the commit API (`.author.login` above);
   no SHA-to-login mapping needed. Skip null logins (web-flow / unmatched) rather than
   guessing.

5. **Cap and log truncation.** If any repo's history is too large to page fully within
   reason, `log` what was capped rather than silently truncating — a report that hides
   gaps reads as complete when it is not.

## Style

**DO:** factual, developer-focused language; factorize similar changes across repos;
extract latest release tags; keep it short.

**DON'T:** per-repo commit counts; marketing language ("demonstrates maturity"); names
or emails in the themes/highlights (the thanks section is the one place to credit
external contributors, by handle); commit-by-commit logs; subjective praise; questions
to the user.

## After writing

Write the file to `docs/doc-site/blog/monthly/<YYYY>-<MM>.md`. Do **not** post to
Discord and do **not** commit from the skill — the routine handles the commit (via the
GitHub Contents API) and the PR; the Discord announcement happens on merge via
`announce-monthly.yml`.
