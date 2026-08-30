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

migrate: ## Plan the .mcp.json credential migration (add REPOINT=1 to rewrite them)
	@node scripts/migrate-mcp-json.mjs $(if $(REPOINT),--repoint,--plan)

servers: ## Regenerate every copy of the server list from servers.json
	@node scripts/generate-servers.mjs

servers-check: ## Fail if any generated copy has drifted from servers.json
	@node scripts/generate-servers.mjs --check

# ─── the icon ────────────────────────────────────────────────────────────────

# The icon is generated, never hand-drawn: one mark, three renderings. The plate
# lives in the flags rather than the artwork so the .icon layers stay separable.
ICON_MARK    := design/bastion-mark.svg
# '#' opens a comment in a Makefile, so the hexes are spelled through a variable.
HASH         := \#
ICON_PLATE    = $(HASH)FFD08A,$(HASH)F2895C
ICON_RADIUS  := 230
ICON_MENUBAR := design/bastion-menubar.svg

icon: ## Regenerate Bastion.icon and the web SVG from design/bastion-mark.svg
	@appshot icon build --from $(ICON_MARK) \
		--plate-gradient '$(ICON_PLATE)' --plate-angle 90 --mark-fraction 1.0 \
		--out apps/apple/Bastion/Bastion.icon
	@appshot icon build --from $(ICON_MARK) \
		--plate-gradient '$(ICON_PLATE)' --plate-angle 90 --mark-fraction 1.0 \
		--corner-radius $(ICON_RADIUS) --label 'Bastion' \
		--out design/bastion-icon.svg
	@# The hills bleed past the plate's corner radius by design, and nothing masks
	@# an SVG on a web page — so the vector needs the clip the OS applies for free.
	@# perl, not `sed -i`: the flag's in-place syntax differs between BSD and GNU sed
	@# and Homebrew's gnu-sed shadows the system one on some of these machines.
	@perl -pi \
		-e 's|</defs>|<clipPath id="c"><rect width="1024" height="1024" rx="$(ICON_RADIUS)"/></clipPath></defs>|;' \
		-e 's|<g transform=|<g clip-path="url($(HASH)c)" transform=|;' \
		design/bastion-icon.svg
	@# The README banner is composed from the icon above, never drawn beside it.
	@# Cupertino's lockup was hand-drawn alongside the mark and its hills stopped
	@# matching two revisions before anyone noticed.
	@node scripts/generate-lockup.mjs
	@appshot icon check --out apps/apple/Bastion/Bastion.icon
	@# The menu bar glyph is authored, not composed — but the imageset needs the
	@# file *inside* it, so design/ stays the one copy anyone edits.
	@cp $(ICON_MENUBAR) apps/apple/Bastion/Assets.xcassets/MenuBarIcon.imageset/
	@echo "  copied $(notdir $(ICON_MENUBAR)) into MenuBarIcon.imageset"
	@# The website renders its favicon, touch icon and OG card from the same two
	@# files. It reads design/ directly, so nothing is copied — but the PNGs it
	@# derives are committed, and only this command's output makes them stale.
	@echo "  next: pnpm --filter @mgcrea/bastion-website icons"

# ─── the workspace ───────────────────────────────────────────────────────────

lint: ## oxlint the JavaScript half
	@pnpm lint

format: ## oxfmt the repo
	@pnpm format

format-check: ## Fail on unformatted files
	@pnpm format:check

.PHONY: help app run stop clean smoke dialect audit migrate servers servers-check icon lint format format-check
