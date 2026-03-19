# Hugo Documentation Site

This directory contains the Hugo configuration for the go-openapi shared documentation site.

## Structure

```
hugo/
├── hugo.yaml                   # Main Hugo configuration
├── docsite.yaml.template       # Dynamic config template (build time info)
├── gendoc.go                   # Local development server (go run gendoc.go)
├── themes/
│   ├── hugo-relearn/           # Relearn theme (extracted from release archive)
│   ├── go-openapi-assets/      # Custom assets (logo, favicon)
│   └── go-openapi-static/      # Static files
└── layouts/                    # Custom layouts (override theme)
    ├── shortcodes/             # Custom Hugo shortcodes
    └── partials/               # Custom partial templates
```

## Content

Documentation content lives in:
```
../../../docs/doc-site/
```

This directory is mounted as Hugo's content directory via module mounts in `hugo.yaml`.

## Local Development

```bash
# First, ensure the Relearn theme is available at themes/hugo-relearn/
# Download from https://github.com/McShelby/hugo-theme-relearn/releases

# Run local Hugo server
go run gendoc.go

# Site will be available at:
# http://localhost:1313/doc-site/
```

The `gendoc.go` program:
1. Generates `docsite.yaml` from template with build timestamp
2. Starts Hugo server with both config files
3. Enables live reload and draft content

## Theme

Uses **Hugo Relearn** theme (dark variant) following go-swagger patterns.

Theme customizations:
- Branding assets in `themes/go-openapi-assets/`
- Static files in `themes/go-openapi-static/`
- Layout overrides in `layouts/`

## Configuration

Two-layer config:

1. **hugo.yaml** - Static configuration (theme, structure, parameters)
2. **docsite.yaml** - Dynamic configuration (build time), generated from template

## Deployment

GitHub Pages deployment via `.github/workflows/update-doc.yml`:
- Builds on push to `master` or changes to `docs/` and `hack/`
- Publishes to: https://go-openapi.github.io/doc-site/
