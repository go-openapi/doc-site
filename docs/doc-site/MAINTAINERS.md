---
title: Maintainer's Guide
description: Common practices for maintaining go-openapi repositories
weight: 2
---

{{% notice primary "TL;DR" "meteor" %}}
> This guide covers the practices common to all go-openapi repositories:
> CI/CD workflows, release procedures, dependency management, and tooling.
>
> Individual projects may document their repo structure and project-specific details
> in their own `docs/MAINTAINERS.md`.
{{% /notice %}}

## Repo configuration

All go-openapi repositories follow the same baseline configuration:

* Default branch: master
* Protected branches: master
* Branch protection rules:
  * require pull requests and approval
  * required status checks:
    * DCO (simple email sign-off)
    * Lint
    * All tests completed
* Auto-merge enabled (used for dependabot updates and other auto-merged PR's, e.g. contributors update)

## Continuous Integration

### Code Quality checks

* meta-linter: [golangci-lint][golangci-url]
* linter config: `.golangci.yml` at the root of each repository (see our [posture](../contributing/style) on linters)
* Code quality assessment: [CodeFactor][codefactor-url]
* Code quality badges
  * [go report card][gocard-url]
  * [CodeFactor][codefactor-url]

> **NOTES**
>
> codefactor inherits roles from github. There is no need to create a dedicated account.
>
> The codefactor app is installed at the organization level (`github.com/go-openapi`).
>
> There is no special token to setup in github for CI usage.

### Testing

* Test reports
  * Uploaded to codecov: <https://app.codecov.io/analytics/gh/go-openapi>
* Test coverage reports
  * Uploaded to codecov: <https://app.codecov.io/gh/go-openapi>

* Fuzz testing
  * Fuzz tests are handled separately by CI and may reuse a cached version of the fuzzing corpus.
    At this moment, cache may not be shared between feature branches or feature branch and master.
    The minimized corpus produced on failure is uploaded as an artifact and should be added manually
    to `testdata/fuzz/...`.

Coverage threshold status is informative and not blocking.
This is because the thresholds are difficult to tune and codecov oftentimes reports false negatives
or may fail to upload coverage.

All tests across `go-openapi` use our fork of `stretchr/testify`: [`github.com/go-openapi/testify`][testify-url].
This allows for minimal test dependencies.

> **NOTES**
>
> codecov inherits roles from github. There is no need to create a dedicated account.
> However, there is only 1 maintainer allowed to be the admin of the organization on codecov
> with their free plan.
>
> The codecov app is installed at the organization level (`github.com/go-openapi`).
>
> There is no special token to setup in github for CI usage.
> A organization-level token used to upload coverage and test reports is managed at codecov:
> no setup is required on github.

### Automated updates

* dependabot
  * configuration: `.github/dependabot.yaml` in each repository

  Principle:

  * dependabot applies updates and security patches to the github-actions and golang ecosystems.
  * all updates from "trusted" dependencies (github actions, golang.org packages, go-openapi packages)
    are auto-merged if they successfully pass CI.

* go version updates

  Principle:

  * we support the 2 latest minor versions of the go compiler (`stable`, `oldstable`)
  * `go.mod` should be updated (manually) whenever there is a new go minor release
    (e.g. every 6 months).

  > This means that our projects always have a 6 months lag to enforce new features from the go compiler.
  >
  > However, new features of go may be used with a "go:build" tag: this allows users of the newer
  > version to benefit the new feature while users still running with `oldstable` use another version
  > that still builds.

* contributors
  * a `CONTRIBUTORS.md` file is updated weekly, with all-time contributors to the repository
  * the `github-actions[bot]` posts a pull request to do that automatically
  * at this moment, this pull request is not auto-approved/auto-merged (bot cannot approve its own PRs)

### Vulnerability scanners

There are 3 complementary scanners - obviously, there is some overlap, but each has a different focus.

* GitHub `CodeQL` <https://github.com/github/codeql>
* `trivy` <https://trivy.dev/docs/latest/getting-started>
* `govulncheck` <https://go.dev/blog/govulncheck>

None of these tools require an additional account or token.

Github CodeQL configuration is set to "Advanced", so we may collect a CI status for this check (e.g. for badges).

Scanners run on every commit to master and at least once a week.

Reports are centralized in github security reports for code scanning tools.

## Releases

### Single module repos

A bump release workflow can be triggered from the github actions UI to cut a release with a few clicks.

The release process is minimalist:

* push a semver tag (i.e v{major}.{minor}.{patch}) to the master branch.
* the CI handles this to generate a github release with release notes

* release notes generator: git-cliff <https://git-cliff.org/docs/>
* configuration: the `.cliff.toml` is defined as a shared configuration on
  remote repo [`ci-workflows/.cliff.toml`][remote-cliff-config]

Commits from maintainers are preferably PGP-signed.

Tags are preferably PGP-signed.

We want our releases to show as "verified" on github.

The tag message introduces the release notes (e.g. a summary of this release).

The release notes generator does not assume that commits are necessarily "conventional commits".

### Mono-repos with multiple modules

The release process is slightly different because we need to update cross-module dependencies
before pushing a tag.

A bump release workflow (mono-repo) can be triggered from the github actions UI to cut a release with a few clicks.

It works with the same input as the one for single module repos, and first creates a PR (auto-merged)
that updates the different go.mod files _before_ pushing the desired git tag.

Commits and tags pushed by the workflow bot are PGP-signed ("go-openapi[bot]").

## Standard documentation files

Every go-openapi repository should include:

* [CONTRIBUTING.md](../contributing/contributing) guidelines
* [DCO.md](../contributing/dco) terms for first-time contributors to read
* [CODE_OF_CONDUCT.md](../contributing/code_of_conduct)
* [SECURITY.md](../SECURITY) policy: how to report vulnerabilities privately
* [LICENSE](../LICENSE) terms
* NOTICE on supplementary license terms (when applicable: original authors, copied code etc)

Reference documentation (released):

* [pkg.go.dev](https://pkg.go.dev/github.com/go-openapi) for all go-openapi packages

[golangci-url]: https://golangci-lint.run/
[codefactor-url]: https://www.codefactor.io/overview
[gocard-url]: https://goreportcard.com/
[remote-cliff-config]: https://github.com/go-openapi/ci-workflows/blob/master/.cliff.toml
[testify-url]: https://github.com/go-openapi/testify
