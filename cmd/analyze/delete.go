//go:build linux

package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"golang.org/x/sys/unix"
)

const trashTimeout = 30 * time.Second

// gioBinary is GLib's gio(1), which implements the freedesktop.org Trash spec
// for every mount (home trash, $topdir/.Trash-$uid, and so on). It is invoked by
// absolute path so a "gio" shadowed earlier in PATH never receives a delete.
const gioBinary = "/usr/bin/gio"

func deletePathCmd(path string, counter *int64) tea.Cmd {
	return func() tea.Msg {
		count, err := trashPathWithProgress(path, counter)
		return deleteProgressMsg{
			done:  true,
			err:   err,
			count: count,
			path:  path,
		}
	}
}

// deleteMultiplePathsCmd moves paths to Trash and aggregates results.
func deleteMultiplePathsCmd(paths []string, counter *int64) tea.Cmd {
	return func() tea.Msg {
		var totalCount int64
		var errors []string
		var removedPaths []string

		// Process deeper paths first to avoid parent/child conflicts.
		pathsToDelete := append([]string(nil), paths...)
		sort.Slice(pathsToDelete, func(i, j int) bool {
			return strings.Count(pathsToDelete[i], string(filepath.Separator)) > strings.Count(pathsToDelete[j], string(filepath.Separator))
		})

		for _, path := range pathsToDelete {
			count, err := trashPathWithProgress(path, counter)
			totalCount += count
			if err != nil {
				if os.IsNotExist(err) {
					removedPaths = append(removedPaths, path)
					continue
				}
				errors = append(errors, err.Error())
				continue
			}
			removedPaths = append(removedPaths, path)
		}

		var resultErr error
		if len(errors) > 0 {
			resultErr = &multiDeleteError{errors: errors}
		}

		return deleteProgressMsg{
			done:         true,
			err:          resultErr,
			count:        totalCount,
			path:         "",
			removedPaths: removedPaths,
		}
	}
}

// multiDeleteError holds multiple deletion errors.
type multiDeleteError struct {
	errors []string
}

func (e *multiDeleteError) Error() string {
	if len(e.errors) == 1 {
		return e.errors[0]
	}
	return strings.Join(e.errors[:min(3, len(e.errors))], "; ")
}

// trashPathWithProgress moves one selected path to Trash and reports completion.
func trashPathWithProgress(root string, counter *int64) (int64, error) {
	// Verify path exists (use Lstat to handle broken symlinks).
	_, err := os.Lstat(root)
	if err != nil {
		return 0, err
	}

	// Trash moves one selected path as a unit. Recursively counting every file
	// first made large directory deletes appear hung before the move began.
	const count int64 = 1

	// Move through a headless Trash route, with Finder as the last compatibility fallback.
	if err := moveToTrash(root); err != nil {
		return 0, err
	}
	if counter != nil {
		atomic.AddInt64(counter, count)
	}

	return count, nil
}

// moveToTrash moves a file/directory to the freedesktop.org Trash. gio(1)
// handles every mount; without it, a built-in mover handles paths on the same
// filesystem as the home Trash.
func moveToTrash(path string) error {
	// Validate raw input before Abs resolves ".." components away.
	if err := validateTrashTarget(path); err != nil {
		return err
	}

	absPath, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("failed to resolve path: %w", err)
	}

	// Validate resolved path as well (defense-in-depth).
	if err := validateTrashTarget(absPath); err != nil {
		return err
	}

	gioErr := fmt.Errorf("gio is not installed")
	if _, statErr := os.Stat(gioBinary); statErr == nil {
		if gioErr = moveToTrashViaGio(absPath); gioErr == nil {
			return nil
		}
	}
	// gio refuses some mounts (tmpfs, for one); the home Trash still accepts
	// anything on its own filesystem.
	if fsErr := moveToTrashViaFilesystem(absPath); fsErr == nil {
		return nil
	}
	return gioErr
}

// moveToTrashViaGio moves absPath to Trash using gio(1).
func moveToTrashViaGio(absPath string) error {
	ctx, cancel := context.WithTimeout(context.Background(), trashTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, gioBinary, "trash", "--", absPath)
	output, err := cmd.CombinedOutput()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return fmt.Errorf("timeout moving to Trash")
		}
		return fmt.Errorf("failed to move to Trash: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

// moveToTrashViaFilesystem implements the home-Trash half of the freedesktop.org
// Trash spec. The .trashinfo file is created with O_EXCL to reserve the name, and
// the move uses renameat2(RENAME_NOREPLACE), so a concurrent name collision can
// never overwrite an existing Trash item.
func moveToTrashViaFilesystem(absPath string) error {
	trashDir, err := homeTrashDirectory()
	if err != nil {
		return err
	}
	filesDir := filepath.Join(trashDir, "files")
	infoDir := filepath.Join(trashDir, "info")
	for _, dir := range []string{trashDir, filesDir, infoDir} {
		if err := ensureOwnedTrashDirectory(dir, true); err != nil {
			return err
		}
	}

	var pathFS, trashFS unix.Stat_t
	if err := unix.Lstat(absPath, &pathFS); err != nil {
		return fmt.Errorf("failed to inspect target: %w", err)
	}
	if err := unix.Stat(filesDir, &trashFS); err != nil {
		return fmt.Errorf("failed to inspect Trash: %w", err)
	}
	if pathFS.Dev != trashFS.Dev {
		return fmt.Errorf("%s is on another filesystem; install glib2 (gio) to trash it", absPath)
	}

	base := filepath.Base(absPath)
	if base == "." || base == string(filepath.Separator) || base == "" {
		return fmt.Errorf("invalid Trash item name")
	}

	info := fmt.Sprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n",
		(&url.URL{Path: absPath}).EscapedPath(), time.Now().Format("2006-01-02T15:04:05"))

	stamp := time.Now().UnixNano()
	for attempt := range 100 {
		name := base
		if attempt > 0 {
			name = fmt.Sprintf("%s.%d.%d.%d", base, stamp, os.Getpid(), attempt)
		}
		infoPath := filepath.Join(infoDir, name+".trashinfo")
		f, err := os.OpenFile(infoPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			if os.IsExist(err) {
				continue
			}
			return fmt.Errorf("failed to write Trash info: %w", err)
		}
		_, writeErr := f.WriteString(info)
		closeErr := f.Close()
		if writeErr != nil || closeErr != nil {
			_ = os.Remove(infoPath)
			return fmt.Errorf("failed to write Trash info")
		}

		dest := filepath.Join(filesDir, name)
		err = unix.Renameat2(unix.AT_FDCWD, absPath, unix.AT_FDCWD, dest, unix.RENAME_NOREPLACE)
		if err == nil {
			return nil
		}
		_ = os.Remove(infoPath)
		if err != syscall.EEXIST {
			return fmt.Errorf("failed to move to Trash: %w", err)
		}
	}

	return fmt.Errorf("failed to choose unique Trash destination for %s", absPath)
}

// homeTrashDirectory returns $XDG_DATA_HOME/Trash (default ~/.local/share/Trash).
func homeTrashDirectory() (string, error) {
	if dataHome := os.Getenv("XDG_DATA_HOME"); filepath.IsAbs(dataHome) {
		return filepath.Join(dataHome, "Trash"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to resolve home directory: %w", err)
	}
	return filepath.Join(home, ".local", "share", "Trash"), nil
}

func ensureOwnedTrashDirectory(path string, create bool) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) && create {
		if err := os.MkdirAll(path, 0o700); err != nil {
			return fmt.Errorf("failed to create Trash directory: %w", err)
		}
		info, err = os.Lstat(path)
	}
	if err != nil {
		return fmt.Errorf("failed to inspect Trash directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("trash path is not a normal directory")
	}

	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Getuid()) {
		return fmt.Errorf("trash directory is not owned by the current user")
	}
	if info.Mode().Perm()&0o022 != 0 {
		return fmt.Errorf("trash directory is writable by another user")
	}
	return nil
}

func validateTrashTarget(path string) error {
	if err := validatePath(path); err != nil {
		return err
	}
	if isProtectedAnalyzeDeletePath(path) {
		return fmt.Errorf("protected path cannot be deleted: %s", path)
	}
	if resolvedPath, err := filepath.EvalSymlinks(path); err == nil && isProtectedAnalyzeDeletePath(resolvedPath) {
		return fmt.Errorf("protected path cannot be deleted: %s", path)
	}
	return nil
}

func isProtectedAnalyzeDeletePath(path string) bool {
	if path == "" {
		return false
	}

	cleanPath := filepath.Clean(path)

	if isCriticalAnalyzeDeletePath(cleanPath) {
		return true
	}

	for _, homeRoot := range protectedAnalyzeHomeRoots() {
		if cleanPath == homeRoot || isSameExistingPath(cleanPath, homeRoot) {
			return true
		}
	}
	return false
}

func isCriticalAnalyzeDeletePath(path string) bool {
	criticalRoots := []string{
		"/",
		"/boot",
		"/efi",
		"/dev",
		"/etc",
		"/home",
		"/lib",
		"/lib64",
		"/mnt",
		"/media",
		"/opt",
		"/proc",
		"/root",
		"/run",
		"/run/media",
		"/srv",
		"/sys",
		"/tmp",
		"/var",
		"/var/lib",
		"/var/cache",
		"/var/log",
		"/var/tmp",
		"/bin",
		"/sbin",
		"/usr",
	}
	for _, root := range criticalRoots {
		if path == root || isSameExistingPath(path, root) {
			return true
		}
	}

	// A child directly under /home is another account's home root, not an
	// ordinary directory. Protect every account root while keeping its
	// descendants available to the owning user.
	if isDirectChildOfExistingRoot(path, "/home") {
		return true
	}

	// These system-owned trees are never an Analyze cleanup surface, even when
	// a caller starts inside one instead of selecting its top-level row.
	// Package-manager state lives under /usr, /etc and /var/lib; removing files
	// there behind pacman's back breaks the system.
	protectedTrees := []string{
		"/boot",
		"/efi",
		"/bin",
		"/sbin",
		"/lib",
		"/lib64",
		"/usr",
		"/etc",
		"/dev",
		"/proc",
		"/sys",
		"/run",
		"/var/lib",
	}
	for _, root := range protectedTrees {
		if strings.HasPrefix(path, root+string(filepath.Separator)) ||
			isPathWithinExistingRoot(path, root) {
			return true
		}
	}
	return false
}

func protectedAnalyzeHomeRoots() []string {
	var homeRoots []string
	seenHomeRoots := make(map[string]bool)
	addHomeRoot := func(home string) {
		if home == "" {
			return
		}
		cleanHome := filepath.Clean(home)
		if !seenHomeRoots[cleanHome] {
			homeRoots = append(homeRoots, cleanHome)
			seenHomeRoots[cleanHome] = true
		}
		if resolvedHome, err := filepath.EvalSymlinks(cleanHome); err == nil && !seenHomeRoots[resolvedHome] {
			homeRoots = append(homeRoots, resolvedHome)
			seenHomeRoots[resolvedHome] = true
		}
	}

	addHomeRoot(os.Getenv("HOME"))
	if currentUser, err := user.Current(); err == nil {
		addHomeRoot(currentUser.HomeDir)
	}
	return homeRoots
}

func isPathWithinExistingRoot(path, protectedRoot string) bool {
	protectedInfo, err := os.Stat(protectedRoot)
	if err != nil {
		return false
	}

	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		if currentInfo, err := os.Stat(current); err == nil && os.SameFile(currentInfo, protectedInfo) {
			return true
		}
		parent := filepath.Dir(current)
		if parent == current {
			return false
		}
	}
}

func isSameExistingPath(path, protectedPath string) bool {
	pathInfo, pathErr := os.Stat(path)
	protectedInfo, protectedErr := os.Stat(protectedPath)
	return pathErr == nil && protectedErr == nil && os.SameFile(pathInfo, protectedInfo)
}

func isDirectChildOfExistingRoot(path, protectedRoot string) bool {
	cleanPath := filepath.Clean(path)
	return cleanPath != filepath.Clean(protectedRoot) &&
		filepath.Dir(cleanPath) != cleanPath &&
		isSameExistingPath(filepath.Dir(cleanPath), protectedRoot)
}

// validatePath checks path safety for external commands.
// Returns error if path is empty, relative, contains null bytes, or has traversal.
func validatePath(path string) error {
	if path == "" {
		return fmt.Errorf("path is empty")
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("path must be absolute: %s", path)
	}
	if strings.Contains(path, "\x00") {
		return fmt.Errorf("path contains null bytes")
	}
	// Check for path traversal attempts (.. components).
	if slices.Contains(strings.Split(path, string(filepath.Separator)), "..") {
		return fmt.Errorf("path contains traversal components: %s", path)
	}
	return nil
}
