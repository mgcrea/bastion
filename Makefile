# The commands you would otherwise retype. Not a build system: the Node half is
# pnpm from here, the Swift half is xcodebuild, and this only names them.
#
# Targets appear as their step of the build order lands. A Makefile that names
# a release path before there is anything to release is a list of commands that
# do not work, and the first one someone runs teaches them not to trust the
# rest.

CONFIG  := Debug
TEAM_ID := 75QE9PRT3V

# The embedded runtime. nodejs.org, not Homebrew: the official darwin builds are
# a single self-contained binary, Homebrew's needs libnode.dylib beside it — and
# the whole point of embedding one is that there is no "which node?" question
# left to answer at spawn time.
NODE_VERSION ?= 24.18.0
# `arch x64` for a release; `arm64` alone builds far faster while iterating.
NODE_ARCHS   ?= arm64 x64
STAGED       := apps/apple/.build/staged

# Where the servers come from, which is the one place Bastion differs from
# cupertino's release path in kind rather than in name.
#
# Cupertino bundles its own `packages/*`. Bastion's servers live in a SIBLING
# REPO and only three of the ten are published to npm, so there is no single
# answer. `make stage-servers` takes the published ones from the registry, which
# is the only source a stranger could reproduce. `LOCAL_SERVERS=1` takes all ten
# from the checkout instead, which is right for a dogfood build and wrong for
# anything anyone else installs — a bundle built that way carries unpublished
# code from a path on this machine.
# The updater. Pinned exactly and checksum-verified: this framework is loaded
# into a process holding every credential the user owns, and `sign` asserts the
# team that signed it, so a version that drifted under that allowance would be
# trusted for something nobody measured.
SPARKLE_VERSION   ?= 2.9.6
SPARKLE_SHA256    := 8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606
SPARKLE_VENDOR    := apps/apple/Vendor
SPARKLE_FRAMEWORK := $(SPARKLE_VENDOR)/Sparkle.framework
SPARKLE_TOOLS     := apps/apple/.build/sparkle-cache/bin
# Records which version is staged, so `make app` re-extracts only on a bump.
SPARKLE_STAMP     := $(SPARKLE_VENDOR)/.sparkle-$(SPARKLE_VERSION)
# Deferred (`=`, not `:=`): RELEASE_APP is defined further down, and immediate
# expansion here resolved to a bare "/Contents/..." path, so every guard on
# this variable quietly did nothing and the framework shipped unsigned.
RELEASE_SPARKLE    = $(RELEASE_APP)/Contents/Frameworks/Sparkle.framework

MCP_ROOT     ?= $(HOME)/Projects/mgcrea/mgcrea-ai
NPM_SERVERS  := shopify appstore-connect ovh-api

# What a local build calls itself, from the two facts CI derives it from: the
# nearest `app-v*` tag and the commit count. Without this a `make install` app
# inherits the pbxproj default and sits in /Applications calling itself 1.0 —
# which, once there is an appcast, is also below the shipped build number, so
# the updater offers a developer their own build as an update.
# Empty outside a git checkout, where the pbxproj default stands: a release
# tarball is still buildable.
APP_VERSION  := $(shell git describe --tags --match 'app-v*' --abbrev=0 2>/dev/null | sed 's/^app-v//')
APP_BUILD    := $(shell git rev-list --count HEAD 2>/dev/null)
# Emitted only when XCARGS does not already carry the setting. CI passes both
# from the tag and `bundle` forwards that string to the same xcodebuild, so
# emitting them unconditionally would put each on the command line twice and
# leave the shipped version to whichever duplicate xcodebuild honours.
XCARGS       ?=
VERSION_ARGS := $(if $(findstring MARKETING_VERSION,$(XCARGS)),,$(if $(APP_VERSION),MARKETING_VERSION=$(APP_VERSION)))
VERSION_ARGS += $(if $(findstring CURRENT_PROJECT_VERSION,$(XCARGS)),,$(if $(APP_BUILD),CURRENT_PROJECT_VERSION=$(APP_BUILD)))

# A Debug build carries its own bundle identifier so its Keychain items are its
# own. This is not cosmetic: Keychain access is scoped by app identity, so a
# shared id means a debug build reads, overwrites and deletes the credentials
# the real app is holding. It must follow CONFIG.
BUNDLE_ID := io.mgcrea.bastion$(if $(filter Debug,$(CONFIG)),.debug,)
APP     ?= apps/apple/.build/Build/Products/$(CONFIG)/Bastion.app
RELEASE_APP := apps/apple/.build/Build/Products/Release/Bastion.app
INSTALLED := /Applications/Bastion.app
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
app: sparkle ## Build Bastion.app and the embedded bastion-bridge
	@set -o pipefail; xcodebuild -project apps/apple/Bastion.xcodeproj -scheme Bastion \
		-configuration $(CONFIG) -derivedDataPath apps/apple/.build \
		$(VERSION_ARGS) $(XCARGS) build \
		| { grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)' || true; }

run: app ## Build, then (re)launch the menu bar app
	@pkill -f 'Bastion.app/Contents/MacOS/Bastion' 2>/dev/null || true
	@sleep 1 && open "$(APP)"
	@echo "Bastion running — look for the tray icon in the menu bar."

stop: ## Quit the app
	@pkill -f 'Bastion.app/Contents/MacOS/Bastion' 2>/dev/null || true

dev-config: ## Point the Debug app at the mgcrea-ai checkout instead of bundled servers
	@mkdir -p "$(SUPPORT)" && chmod 700 "$(SUPPORT)"
	@node=$$(command -v node) || { echo "no node on PATH"; exit 1; }; \
	printf '{\n  "node": "%s",\n  "repo": "%s"\n}\n' "$$node" "$(MCP_ROOT)" > "$(SUPPORT)/dev.json"
	@chmod 600 "$(SUPPORT)/dev.json"
	@echo "  $(SUPPORT)/dev.json -> $(MCP_ROOT)"

clean: ## Remove the app build output
	@rm -rf apps/apple/.build

# ─── the release path ────────────────────────────────────────────────────────

# Idempotent, and stamped by version.
#
# It used to re-extract on every `make app`, in place, into a directory it first
# tried to `rm -rf`. Two things were wrong with that. `unzip` cannot write the
# symlinks a framework is made of when real files are already sitting at those
# paths — it reports "deferred symlink … invalid placeholder file" and leaves
# zero-length placeholders behind — so one interrupted run poisoned every run
# after it. And the `rm -rf` that was supposed to prevent that is the step that
# failed first, which meant the guard and the thing it guarded broke together.
#
# So: extract into a fresh temporary directory that is thrown away either way,
# and stamp the result. Nothing is ever cleaned in place, a failed run leaves no
# state for the next one to inherit, and `make app` stops paying for an
# extraction it does not need. Bumping SPARKLE_VERSION invalidates the stamp.
sparkle: $(SPARKLE_STAMP) ## Download and stage the pinned Sparkle.framework

$(SPARKLE_STAMP):
	@mkdir -p apps/apple/.build/sparkle-cache $(SPARKLE_VENDOR)
	@zip="apps/apple/.build/sparkle-cache/Sparkle-$(SPARKLE_VERSION).zip"; \
	[ -f "$$zip" ] || curl -fsSL -o "$$zip" \
		"https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-for-Swift-Package-Manager.zip"; \
	echo "$(SPARKLE_SHA256)  $$zip" | shasum -a 256 -c - >/dev/null \
		|| { echo "  Sparkle checksum mismatch — refusing to build against it"; rm -f "$$zip"; exit 1; }; \
	tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/sparkle.XXXXXX") || exit 1; \
	trap 'rm -rf "$$tmp"' EXIT INT TERM; \
	ditto -x -k "$$zip" "$$tmp" || exit 1; \
	rm -rf $(SPARKLE_FRAMEWORK) $(SPARKLE_TOOLS); \
	mkdir -p $(SPARKLE_TOOLS); \
	ditto "$$tmp/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" $(SPARKLE_FRAMEWORK) || exit 1; \
	ditto "$$tmp/bin" $(SPARKLE_TOOLS) || exit 1
	@# Sandbox-only, and this app is not sandboxed. Stripped here rather than at
	@# bundle time so a Debug build has the same Mach-O inventory as a Release
	@# one — every extra binary inside the bundle is one more thing signed, one
	@# more thing notarized, and one more thing to explain. This invalidates the
	@# vendored signature by design, which is why `sign` re-signs the framework
	@# and then asserts the team on it.
	@rm -rf $(SPARKLE_FRAMEWORK)/Versions/B/XPCServices
	@rm -f $(SPARKLE_VENDOR)/.sparkle-*
	@touch $(SPARKLE_STAMP)
	@echo "  Sparkle $(SPARKLE_VERSION) staged: $(SPARKLE_FRAMEWORK)"

node: ## Download and lipo the embedded node runtime
	@mkdir -p $(STAGED) apps/apple/.build/node-cache
	@for arch in $(NODE_ARCHS); do \
		tar="apps/apple/.build/node-cache/node-v$(NODE_VERSION)-darwin-$$arch.tar.gz"; \
		[ -f "$$tar" ] || curl -fsSL -o "$$tar" \
			"https://nodejs.org/dist/v$(NODE_VERSION)/node-v$(NODE_VERSION)-darwin-$$arch.tar.gz"; \
		tar -xzf "$$tar" -C apps/apple/.build/node-cache \
			"node-v$(NODE_VERSION)-darwin-$$arch/bin/node"; \
	done
	@slices=""; for arch in $(NODE_ARCHS); do \
		slices="$$slices apps/apple/.build/node-cache/node-v$(NODE_VERSION)-darwin-$$arch/bin/node"; done; \
		lipo -create $$slices -output $(STAGED)/node
	@lipo -info $(STAGED)/node | sed 's/^/  /'

# Two steps, because the published tarball is not runnable on its own.
#
# `npm pack` fetches exactly what the registry serves and nothing else, which is
# the right source — but these packages do NOT bundle their dependencies, so a
# staged `dist/cli.js` dies at startup with ERR_MODULE_NOT_FOUND on
# `@modelcontextprotocol/sdk`. Measured, by `scripts/verify-servers.sh` refusing
# to sign a bundle in which all three staged servers failed to answer
# `initialize` — which is the entire reason that check runs before the signature
# rather than after it.
#
# So each staged server then gets its own production `node_modules`. Per server
# rather than hoisted: they are independent packages that happen to share a
# parent directory, and a shared tree would make one server's resolution depend
# on another's dependency ranges.
stage-servers: ## Stage the MCP servers into the release bundle layout
	@rm -rf "$(STAGED)/servers" && mkdir -p "$(STAGED)/servers"
ifdef LOCAL_SERVERS
	@echo "  LOCAL_SERVERS=1 — staging all ten from $(MCP_ROOT)."
	@echo "  !! This bundle will carry unpublished code from this machine."
	@for id in $$(node -e 'console.log(require("./servers.json").servers.map(s=>s.id).join(" "))'); do \
		src="$(MCP_ROOT)/mcp-$$id"; \
		if [ ! -f "$$src/dist/cli.js" ]; then echo "  $$id: no dist/cli.js — run its build"; exit 1; fi; \
		mkdir -p "$(STAGED)/servers/$$id"; \
		ditto "$$src/dist" "$(STAGED)/servers/$$id/dist"; \
		install -m 644 "$$src/package.json" "$(STAGED)/servers/$$id/package.json"; \
		echo "  $$id: from the checkout"; \
	done
else
	@cd "$(STAGED)/servers" && for id in $(NPM_SERVERS); do \
		tarball=$$(npm pack "@mgcrea/mcp-$$id" --silent 2>/dev/null) || \
			{ echo "  $$id: not on npm — skipped"; continue; }; \
		mkdir -p "$$id" && tar -xzf "$$tarball" -C "$$id" --strip-components=1 && rm -f "$$tarball"; \
		echo "  $$id: $$(node -p "require('./$$id/package.json').version") from npm"; \
	done
	@echo "  the other servers are not published; a bundle without them reports"
	@echo "  'not in this build' when one is asked for, which is the honest answer."
endif
	@# `--omit=dev` and no lockfile: what ships is the runtime closure and
	@# nothing else. `--ignore-scripts` because a postinstall from a transitive
	@# dependency has no business running inside a bundle about to be signed.
	@for dir in "$(STAGED)/servers"/*/; do \
		[ -d "$$dir" ] || continue; \
		(cd "$$dir" && npm install --omit=dev --no-package-lock --ignore-scripts --silent) \
			|| { echo "  $$(basename $$dir): could not install dependencies"; exit 1; }; \
		echo "  $$(basename $$dir): $$(du -sh "$$dir" | cut -f1)"; \
	done

# The package.json + dist/ shape is not decoration. These servers read their own
# version from `new URL("../package.json", import.meta.url)`, so a flat
# `servers/<id>/cli.js` resolves to one shared file and reports the wrong
# version in every diagnostic.
bundle: stage-servers node sparkle ## Build, stage, verify and sign a Release Bastion.app
	@$(MAKE) --no-print-directory app CONFIG=Release \
		XCARGS="$(XCARGS) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
	@rm -rf "$(RELEASE_APP)/Contents/Resources/servers" "$(RELEASE_APP)/Contents/Resources/node"
	@ditto "$(STAGED)/servers" "$(RELEASE_APP)/Contents/Resources/servers"
	@ditto "$(STAGED)/node" "$(RELEASE_APP)/Contents/Resources/node"
	@# Before signing, not after. A signature over a bundle whose servers cannot
	@# start is worth nothing, and this is the first point at which the servers
	@# and the runtime they will be spawned under sit side by side.
	@scripts/verify-servers.sh "$(RELEASE_APP)"
	@$(MAKE) --no-print-directory sign

# Inside out: node, then the bridge, then the app. A signature over a bundle is
# a signature over its contents, so anything signed after the wrapper
# invalidates it.
#
# No `--entitlements` on the app, and that is the claim rather than an omission.
# Spawning children and binding loopback need none, and with the sandbox off
# `com.apple.security.network.server` is unnecessary. An empty permission set
# that is true by construction is checkable; one arrived at by deletion is not.
# `make audit` asserts there is no entitlements file to begin with, and the
# verification below asserts none ended up on the signed bundle anyway.
#
# The whole identity block is ONE shell invocation because `$$id` has to survive
# across the codesign calls. Comments inside it must be shell comments on their
# own logical line, never `@#` — `@` applies to the first line of a recipe, so a
# continued `@#` is handed to sh, which has no such command.
sign: ## Sign the Release bundle (Developer ID if present, else Apple Development)
	@id=$$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $$2; exit}'); \
	if [ -z "$$id" ]; then \
		id=$$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $$2; exit}'); \
		echo "  !! no Developer ID Application certificate — signing with Apple Development."; \
		echo "     This build will NOT notarize and will not run on another Mac."; \
	fi; \
	test -n "$$id" || { echo "  no codesigning identity at all"; exit 1; }; \
	if [ -d "$(RELEASE_SPARKLE)" ]; then \
		codesign --force --options runtime --timestamp --sign "$$id" \
			"$(RELEASE_SPARKLE)/Versions/B/Updater.app"; \
		codesign --force --options runtime --timestamp --sign "$$id" \
			"$(RELEASE_SPARKLE)/Versions/B/Autoupdate"; \
		codesign --force --options runtime --timestamp --sign "$$id" \
			"$(RELEASE_SPARKLE)"; \
	fi; \
	if [ -x "$(RELEASE_APP)/Contents/Resources/node" ]; then \
		codesign --force --options runtime --timestamp --sign "$$id" \
			--entitlements apps/apple/node.entitlements \
			"$(RELEASE_APP)/Contents/Resources/node"; \
	fi; \
	codesign --force --options runtime --timestamp --sign "$$id" \
		"$(RELEASE_APP)/Contents/Helpers/bastion-bridge"; \
	codesign --force --options runtime --timestamp --sign "$$id" "$(RELEASE_APP)"
	@codesign --verify --deep --strict --verbose=1 "$(RELEASE_APP)" 2>&1 | sed 's/^/  /'
	@codesign -d --entitlements - --xml "$(RELEASE_APP)" 2>/dev/null | grep -q '<key>' \
		&& { echo "  the app carries entitlements — it should carry none"; exit 1; } \
		|| echo "  no entitlements on the app"
	@# The hardened runtime is on and nothing disables library validation, so a
	@# Sparkle signed by another team fails at dlopen — at launch, on a user's
	@# Mac, long after this. Assert the team here, where the message is readable.
	@test -d "$(RELEASE_SPARKLE)" && { codesign -dv --verbose=2 "$(RELEASE_SPARKLE)" 2>&1 \
		| grep -q 'TeamIdentifier=$(TEAM_ID)' \
		|| { echo "  Sparkle is not signed by $(TEAM_ID) — library validation will reject it"; exit 1; }; \
		echo "  Sparkle signed by $(TEAM_ID)"; } || true
	@# A build whose public key is empty cannot verify an appcast, so Sparkle
	@# refuses every update it is offered. Safe, but silently un-updatable, and
	@# the only moment anyone would notice is the release that needed to ship.
	@/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$(RELEASE_APP)/Contents/Info.plist" 2>/dev/null \
		| grep -q . || echo "  !! SUPublicEDKey is empty — this build can never be updated. Run 'make sparkle-keys'."
	@echo "  size: $$(du -sh "$(RELEASE_APP)" | cut -f1)"

# Run once, ever. The private key goes into the login keychain and the public key
# into apps/apple/Bastion-Info.plist, where it is committed.
#
# That private key is the most dangerous secret this project has: together with
# the Developer ID certificate it is enough to hand every user a new version of
# an app that holds their Shopify secret, their Keycloak password and a
# brokerage refresh token, with one click and no further question. It belongs in
# the keychain and in one repository secret, never in an org-wide one and never
# anywhere a pull_request workflow can read it.
sparkle-keys: sparkle ## Generate or reuse the EdDSA update-signing key
	@echo "Sparkle stores ONE signing key per user account, not one per app:"
	@echo "a single item under https://sparkle-project.org in the login keychain."
	@echo "If cupertino has already made one, this reuses it and Bastion ships the"
	@echo "same public key — which means one leaked key can push an update to both."
	@echo "Getting a separate key means exporting, removing the existing item, and"
	@echo "importing per release. That is a deliberate choice, so it is not made here."
	@echo ""
	@security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1 \
		&& echo "  a key already exists — the tool will reuse it" \
		|| echo "  no key yet — the tool will create one"
	@echo ""
	@$(SPARKLE_TOOLS)/generate_keys
	@echo ""
	@echo "Put the printed public key in the SUPublicEDKey value of"
	@echo "apps/apple/Bastion-Info.plist, and commit it. The private half stays"
	@echo "in the login keychain — it is never written to this repository."

# The appcast is one item, not a history. Sparkle only needs the newest, and a
# feed that accumulates every release is a feed that has to stay consistent with
# every zip still on the CDN.
appcast: ## Sign the release zip and write a one-item appcast
	@test -f apps/apple/.build/Bastion.zip || { echo "run 'make build-release' first"; exit 1; }
	@version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		"$(RELEASE_APP)/Contents/Info.plist"); \
	build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
		"$(RELEASE_APP)/Contents/Info.plist"); \
	length=$$(stat -f%z apps/apple/.build/Bastion.zip); \
	signature=$$($(SPARKLE_TOOLS)/sign_update apps/apple/.build/Bastion.zip | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/'); \
	notes=$$(awk '/^## /{ if (n++) exit } n' CHANGELOG.md 2>/dev/null | tail -n +2); \
	printf '%s\n' \
		'<?xml version="1.0" encoding="utf-8"?>' \
		'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
		'  <channel>' \
		'    <title>Bastion</title>' \
		"    <item>" \
		"      <title>$$version</title>" \
		"      <sparkle:version>$$build</sparkle:version>" \
		"      <sparkle:shortVersionString>$$version</sparkle:shortVersionString>" \
		"      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>" \
		"      <description><![CDATA[$$notes]]></description>" \
		"      <enclosure url=\"https://bastion.mgcrea.io/releases/Bastion-$$version.zip\"" \
		"                 length=\"$$length\"" \
		"                 type=\"application/octet-stream\"" \
		"                 sparkle:edSignature=\"$$signature\" />" \
		"    </item>" \
		'  </channel>' \
		'</rss>' > apps/website/public/appcast.xml
	@echo "  wrote apps/website/public/appcast.xml"

notarize: ## Submit the signed bundle to Apple and staple the ticket
	@test -n "$$AC_KEY_ID" || { echo "set AC_KEY_ID, AC_ISSUER_ID and AC_KEY_PATH first" >&2; exit 1; }
	@ditto -c -k --keepParent "$(RELEASE_APP)" apps/apple/.build/Bastion.zip
	@xcrun notarytool submit apps/apple/.build/Bastion.zip --wait \
		--key "$$AC_KEY_PATH" --key-id "$$AC_KEY_ID" --issuer "$$AC_ISSUER_ID"
	@xcrun stapler staple "$(RELEASE_APP)"
	@# Re-zipped AFTER stapling: the ticket is written into the bundle, so the
	@# archive made before it does not carry one and Gatekeeper on a machine
	@# that is offline would reject it.
	@ditto -c -k --keepParent "$(RELEASE_APP)" apps/apple/.build/Bastion.zip
	@echo "  stapled: apps/apple/.build/Bastion.zip"

# Sequential sub-makes rather than `build-release: bundle notarize`, because
# prerequisites may run in parallel under -j and notarizing a bundle that is
# still being signed staples a ticket to a cdhash that is about to change.
build-release: ## Build, sign and notarize a shippable Bastion.app
	@$(MAKE) --no-print-directory bundle
	@$(MAKE) --no-print-directory notarize

# ─── installing ──────────────────────────────────────────────────────────────

install: app dev-config ## Install the Debug build to /Applications (development)
	@$(MAKE) --no-print-directory install-from SRC="$(APP)"

install-release: ## Install the notarized Release build (run build-release first)
	@$(MAKE) --no-print-directory install-from SRC="$(RELEASE_APP)"

install-from:
	@test -d "$(SRC)" || { echo "no app at $(SRC) — run 'make bundle' first"; exit 1; }
	@if [ -d "$(INSTALLED)" ]; then \
		id=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(INSTALLED)/Contents/Info.plist" 2>/dev/null); \
		case "$$id" in \
			io.mgcrea.bastion|io.mgcrea.bastion.debug) ;; \
			*) echo "refusing to replace $(INSTALLED): its identifier is '$$id'"; exit 1 ;; \
		esac; \
	fi
	@pkill -f 'Bastion.app/Contents/MacOS/Bastion' 2>/dev/null || true
	@sleep 1
	@rm -rf "$(INSTALLED)"
	@ditto "$(SRC)" "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "installed  $(INSTALLED)"
	@echo "bridge     $(INSTALLED)/Contents/Helpers/bastion-bridge"
	@spctl -a -t exec "$(INSTALLED)" >/dev/null 2>&1 \
		&& echo "gatekeeper accepted (notarized)" \
		|| echo "NOT notarized — fine locally, but this copy will not run on another Mac"
	@echo ""
	@echo "Keychain items are scoped by bundle identifier, so a Debug install and a"
	@echo "Release install hold SEPARATE credentials. Profiles created against one"
	@echo "are invisible to the other."

uninstall: ## Remove the installed copy
	@pkill -f 'Bastion.app/Contents/MacOS/Bastion' 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@echo "removed $(INSTALLED)"
	@echo "Credentials stay in the Keychain and profiles in Application Support."
	@echo "Remove them by hand if you mean to start clean."

smoke: app ## Prove one supervised server end to end (PROFILE=prod SERVER=shopify)
	@scripts/smoke.sh

dialect: app ## Assert Bastion serves both protocol eras (needs a profile)
	@scripts/dialect-check.sh

wiring-check: ## Assert the config merge leaves other people's files alone
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/wiring-check \
		apps/apple/Bastion/ClientWiringMerge.swift scripts/wiring-check.swift
	@apps/apple/.build/wiring-check

# Read-only. Parses your actual client configs, merges in memory, and asserts
# every pre-existing key comes back deep-equal. Fixtures only cover the shapes
# somebody thought of; this covers the ones nobody would have invented.
wiring-check-real: wiring-check ## Prove the merge against the real client configs (read-only)
	@apps/apple/.build/wiring-check \
		"$(HOME)/.claude.json" \
		"$(HOME)/Library/Application Support/Claude/claude_desktop_config.json" \
		"$(HOME)/Library/Application Support/Code/User/mcp.json"

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

.PHONY: help app run stop dev-config clean \
	sparkle sparkle-keys appcast node stage-servers bundle sign notarize build-release \
	install install-release install-from uninstall \
	smoke dialect wiring-check wiring-check-real audit migrate servers servers-check icon \
	lint format format-check
