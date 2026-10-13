# Makefile for nixit

.PHONY: all build install uninstall check test test-go test-shell clean

BIN_DIR := bin
GO ?= go
LDFLAGS := -s -w
PREFIX ?= $(HOME)/.local

all: build

# Build the Go helpers (disk analyzer and status dashboard).
build:
	$(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/analyze-go ./cmd/analyze
	$(GO) build -ldflags="$(LDFLAGS)" -o $(BIN_DIR)/status-go ./cmd/status

# Link the nixit command into $(PREFIX)/bin (default ~/.local/bin).
install: build
	mkdir -p $(PREFIX)/bin
	ln -sf $(CURDIR)/nixit $(PREFIX)/bin/nixit
	@echo "Installed: $(PREFIX)/bin/nixit -> $(CURDIR)/nixit"

uninstall:
	rm -f $(PREFIX)/bin/nixit

check:
	bash -n nixit lib/*.sh bin/*.sh
	@if command -v shellcheck >/dev/null; then shellcheck -x -e SC1091 nixit lib/*.sh bin/*.sh; else echo "shellcheck not installed; skipped"; fi
	$(GO) vet ./...

test: test-go test-shell

test-go:
	$(GO) test ./...

test-shell:
	bash tests/run.sh

clean:
	rm -f $(BIN_DIR)/analyze-go $(BIN_DIR)/status-go
