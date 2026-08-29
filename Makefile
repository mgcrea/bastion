# The commands you would otherwise retype. Not a build system: the Node half is
# pnpm from here, the Swift half is xcodebuild, and this only names them.
#
# Targets appear as their step of the build order lands. A Makefile that names
# a release path before there is anything to release is a list of commands that
# do not work, and the first one someone runs teaches them not to trust the
# rest.

CONFIG  := Debug

# A Debug build carries its own bundle identifier so its Keychain items are its
# own. This is not cosmetic: Keychain access is scoped by app identity, so a
# shared id means a debug build reads, overwrites and deletes the credentials
# the real app is holding. It must follow CONFIG.
BUNDLE_ID := io.mgcrea.bastion$(if $(filter Debug,$(CONFIG)),.debug,)
APP     ?= apps/apple/.build/Build/Products/$(CONFIG)/Bastion.app
SUPPORT := $(HOME)/Library/Application Support/$(BUNDLE_ID)

.DEFAULT_GOAL := help

help: ## Show this help
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ─── the app ─────────────────────────────────────────────────────────────────

# The `|| true` belongs to grep, not to the pipeline: grep exits 1 on a clean
# build with nothing to report, and swallowing that must not also swallow
# xcodebuild's own failure.
app: ## Build Bastion.app
	@set -o pipefail; xcodebuild -project apps/apple/Bastion.xcodeproj -scheme Bastion \
		-configuration $(CONFIG) -derivedDataPath apps/apple/.build build \
		| { grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' || true; }

run: app ## Build, then (re)launch the menu bar app
	@pkill -f 'Bastion.app/Contents/MacOS/Bastion' 2>/dev/null || true
	@sleep 1 && open "$(APP)"
	@echo "Bastion running — look for the tray icon in the menu bar."

stop: ## Quit the app
	@pkill -f 'Bastion.app/Contents/MacOS/Bastion' 2>/dev/null || true

clean: ## Remove the app build output
	@rm -rf apps/apple/.build

smoke: app ## Prove one supervised server end to end (PROFILE=prod SERVER=shopify)
	@scripts/smoke.sh

dialect: app ## Assert Bastion serves both protocol eras (needs a profile)
	@scripts/dialect-check.sh

audit: app ## Assert the listener is loopback-only and refuses foreign Origin/Host
	@scripts/audit-listener.sh

# ─── the manifest ────────────────────────────────────────────────────────────

servers: ## Regenerate every copy of the server list from servers.json
	@node scripts/generate-servers.mjs

servers-check: ## Fail if any generated copy has drifted from servers.json
	@node scripts/generate-servers.mjs --check

# ─── the workspace ───────────────────────────────────────────────────────────

lint: ## oxlint the JavaScript half
	@pnpm lint

format: ## oxfmt the repo
	@pnpm format

format-check: ## Fail on unformatted files
	@pnpm format:check

.PHONY: help app run stop clean smoke dialect audit servers servers-check lint format format-check
