# go-openapi/doc-site

Shared documentation for the [go-openapi](https://github.com/go-openapi) organization.

This repository is the single source of truth for common project documentation:
contributing guidelines, coding style, security policy, licensing, and code of conduct.

## Published site

**https://go-openapi.github.io/doc-site/**

## What's here

| Document | Description |
|----------|-------------|
| [Contributing](docs/doc-site/contributing/CONTRIBUTING.md) | How to contribute to go-openapi projects |
| [Coding Style](docs/doc-site/contributing/STYLE.md) | Linting and code quality stance |
| [Code of Conduct](docs/doc-site/contributing/CODE_OF_CONDUCT.md) | Contributor Covenant |
| [DCO](docs/doc-site/contributing/DCO.md) | Developer Certificate of Origin |
| [Security](docs/doc-site/SECURITY.md) | Vulnerability reporting policy |
| [License](docs/doc-site/LICENSE.md) | Apache-2.0 |

## Local development

```bash
cd hack/doc-site/hugo
go run gendoc.go
# Visit http://localhost:1313/doc-site/
```

Requires Hugo and the Relearn theme extracted at `hack/doc-site/hugo/themes/hugo-relearn/`.

## Linking from other repositories

Other go-openapi projects can link to these shared docs instead of duplicating them:

```markdown
See the [contributing guidelines](https://go-openapi.github.io/doc-site/contributing/contributing).
```

## License

Apache-2.0
