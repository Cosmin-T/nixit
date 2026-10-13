//go:build linux

package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// insightSystemRoot prefixes the system-wide insight paths; tests point it at a
// temp directory.
var insightSystemRoot = "/"

// createInsightEntries returns the list of hidden-space insight entries
// to show in the overview screen alongside the standard directory entries.
func createInsightEntries() []dirEntry {
	home := os.Getenv("HOME")
	if home == "" {
		return nil
	}

	var entries []dirEntry

	// Old Downloads: ~/Downloads (files older than 90 days)
	downloadsPath := filepath.Join(home, "Downloads")
	if info, err := os.Stat(downloadsPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:  "Old Downloads (90d+)",
			Path:  downloadsPath,
			IsDir: true,
			Size:  -1,
		})
	}

	// Cleanable paths: things nixit clean can remove or the user can safely delete.
	// ~/.cache itself is intentionally omitted here because the specific cache
	// subdirectories below are already its children; listing both would
	// double-count the same bytes.
	cleanablePaths := []struct {
		name string
		path string
	}{
		{"Pacman Cache", filepath.Join(insightSystemRoot, "var", "cache", "pacman", "pkg")},
		{"System Journal", filepath.Join(insightSystemRoot, "var", "log", "journal")},
		{"Core Dumps", filepath.Join(insightSystemRoot, "var", "lib", "systemd", "coredump")},
		{"Trash", filepath.Join(home, ".local", "share", "Trash")},
		{"yay Cache", filepath.Join(home, ".cache", "yay")},
		{"paru Cache", filepath.Join(home, ".cache", "paru")},
		{"Thumbnails", filepath.Join(home, ".cache", "thumbnails")},
		{"Flatpak Data", filepath.Join(insightSystemRoot, "var", "lib", "flatpak")},
		{"Steam Shader Cache", filepath.Join(home, ".local", "share", "Steam", "steamapps", "shadercache")},

		// Developer-specific (only shown if path exists)
		{"JetBrains Cache", filepath.Join(home, ".cache", "JetBrains")},
		{"Docker Data", filepath.Join(insightSystemRoot, "var", "lib", "docker")},
		{"pip Cache", filepath.Join(home, ".cache", "pip")},
		{"uv Cache", filepath.Join(home, ".cache", "uv")},
		{"Go Build Cache", filepath.Join(home, ".cache", "go-build")},
		{"Cargo Registry", filepath.Join(home, ".cargo", "registry")},
		{"npm Cache", filepath.Join(home, ".npm", "_cacache")},
		{"Gradle Cache", filepath.Join(home, ".gradle", "caches")},
	}
	for _, c := range cleanablePaths {
		if info, err := os.Stat(c.path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{
				Name:  c.name,
				Path:  c.path,
				IsDir: true,
				Size:  -1,
			})
		}
	}

	return entries
}

// measureInsightSize measures the size of a path.
// Old Downloads is treated specially: only files older than 90 days are counted.
func measureInsightSize(ctx context.Context, path string) (int64, error) {
	return measureInsightSizeWithPublication(ctx, path, nil)
}

func measureInsightSizeWithPublication(ctx context.Context, path string, publication *scanPublication) (int64, error) {
	home := os.Getenv("HOME")

	if home != "" && path == filepath.Join(home, "Downloads") {
		return measureOldDownloads(ctx, path, 90)
	}

	return measureOverviewSizeWithPublication(ctx, path, publication)
}

// measureOldDownloads calculates total size of files in a directory
// that haven't been modified in the given number of days.
func measureOldDownloads(ctx context.Context, dir string, daysOld int) (int64, error) {
	ctx, cancel := context.WithTimeout(ctx, duTimeout)
	defer cancel()
	var failures scanFailures
	cutoff := time.Now().AddDate(0, 0, -daysOld)
	var total int64

	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}

	for _, entry := range entries {
		if ctx.Err() != nil {
			failures.record(ctx.Err())
			break
		}
		// Skip hidden files.
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			failures.record(err)
			continue
		}

		if info.ModTime().Before(cutoff) {
			if entry.IsDir() {
				// Use du for directories.
				size, err := getDirectorySizeFromDu(ctx, filepath.Join(dir, entry.Name()))
				failures.record(err)
				total += size
			} else {
				total += info.Size()
			}
		}
	}

	return total, failures.first
}
