# Pacer dev workflow.
#
# This Makefile is the single entry point for AI and humans alike.
# All non-trivial logic lives in `bin/dev-*.sh` so each step is
# inspectable and individually runnable.
#
# Common flows:
#
#   First-time setup  : make install
#   After AI changes  : make install        (idempotent — handles upgrade)
#   Watch logs        : make logs
#   Quick health check: make status
#   Foreground debug  : make daemon-fg      (kills launchctl daemon first)
#   Tear down         : make uninstall
#
# `make help` lists everything with one-line descriptions.

# Use bash so the recipes can rely on bash features (heredocs, [[ ]]).
SHELL := /bin/bash

# Paths used throughout. Quoted in recipes when expanded.
REPO_ROOT      := $(shell pwd)
BUILD_OUTPUT   := $(REPO_ROOT)/Build/Products/Debug/Pacer.app
INSTALLED_APP  := /Applications/Pacer.app
DEV_LABEL      := com.ericandrechek.pacer.daemon.dev
SMAPP_LABEL    := com.ericandrechek.pacer.daemon
DEV_PLIST      := $(HOME)/Library/LaunchAgents/$(DEV_LABEL).plist
LOG_DIR        := $(HOME)/Library/Logs/Pacer
LOG_ERR        := $(LOG_DIR)/PacerDaemon.err.log
STORE_DIR      := $(HOME)/Library/Group Containers/group.com.ericandrechek.pacer

# Mark targets that don't produce a file as PHONY so make doesn't
# get confused if a file with the same name appears.
.PHONY: help build verify test app install uninstall reinstall \
        daemon-stop daemon-start daemon-restart daemon-fg \
        logs logs-tail status open clean-data

# Default target — show help so a bare `make` doesn't do something
# surprising.
.DEFAULT_GOAL := help

help:  ## Show this help.
	@printf "Pacer dev workflow\n\n"
	@printf "Targets:\n"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf "\nLog file: %s\n" "$(LOG_ERR)"
	@printf "Installed app: %s\n" "$(INSTALLED_APP)"

# ------------------------------------------------------------------
# Build / test
# ------------------------------------------------------------------

verify:  ## Verification build (no signing, no install) — fastest sanity check.
	@xcodegen generate
	@xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Debug \
		-destination 'platform=macOS' \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
		build | (grep -E '(error:|warning:|FAILED|SUCCEEDED)' || true)

# Convenience alias.
build: verify  ## Alias for `verify`.

test:  ## Run the PacerCore unit + ground-truth tests.
	@cd PacerCore && swift test 2>&1 | tail -3

app:  ## Signed Debug build of Pacer.app (output: Build/Products/Debug/Pacer.app).
	@xcodegen generate
	@xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Debug \
		-destination 'platform=macOS' \
		-allowProvisioningUpdates \
		build | (grep -E '(error:|warning:|FAILED|SUCCEEDED)' || true)

# ------------------------------------------------------------------
# Install / uninstall
# ------------------------------------------------------------------

install:  ## Build + sign + copy to /Applications + register daemon. Idempotent.
	@$(REPO_ROOT)/bin/dev-install.sh

uninstall:  ## Stop daemon + remove /Applications/Pacer.app. Preserves SwiftData and logs.
	@$(REPO_ROOT)/bin/dev-uninstall.sh

reinstall: uninstall install  ## Uninstall and reinstall. Use when something feels wedged.

# ------------------------------------------------------------------
# Daemon lifecycle
# ------------------------------------------------------------------

daemon-stop:  ## Stop the running daemon (both dev and SMAppService labels).
	@launchctl bootout "gui/$$(id -u)/$(DEV_LABEL)"   2>/dev/null || true
	@launchctl bootout "gui/$$(id -u)/$(SMAPP_LABEL)" 2>/dev/null || true
	@echo "Daemon stopped (or was not running)."

daemon-start:  ## Start the daemon via launchctl. Requires `make install` first.
	@if [ ! -f "$(DEV_PLIST)" ]; then \
		echo "ERROR: $(DEV_PLIST) not found. Run 'make install' first."; exit 1; \
	fi
	@launchctl bootstrap "gui/$$(id -u)" "$(DEV_PLIST)"
	@echo "Daemon started."

daemon-restart: daemon-stop daemon-start  ## Stop and start.

daemon-fg:  ## Run the installed daemon in the foreground for live debugging.
	@if [ ! -x "$(INSTALLED_APP)/Contents/Library/LaunchServices/PacerDaemon" ]; then \
		echo "ERROR: $(INSTALLED_APP) not installed. Run 'make install' first."; exit 1; \
	fi
	@$(MAKE) daemon-stop
	@echo "Running daemon in foreground. Ctrl-C to stop."
	@"$(INSTALLED_APP)/Contents/Library/LaunchServices/PacerDaemon"

# ------------------------------------------------------------------
# Observation
# ------------------------------------------------------------------

logs:  ## tail -f the daemon's stderr log. Ctrl-C to exit.
	@if [ ! -f "$(LOG_ERR)" ]; then \
		echo "Log not yet created at $(LOG_ERR). Daemon may not be running yet."; \
		echo "Run 'make status' for diagnosis or 'make install' to start."; \
		exit 0; \
	fi
	@tail -F "$(LOG_ERR)"

logs-tail:  ## Print the last 100 lines of the daemon log (for AI use).
	@if [ ! -f "$(LOG_ERR)" ]; then \
		echo "(no log yet at $(LOG_ERR))"; \
	else \
		tail -n 100 "$(LOG_ERR)"; \
	fi

status:  ## Show install state, daemon PID, log file sizes, recent log lines.
	@$(REPO_ROOT)/bin/dev-status.sh

open:  ## Open Pacer.app from /Applications.
	@if [ ! -d "$(INSTALLED_APP)" ]; then \
		echo "ERROR: $(INSTALLED_APP) not installed. Run 'make install' first."; exit 1; \
	fi
	@open "$(INSTALLED_APP)"

# ------------------------------------------------------------------
# Destructive utilities (no shortcut alias; user must spell it out)
# ------------------------------------------------------------------

clean-data:  ## DESTRUCTIVE: also remove SwiftData store and logs. Prompts for confirmation.
	@echo "About to remove:"
	@echo "  $(STORE_DIR)/pacer.sqlite (and -wal/-shm)"
	@echo "  $(LOG_DIR)/*"
	@read -p "Continue? [y/N] " yn; \
	if [ "$$yn" = "y" ] || [ "$$yn" = "Y" ]; then \
		rm -f "$(STORE_DIR)/pacer.sqlite" "$(STORE_DIR)/pacer.sqlite-wal" "$(STORE_DIR)/pacer.sqlite-shm"; \
		rm -f "$(LOG_DIR)"/*.log; \
		echo "Wiped."; \
	else \
		echo "Cancelled."; \
	fi
