# Pacer dev workflow.
#
# Single-binary architecture: data collection runs inside the app
# process (FSEvents + OAuth poller live in `App/Background/`). There
# is no separate daemon binary anymore.
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
#   Tear down         : make uninstall
#
# `make help` lists everything with one-line descriptions.

# Use bash so the recipes can rely on bash features (heredocs, [[ ]]).
SHELL := /bin/bash

# Paths used throughout. Quoted in recipes when expanded.
REPO_ROOT      := $(shell pwd)
BUILD_OUTPUT   := $(REPO_ROOT)/Build/Products/Debug/Pacer.app
INSTALLED_APP  := /Applications/Pacer.app
LOG_DIR        := $(HOME)/Library/Logs/Pacer
LOG_ERR        := $(LOG_DIR)/Pacer.err.log
STORE_DIR      := $(HOME)/Library/Group Containers/group.com.ericandrechek.pacer

# Mark targets that don't produce a file as PHONY so make doesn't
# get confused if a file with the same name appears.
.PHONY: help build verify test app install uninstall reinstall \
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

install:  ## Build + sign + notarize + copy to /Applications. Cleans up legacy daemon registration. Quits and re-opens Pacer.app if it was running. Idempotent.
	@$(REPO_ROOT)/bin/dev-install.sh

uninstall:  ## Quit GUI + remove /Applications/Pacer.app + clean up legacy daemon plist. Preserves SwiftData and logs.
	@$(REPO_ROOT)/bin/dev-uninstall.sh

# `reinstall` captures whether Pacer.app is currently running BEFORE
# either step touches it, then asks dev-install.sh to restore the GUI
# at the end — otherwise the user's app would silently disappear
# across the uninstall→install boundary.
reinstall:  ## Uninstall and reinstall (preserves GUI state). Use when something feels wedged.
	@app_was_running=0; \
	if pgrep -f '/Pacer\.app/Contents/MacOS/Pacer$$' >/dev/null 2>&1; then app_was_running=1; fi; \
	$(MAKE) uninstall && \
	if [ "$$app_was_running" = "1" ]; then \
		"$(REPO_ROOT)/bin/dev-install.sh" --restore-app; \
	else \
		"$(REPO_ROOT)/bin/dev-install.sh"; \
	fi

# ------------------------------------------------------------------
# Observation
# ------------------------------------------------------------------

logs:  ## tail -f the app's stderr log. Ctrl-C to exit.
	@if [ ! -f "$(LOG_ERR)" ]; then \
		echo "Log not yet created at $(LOG_ERR). App may not be running yet."; \
		echo "Run 'make status' for diagnosis or 'make install' to start."; \
		exit 0; \
	fi
	@tail -F "$(LOG_ERR)"

logs-tail:  ## Print the last 100 lines of the app log (for AI use).
	@if [ ! -f "$(LOG_ERR)" ]; then \
		echo "(no log yet at $(LOG_ERR))"; \
	else \
		tail -n 100 "$(LOG_ERR)"; \
	fi

status:  ## Show install state, app PID, log file sizes, recent log lines.
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
