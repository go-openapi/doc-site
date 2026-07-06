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

The routine starts with **only `doc-site` checked out**. **Do not** try to use the
GitHub REST API (`gh api`, `curl https://api.github.com/...`) or `gh repo list`: in the
scheduled cloud sandbox the egress proxy binds the session to a single repository, so
**every `api.github.com`, `github.com`, and `codeload.github.com` request returns HTTP
403** — including *unauthenticated public reads* and the org-listing / GraphQL endpoints
`gh repo list` depends on. A token does not help; the block is at the network layer.

What the proxy **does** allow, and what this routine relies on:

- the **git smart-HTTP protocol** — `git clone`, `git ls-remote`, `git fetch` — against
  any public repo (and the `fredbi/doc-site` fork), and
- **`raw.githubusercontent.com`** (single-file reads).

Public repos need **no token** for git reads. So collect everything from **shallow git
clones** rather than the API. Work in a scratch dir, not the `doc-site` checkout.

1. **Enumerate repositories.** The org-listing API is blocked, so build the repo set from
   readable sources and validate it with `git ls-remote` (skip archived repos and forks —
   forks are absent from these orgs in practice; dormant repos fall out naturally in step 2):
   - **Libraries** — union of `github.com/go-openapi/*` module paths found in a few
     `go.mod` files (fetch via raw; go-swagger's `go.mod` pulls in most of them):
     ```bash
     for m in go-swagger/go-swagger go-openapi/runtime go-openapi/validate go-openapi/strfmt; do
       curl -sS "https://raw.githubusercontent.com/$m/master/go.mod"
     done | grep -oE 'go-openapi/[a-z0-9-]+' | sort -u
     ```
   - **Non-module repos** — add the known infra/tooling/example repos not referenced by any
     `go.mod`: `go-openapi/{doc-site,ci-workflows,.github,codescan,kvstore,stubs,swaggersocket}`
     and `go-swagger/{go-swagger,examples,scan-repo-boundary}`.
   - **Validate** each candidate exists and is reachable (drop the misses):
     ```bash
     git ls-remote "https://github.com/<owner>/<repo>" HEAD >/dev/null 2>&1 && echo "<owner>/<repo>"
     ```

2. **Per repo, clone shallow over the window** (start a few days *before* `<since>` so the
   first in-window commit is included; `--no-checkout --filter=blob:none` keeps it cheap —
   we only need history, not trees):
   ```bash
   git clone -q --no-checkout --filter=blob:none --shallow-since=<since-minus-a-week> \
     "https://github.com/<owner>/<repo>" "<dir>"
   ```
   - **Commits in the window** (author name, email, subject):
     ```bash
     git -C <dir> log --since=<since> --until=<until> --pretty='%an%x09%ae%x09%s'
     ```
     A repo whose newest commit predates `--shallow-since` **fails to clone** — that just
     means zero activity in the window. Confirm dormancy if unsure with a
     `git clone --depth=1` and `git -C <dir> log -1 --pretty=%ci`.
   - **Releases in the window** and **latest release tag** (for the highlights table) from
     tags — no Releases API needed:
     ```bash
     # tags whose commit date lands in the window:
     git -C <dir> for-each-ref --format='%(refname:short) %(creatordate:short)' refs/tags \
       | awk '$2>="<yyyy-mm-01>" && $2<"<next-month-01>"'
     # newest semver release tag (ignores per-submodule path tags):
     git -C <dir> ls-remote --tags origin | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
     ```
     Repos with no version tag (e.g. `doc-site`, `.github`) → leave the cell as "—".
   - **Merged-PR numbers** (optional, for richer highlights) are embedded in squashed commit
     subjects as `(#NNN)` — extract them from the `%s` output rather than the search API.

3. **Contributor handles without the API.** Git carries author *name + email*, not the
   GitHub login, so recover the handle from what git *does* have — never guess, never list
   an email:
   - **GitHub noreply emails** encode the login: `NNN+<login>@users.noreply.github.com`
     → `<login>`.
   - **`Signed-off-by:` / `Co-authored-by:` trailers** in the full commit body
     (`git log --pretty='%an%x09%s%x09%b'`) frequently carry the handle.
   - If a contributor's handle can't be derived from either (author used a plain email and
     no trailer names them), **omit them** from the thanks section rather than guessing or
     printing a display name — and `log` the omission so the gap is visible.

4. **Cap and log truncation.** If any repo's history is too large to page fully within
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
Discord and do **not** commit from the skill — the routine handles the commit and the PR;
the Discord announcement happens on merge via `announce-monthly.yml`.

**Publishing note (same sandbox constraint).** Because `api.github.com` is blocked, the
routine's original `gh api .../contents/...` Contents-API path to the `fredbi/doc-site`
fork does **not** work, and a plain `git push` from the sandbox produces an *unsigned*
commit attributed to the proxy identity — which the contribution rules forbid. The
working path is the **in-scope GitHub MCP server** (`go-openapi/doc-site` only), which
reaches the Contents API server-side and yields a GitHub-Verified, token-owner-authored
commit: create a `claude/monthly-<YM>` branch, `create_or_update_file` the report onto it
(sign the message off as the maintainer), then open the PR on `go-openapi/doc-site` with
`base=master head=claude/monthly-<YM>`. This is a same-repo branch PR, not a cross-fork
one. Record any such deviation (branch-on-upstream vs fork, git-derived data vs API) in
the PR body so reviewers know how the run was produced.
