//go:build linux

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// useTempTrash points the freedesktop.org home Trash at a temp directory on the
// same filesystem as the test files, so no test touches the real Trash.
func useTempTrash(t *testing.T) (root, trashDir string) {
	t.Helper()
	root = t.TempDir()
	dataHome := filepath.Join(root, "data")
	if err := os.MkdirAll(dataHome, 0o700); err != nil {
		t.Fatalf("create data home: %v", err)
	}
	t.Setenv("XDG_DATA_HOME", dataHome)
	return root, filepath.Join(dataHome, "Trash")
}

func TestTrashPathWithProgress(t *testing.T) {
	root, _ := useTempTrash(t)
	target := filepath.Join(root, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	for _, f := range []string{"one.txt", "two.txt"} {
		if err := os.WriteFile(filepath.Join(target, f), []byte("content"), 0o644); err != nil {
			t.Fatalf("write %s: %v", f, err)
		}
	}

	var counter int64
	count, err := trashPathWithProgress(target, &counter)
	if err != nil {
		t.Fatalf("trashPathWithProgress returned error: %v", err)
	}
	if count != 1 || counter != 1 {
		t.Fatalf("expected one path-level Trash operation, got count=%d counter=%d", count, counter)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("expected target to be moved to Trash, stat err=%v", err)
	}
}

func TestDeleteMultiplePathsCmdHandlesParentChild(t *testing.T) {
	root, _ := useTempTrash(t)
	parent := filepath.Join(root, "parent")
	child := filepath.Join(parent, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child, "fileC"), []byte("c"), 0o644); err != nil {
		t.Fatalf("write fileC: %v", err)
	}

	var counter int64
	msg := deleteMultiplePathsCmd([]string{parent, child}, &counter)()
	progress, ok := msg.(deleteProgressMsg)
	if !ok {
		t.Fatalf("expected deleteProgressMsg, got %T", msg)
	}
	if progress.err != nil {
		t.Fatalf("unexpected error: %v", progress.err)
	}
	if progress.count != 2 {
		t.Fatalf("expected 2 paths trashed, got %d", progress.count)
	}
	if _, err := os.Stat(parent); !os.IsNotExist(err) {
		t.Fatalf("expected parent to be moved to Trash, err=%v", err)
	}
}

func TestMoveToTrashNonExistent(t *testing.T) {
	if err := moveToTrash("/nonexistent/path/that/does/not/exist"); err == nil {
		t.Fatal("expected error for non-existent path")
	}
}

func TestMoveToTrashRejectsTraversal(t *testing.T) {
	// Verify the full production path rejects ".." before filepath.Abs resolves it.
	err := moveToTrash("/tmp/fakedir/../../../etc/passwd")
	if err == nil || !strings.Contains(err.Error(), "traversal") {
		t.Fatalf("expected traversal error, got: %v", err)
	}
}

func TestValidateTrashTargetRejectsCriticalRoots(t *testing.T) {
	for _, path := range []string{"/", "/usr", "/etc", "/boot", "/home", "/var", "/var/lib", "/run/media"} {
		if err := validateTrashTarget(path); err == nil {
			t.Errorf("validateTrashTarget(%q) = nil, want protected error", path)
		}
	}
}

func TestValidateTrashTargetRejectsSystemTrees(t *testing.T) {
	for _, path := range []string{"/usr/bin/bash", "/etc/fstab", "/boot/vmlinuz-linux", "/var/lib/pacman/local"} {
		if err := validateTrashTarget(path); err == nil {
			t.Errorf("validateTrashTarget(%q) = nil, want protected error", path)
		}
	}
}

func TestValidateTrashTargetRejectsHomeRoots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := validateTrashTarget(home); err == nil {
		t.Fatalf("validateTrashTarget(HOME) = nil, want protected error")
	}
	if err := validateTrashTarget("/home/someone"); err == nil {
		t.Fatalf("validateTrashTarget(/home/someone) = nil, want protected error")
	}
}

func TestValidateTrashTargetAllowsRegularUserPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, path := range []string{
		filepath.Join(home, "Downloads", "big.iso"),
		filepath.Join(home, ".cache", "yay"),
		"/home/someone/Downloads",
		"/var/cache/pacman/pkg/foo.pkg.tar.zst",
	} {
		if err := validateTrashTarget(path); err != nil {
			t.Errorf("validateTrashTarget(%q) = %v, want nil", path, err)
		}
	}
}

func TestValidateTrashTargetRejectsSymlinkToCriticalRoot(t *testing.T) {
	link := filepath.Join(t.TempDir(), "etc-link")
	if err := os.Symlink("/etc", link); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	if err := validateTrashTarget(link); err == nil {
		t.Fatalf("validateTrashTarget(%q) = nil, want protected error", link)
	}
}

func TestMoveToTrashViaFilesystemWritesTrashInfo(t *testing.T) {
	root, trashDir := useTempTrash(t)
	target := filepath.Join(root, "my report.txt")
	if err := os.WriteFile(target, []byte("data"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}

	if err := moveToTrashViaFilesystem(target); err != nil {
		t.Fatalf("filesystem Trash move failed: %v", err)
	}
	if got, err := os.ReadFile(filepath.Join(trashDir, "files", "my report.txt")); err != nil || string(got) != "data" {
		t.Fatalf("trashed file mismatch: data=%q err=%v", got, err)
	}
	info, err := os.ReadFile(filepath.Join(trashDir, "info", "my report.txt.trashinfo"))
	if err != nil {
		t.Fatalf("read trashinfo: %v", err)
	}
	if !strings.HasPrefix(string(info), "[Trash Info]\n") || !strings.Contains(string(info), "Path="+strings.ReplaceAll(target, " ", "%20")+"\n") {
		t.Fatalf("unexpected trashinfo: %q", info)
	}
	if !strings.Contains(string(info), "DeletionDate=") {
		t.Fatalf("trashinfo missing DeletionDate: %q", info)
	}
}

func TestMoveToTrashViaFilesystemMovesWithoutOverwritingCollision(t *testing.T) {
	root, trashDir := useTempTrash(t)
	filesDir := filepath.Join(trashDir, "files")
	if err := os.MkdirAll(filesDir, 0o700); err != nil {
		t.Fatalf("create fake Trash: %v", err)
	}
	target := filepath.Join(root, "report.txt")
	if err := os.WriteFile(target, []byte("new"), 0o644); err != nil {
		t.Fatalf("write target: %v", err)
	}
	existing := filepath.Join(filesDir, "report.txt")
	if err := os.WriteFile(existing, []byte("keep"), 0o644); err != nil {
		t.Fatalf("write collision: %v", err)
	}

	if err := moveToTrashViaFilesystem(target); err != nil {
		t.Fatalf("filesystem Trash move failed: %v", err)
	}
	if got, err := os.ReadFile(existing); err != nil || string(got) != "keep" {
		t.Fatalf("existing Trash item was changed: data=%q err=%v", got, err)
	}
	matches, err := filepath.Glob(filepath.Join(filesDir, "report.txt.*"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one collision-safe Trash item, matches=%v err=%v", matches, err)
	}
	if _, err := os.Stat(filepath.Join(trashDir, "info", filepath.Base(matches[0])+".trashinfo")); err != nil {
		t.Fatalf("expected matching trashinfo: %v", err)
	}
}

func TestMoveToTrashViaFilesystemRejectsSymlinkedTrash(t *testing.T) {
	root, trashDir := useTempTrash(t)
	realTrash := filepath.Join(root, "real-trash")
	if err := os.MkdirAll(realTrash, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.Symlink(realTrash, trashDir); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	target := filepath.Join(root, "file.txt")
	if err := os.WriteFile(target, []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := moveToTrashViaFilesystem(target); err == nil {
		t.Fatal("expected symlinked Trash to be rejected")
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("target should be untouched: %v", err)
	}
}

func TestValidatePath(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		wantErr bool
	}{
		// 基本合法路径
		{"absolute path", "/Users/test/file.txt", false},
		{"path with spaces", "/Users/test/My Documents/file.txt", false},
		{"root", "/", false},

		// 中文路径
		{"chinese path", "/Users/test/中文文件夹/文件.txt", false},
		{"chinese mixed", "/Users/test/Downloads/报告2024.pdf", false},

		// Emoji 路径
		{"emoji path", "/Users/test/📁文件夹/📝笔记.txt", false},
		{"emoji only", "/Users/test/🎉/🎊.txt", false},

		// 特殊字符路径 (之前被错误拒绝的)
		{"dollar sign", "/Users/test/$HOME/workspace", false},
		{"semicolon", "/Users/test/project;v2", false},
		{"colon", "/Users/test/project:2024", false},
		{"ampersand", "/Users/test/R&D/project", false},
		{"at sign", "/Users/test/user@domain", false},
		{"hash", "/Users/test/project#123", false},
		{"percent", "/Users/test/100% complete", false},
		{"exclamation", "/Users/test/important!.txt", false},
		{"single quote", "/Users/test/user's files", false},
		{"equals", "/Users/test/key=value", false},
		{"plus", "/Users/test/file+v2", false},
		{"brackets", "/Users/test/[2024] report", false},
		{"parentheses", "/Users/test/project (copy)", false},
		{"comma", "/Users/test/file, backup", false},

		// 非法路径
		{"empty", "", true},
		{"relative", "relative/path", true},
		{"relative dot", "./file.txt", true},
		{"null byte", "/Users/test\x00/file", true},
		{"path traversal", "/Users/test/../../../etc", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validatePath(tt.path)
			if (err != nil) != tt.wantErr {
				t.Errorf("validatePath(%q) error = %v, wantErr %v", tt.path, err, tt.wantErr)
			}
		})
	}
}

func TestValidatePathWithChineseAndSpecialChars(t *testing.T) {
	// 专门测试之前会导致兼容性回退的路径
	parent := t.TempDir()
	testCases := []struct {
		name string
		path string
	}{
		{"chinese", "中文文件夹"},
		{"emoji", "📁 文档"},
		{"mixed", "报告-2024_v2 (终稿) [已审核]"},
		{"special", "Project$2024; Q1: R&D"},
		{"complex", "用户@公司 100% 完成!"},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			fullPath := filepath.Join(parent, tc.path)
			if err := os.MkdirAll(fullPath, 0o755); err != nil {
				t.Fatalf("mkdir %q: %v", tc.path, err)
			}

			if err := validatePath(fullPath); err != nil {
				t.Errorf("validatePath rejected valid path %q: %v", tc.path, err)
			}
		})
	}
}

// Regression for discussion #474: deleting from analyze over SSH appeared to do
// nothing. The only Trash path was Finder AppleScript, which raises a dialog on
// the physical machine that a remote user cannot answer, so every delete sat for
// trashTimeout and then failed. trash(8) needs no Finder, so it must be tried
// first and must actually move the file.
