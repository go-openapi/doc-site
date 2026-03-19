//go:build ignore

// Local development script for Hugo documentation.
//
// Usage: go run gendoc.go
//
// Requires:
// * hugo
// * git
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

//nolint:forbidigo,dogsled
func main() {
	ctx := context.Background()

	// Change to the directory containing this script.
	_, thisFile, _, _ := runtime.Caller(0)
	scriptDir := filepath.Dir(thisFile)
	if err := os.Chdir(scriptDir); err != nil {
		fatalf("chdir: %v", err)
	}

	fmt.Println("==> Preparing Hugo documentation site...")

	buildTime := time.Now().UTC().Format("2006-01-02T15:04:05Z")
	fmt.Printf("    Build time: %s\n", buildTime)

	// Generate dynamic config from template.
	generateDocsiteYAML(buildTime)
	fmt.Println("==> Generated docsite.yaml")

	// Check if theme exists.
	if _, err := os.Stat("themes/hugo-relearn"); os.IsNotExist(err) {
		fatalf("Relearn theme not found at themes/hugo-relearn\n" +
			"Download from https://github.com/McShelby/hugo-theme-relearn/releases and extract to themes/hugo-relearn")
	}

	// Check if content docs exist.
	if _, err := os.Stat("../../../docs/doc-site"); os.IsNotExist(err) {
		fmt.Println("WARNING: Content not found at ../../../docs/doc-site")
		fmt.Println()
		fmt.Println("Creating placeholder content directory...")
		os.MkdirAll("content", 0o755) //nolint:errcheck,mnd
	}

	fmt.Println("==> Starting Hugo development server...")
	fmt.Println("    Visit: http://localhost:1313/doc-site/")
	fmt.Println()

	// Start Hugo server with both configs.
	cmd := exec.CommandContext(ctx, "hugo", "server",
		"--config", "hugo.yaml,docsite.yaml",
		"--buildDrafts",
		"--disableFastRender",
		"--navigateToChanged",
		"--bind", "0.0.0.0",
		"--port", "1313",
		"--baseURL", "http://localhost:1313/doc-site/",
		"--appendPort=false",
		"--logLevel", "info",
		"--cleanDestinationDir",
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	if err := cmd.Run(); err != nil {
		fatalf("hugo: %v", err)
	}
}

// generateDocsiteYAML reads the template and writes docsite.yaml with substitutions.
func generateDocsiteYAML(buildTime string) {
	tmpl, err := os.ReadFile("docsite.yaml.template")
	if err != nil {
		fatalf("reading template: %v", err)
	}

	out := string(tmpl)
	out = strings.ReplaceAll(out, "{{ BUILD_TIME }}", buildTime)

	if err := os.WriteFile("docsite.yaml", []byte(out), 0o600); err != nil { //nolint:mnd
		fatalf("writing docsite.yaml: %v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "ERROR: "+format+"\n", args...)
	os.Exit(1)
}
