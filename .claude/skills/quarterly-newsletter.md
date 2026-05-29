---
name: go-openapi-changes-summary
description: Generate qualitative monthly summaries of changes across go-openapi repositories. Use when the user asks to summarize repository changes, create a monthly report, or analyze what has changed in go-openapi repositories over a time period.
---

# Go-OpenAPI Changes Summary

This skill provides a framework for creating factual, developer-focused monthly summaries of changes across multiple go-openapi repositories.

## Output Format

Create a markdown document with the following structure:

### 1. Header
```markdown
# Go-OpenAPI Organization Summary

**Overall effort:** [total commits] commits across [N] repositories
```

### 2. Key Themes & Improvements
Identify and factorize common patterns across all repositories. Group similar changes under themes such as:
- CI/CD Infrastructure (workflow updates, automation)
- Documentation (CONTRIBUTING, SECURITY, README improvements)
- Dependency Management (dependabot updates, version bumps)
- Code Quality & Linting (golangci-lint updates, code cleanup)
- Testing (test improvements, coverage, new test types)
- Licensing & Legal (license headers, NOTICE files)

For each theme:
- List which repositories were affected
- Describe common changes across repositories
- Note repository-specific variations where relevant
- Avoid repeating similar changes for each repo

### 3. Impact Assessment
Provide factual assessment of:
- **Organizational Consistency**: Changes to infrastructure/governance
- **Automation & Efficiency**: CI/CD improvements
- **Security**: Security scanning, dependency updates
- **Contributor Experience**: Documentation improvements
- **Code Quality**: Linting, testing improvements
- **Release Management**: Release automation changes
- **Risk Level**: Low/Medium/High with justification

### 4. Repository-Specific Highlights
For each repository, include:
```markdown
### [repo-name] ([latest-tag])
**Status:** [Brief status description]
- [Key specific changes]
- [Notable highlights]
```

Order repositories by significance of changes or alphabetically.

### 5. Summary
Concise summary (2-3 paragraphs) covering:
- Main pillars of work (Infrastructure, Governance, Quality, etc.)
- Whether breaking changes or feature work occurred
- Overall nature of the effort (coordinated vs. ad-hoc)

### 6. Thanks to Our Contributors
Close with a short, warm thank-you note acknowledging the **external human contributors** for the period. This list is intentionally small but matters — these are community members, not maintainers or automation.

- **Include** anyone who authored a commit in the window across all go-openapi *and* go-swagger repositories.
- **Exclude**: the maintainer(s) (e.g. `fredbi` / `Frederic BIDON`), AI agents (Claude, `Copilot`), and bots (`dependabot[bot]`, `bot-go-openapi[bot]`).
- For **each** contributor, list their GitHub handle and the repo(s) they touched (most community contributions land on go-swagger, the user-facing tool).
- Do **not** count individual contributions — a handful of fixes is dwarfed by the bot/maintainer commit volume, so counts would misrepresent. Just thank them by name.
- Keep the tone warm and genuine, not promotional.

## Style Guidelines

**DO:**
- Use factual, developer-focused language
- Factorize similar changes across repositories
- Include specific examples and details
- Focus on qualitative assessment over statistics
- Include overall commit count at the top
- Extract and display latest release tags for each repo

**DON'T:**
- Include per-repository commit counts
- Use marketing language ("demonstrates leadership", "represents maturity")
- Include contributor names or email addresses in the body of the themes (the final "Thanks to Our Contributors" section is the one place to credit external contributors — by GitHub handle, never by email)
- Repeat similar changes for each repository individually
- Include detailed commit-by-commit logs
- Add subjective praise or promotional language

## Data Collection

To analyze repositories:

1. Extract repository archives if provided
2. Configure git safe directories:
   ```bash
   for repo in [repo-list]; do 
     git config --global --add safe.directory /path/to/$repo
   done
   ```

3. Collect data for each repository:
   - Commit messages: `git log --since="1 month ago" --pretty=format:"%s"`
   - Files changed: `git log --since="1 month ago" --name-only --pretty=format: | sort -u`
   - Latest tag: `git describe --tags --abbrev=0`
   - Authors: `git log <default-branch> --since=<date> --no-merges --pretty=format:'%an%x09%ae'` — count on the *default* branch (`git rev-parse --abbrev-ref origin/HEAD`), not local HEAD

4. Calculate total commits across all repos

5. Resolve contributor GitHub handles for the thank-you section. Git author names are not GitHub usernames. For `…@users.noreply.github.com` emails the handle is embedded (`<id>+<handle>@…`). Otherwise map a sample commit SHA to its GitHub login:
   ```bash
   gh api repos/<owner>/<repo>/commits/<sha> --jq '.author.login'
   ```

5. Categorize commits by type (CI, deps, docs, tests, lint, etc.)

## Analysis Process

1. **Identify Common Patterns**: Look for the same commit messages, file changes, or workflows across multiple repositories

2. **Group by Theme**: Organize changes into logical themes rather than repository-by-repository

3. **Extract Repository-Specific Changes**: Note what's unique to each repository

4. **Determine Impact**: Assess the practical impact of changes on users, contributors, and maintainers

5. **Synthesize Summary**: Create a narrative that explains the coordinated effort (if any)

## Example Theme Structure

```markdown
### 1. **CI/CD Infrastructure Modernization (Organization-Wide)**
A systematic effort to modernize CI/CD infrastructure across repositories.

**Affected repositories:** analysis, jsonpointer, jsonreference, loads (4/8 repos)

**Common changes across repositories:**
- Added `bump-release.yml` workflow for automated versioning
- Added `codeql.yml` for security scanning
- Updated `go-test.yml` to use shared workflows

**Repository-specific enhancements:**
- **jsonpointer**: Added fuzz testing workflow
- **analysis**: Enhanced coverage reporting
```

## Technical Notes

- Time period is typically "1 month ago" but can be adjusted based on user request
- If repositories are on GitHub and accessible, can fetch directly; otherwise work with uploaded archives
- Git commands should handle missing repositories gracefully
- When counting commits, use: `git log --since="1 month ago" --oneline | wc -l`
