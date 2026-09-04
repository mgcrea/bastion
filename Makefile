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
#
# THE NPM THAT COMES WITH IT IS THE REASON THIS MOVES. It is not pinned
# separately — whatever npm the node tarball bundles is the npm every install
# runs — so a node bump is an npm bump and the two cannot be reasoned about
# apart. 24.18.0 carried npm 11.16.0, which predates `min-release-age-exclude`
# and answered a perfectly good `~/.npmrc` with `Unknown user config`, applying
# the bare age filter and failing a same-day publish as `ENOVERSIONS: No
# versions available` — a sentence that reads as if the package does not exist.
# 24.20.0 is the first v24 carrying npm 11.19.0, which honours it.
NODE_VERSION ?= 24.20.0
# arm64 ONLY, and this is not a size optimisation dressed up as one. The app
# itself has no x86_64 slice — a Release build of Bastion and bastion-bridge is
# arm64, measured, so an Intel Mac cannot launch the process that would spawn
# node in the first place. The x86_64 node slice was 118 MB shipped to nobody.
#
# macOS 26 is the last release supporting Intel and Bastion already requires
# 26.0, so the window was three Mac models wide before it closed; macOS 27 is
# Apple silicon only. Re-add `x64` here only alongside an x86_64 slice in the
# app, or the runtime is fat for a host that cannot reach it.
NODE_ARCHS   ?= arm64
STAGED       := apps/apple/.build/staged

# NO SERVERS ARE BUNDLED. That is the one place Bastion differs from cupertino's
# release path in kind rather than in name.
#
# Cupertino bundles its own `packages/*`. Bastion used to bundle the published
# ones and stage the rest from a sibling checkout, and that is exactly what made
# the server list feel fixed: a server you could add was a server that had to
# already be in `Contents/Resources`, and every id outside the bundle answered
# "not in this build".
#
# So the bundle carries the RUNTIME and nothing else — node, and the npm that
# shipped with it — and `ServerInstaller` fetches a server into Application
# Support when somebody asks for it. `MCP_ROOT` survives for `dev-config`,
# which points a Debug build at the checkout instead.
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

# Quit BEFORE building, not after. `run: app` built first and killed second,
# so xcodebuild overwrote the bundle under the still-running instance — and a
# process whose on-disk code no longer validates cannot be identified by
# securityd, which answers every Keychain access with errSecCSNoSuchCode
# (-67065) and suppresses the prompt rather than showing it. The symptom is a
# credential that reads as unset for no visible reason.
run: ## Build, then (re)launch the menu bar app
	@$(MAKE) --no-print-directory stop
	@$(MAKE) --no-print-directory app
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

# node, and the npm that came with it.
#
# npm is not a convenience here — it is how a server gets installed at all, and
# it has to be the one this exact runtime shipped with: npm's own `engines`
# range is written against its node, and pairing an arbitrary npm with a pinned
# node is the mismatch nobody would think to look for when an install fails on
# one machine and not another.
#
# Pure JavaScript, ~17MB, no Mach-O anywhere in it — checked, because a binary
# in here would be one more thing to sign, notarize and explain. It is taken
# from the arm64 tarball because npm is architecture-independent; the `lipo`
# above is for the runtime, which is not.
#
# Every tarball is checked against nodejs.org's SHASUMS256.txt for the version
# before anything is extracted, the same way `sparkle` checks its zip. A cached
# tarball that fails is deleted so the next run fetches it again rather than
# failing forever on the same bytes. The sums file is fetched over https from
# the same host as the tarball, so what this defends against is a truncated or
# substituted download and a stale cache, not a compromised nodejs.org.
NODE_SUMS := apps/apple/.build/node-cache/SHASUMS256-v$(NODE_VERSION).txt

node: ## Download, verify and stage the embedded node runtime and npm
	@mkdir -p $(STAGED) apps/apple/.build/node-cache
	@[ -f "$(NODE_SUMS)" ] || curl -fsSL -o "$(NODE_SUMS)" \
		"https://nodejs.org/dist/v$(NODE_VERSION)/SHASUMS256.txt"
	@for arch in $(NODE_ARCHS); do \
		name="node-v$(NODE_VERSION)-darwin-$$arch.tar.gz"; \
		tar="apps/apple/.build/node-cache/$$name"; \
		[ -f "$$tar" ] || curl -fsSL -o "$$tar" "https://nodejs.org/dist/v$(NODE_VERSION)/$$name"; \
		grep " $$name$$" "$(NODE_SUMS)" | sed "s|  .*|  $$tar|" | shasum -a 256 -c - >/dev/null \
			|| { echo "  !! $$name does not match SHASUMS256.txt for v$(NODE_VERSION); deleted, run 'make node' again"; \
			     rm -f "$$tar"; exit 1; }; \
		echo "  $$name verified"; \
		tar -xzf "$$tar" -C apps/apple/.build/node-cache \
			"node-v$(NODE_VERSION)-darwin-$$arch/bin/node"; \
	done
	@slices=""; for arch in $(NODE_ARCHS); do \
		slices="$$slices apps/apple/.build/node-cache/node-v$(NODE_VERSION)-darwin-$$arch/bin/node"; done; \
		lipo -create $$slices -output $(STAGED)/node
	@lipo -info $(STAGED)/node | sed 's/^/  /'
	@arch=$$(echo $(NODE_ARCHS) | tr ' ' '\n' | grep -m1 arm64 || echo $(NODE_ARCHS) | cut -d' ' -f1); \
		src="apps/apple/.build/node-cache/node-v$(NODE_VERSION)-darwin-$$arch"; \
		tar -xzf "apps/apple/.build/node-cache/node-v$(NODE_VERSION)-darwin-$$arch.tar.gz" \
			-C apps/apple/.build/node-cache "node-v$(NODE_VERSION)-darwin-$$arch/lib/node_modules/npm"; \
		rm -rf "$(STAGED)/npm"; \
		ditto "$$src/lib/node_modules/npm" "$(STAGED)/npm"
	@echo "  npm $$($(STAGED)/node $(STAGED)/npm/bin/npm-cli.js --version) staged"

bundle: node sparkle ## Build, stage, verify and sign a Release Bastion.app
	@$(MAKE) --no-print-directory app CONFIG=Release \
		XCARGS="$(XCARGS) CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
	@rm -rf "$(RELEASE_APP)/Contents/Resources/node" "$(RELEASE_APP)/Contents/Resources/npm"
	@ditto "$(STAGED)/node" "$(RELEASE_APP)/Contents/Resources/node"
	@ditto "$(STAGED)/npm" "$(RELEASE_APP)/Contents/Resources/npm"
	@# Before signing, not after. A signature over a bundle that cannot install
	@# or start a server is worth nothing, and this is the first point at which
	@# the runtime and the package manager it installs with sit side by side.
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
# The appcast is a RELEASE ASSET, not a site asset, and the enclosure points at the
# tag's own upload. Both halves of that matter. Publishing a release then never
# needs a site deploy, which is the only reason `/appcast.xml` in
# apps/website/public/_redirects can be a permanent 302 — and SUFeedURL is baked
# into every binary ever shipped, so it has to be a URL that outlives any decision
# about where files live. It previously wrote into the site and pointed at
# bastion.mgcrea.io/releases/Bastion-<version>.zip, a path nothing serves.
# The notes are the top CHANGELOG section rendered to HTML by
# scripts/changelog-notes.mjs, because Sparkle renders the description as HTML
# and used to be handed raw markdown, asterisks and all. The renderer escapes
# `]]>`, and xmllint refuses a feed that is not well-formed rather than letting
# every user's updater discover it.
# The update signature comes from the keychain on a developer's Mac and from
# $SPARKLE_ED_PRIVATE_KEY in CI, which has no keychain to have generated one in.
# Both produce the same signature over the same bytes, so the feed stays
# reproducible either way — and the failure that used to be silent is now a
# hard stop: sign_update printing nothing left `sparkle:edSignature=""` in a
# well-formed feed that xmllint happily accepted and every updater refused.
# `stat` is called BSD-first, GNU-second: Homebrew's coreutils puts a GNU `stat`
# ahead of /usr/bin on many machines, where `-f%z` fails with "invalid option"
# and the enclosure came out as length="" — a malformed appcast whose only
# symptom is somebody else's update failing.
appcast: ## Sign the release zip and write a one-item appcast
	@test -f apps/apple/.build/Bastion.zip || { echo "run 'make build-release' first"; exit 1; }
	@version=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		"$(RELEASE_APP)/Contents/Info.plist"); \
	build=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
		"$(RELEASE_APP)/Contents/Info.plist"); \
	length=$$(stat -f%z apps/apple/.build/Bastion.zip 2>/dev/null || stat -c%s apps/apple/.build/Bastion.zip); \
	if [ -n "$$SPARKLE_ED_PRIVATE_KEY" ]; then \
		: "# CI, which has no keychain to have generated the key in. It reaches"; \
		: "# sign_update through a file and never through argv: a private key on"; \
		: "# a command line is readable by every other process via ps."; \
		umask 077; printf '%s' "$$SPARKLE_ED_PRIVATE_KEY" > apps/apple/.build/sparkle.key; \
		raw=$$($(SPARKLE_TOOLS)/sign_update --ed-key-file apps/apple/.build/sparkle.key \
			apps/apple/.build/Bastion.zip); \
		rm -f apps/apple/.build/sparkle.key; \
	else \
		: "# A developer's Mac, where generate_keys put the key in the keychain."; \
		: "# Same signature either way, so a feed can still be produced and read"; \
		: "# locally without exporting the private key to do it."; \
		raw=$$($(SPARKLE_TOOLS)/sign_update apps/apple/.build/Bastion.zip); \
	fi; \
	signature=$$(printf '%s' "$$raw" | sed 's/.*sparkle:edSignature="\([^"]*\)".*/\1/'); \
	test -n "$$signature" && [ "$$signature" != "$$raw" ] \
		|| { echo "  !! sign_update produced no edSignature; not shipping a feed" >&2; exit 1; }; \
	notes=$$(node scripts/changelog-notes.mjs CHANGELOG.md); \
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
		"      <enclosure url=\"https://github.com/mgcrea/bastion/releases/download/app-v$$version/Bastion.zip\"" \
		"                 length=\"$$length\"" \
		"                 type=\"application/octet-stream\"" \
		"                 sparkle:edSignature=\"$$signature\" />" \
		"    </item>" \
		'  </channel>' \
		'</rss>' > apps/apple/.build/appcast.xml
	@xmllint --noout apps/apple/.build/appcast.xml \
		|| { echo "  !! appcast.xml is not well-formed; not shipping it" >&2; rm -f apps/apple/.build/appcast.xml; exit 1; }
	@echo "  wrote apps/apple/.build/appcast.xml"

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

builtin: app ## Assert Bastion's own server: the write gate, and that no tool returns a secret
	@scripts/builtin-check.sh

facade: app ## Assert the tool facade end to end: the saving, the way in, the audit, the gate
	@scripts/facade-check.sh

# The other half of the money loop. A refund or a chargeback marks the row in D1;
# nothing reaches the app until this bakes the list into the next build, because
# the app is not allowed to ask anyone anything at runtime.
revocations: ## Rewrite the baked-in revocation list from D1
	@node scripts/generate-revocations.mjs

# JavaScript mints the keys and Swift accepts them, so the disagreement that
# would cost money lives between the two — and neither side's own tests can see
# it. This one compiles the real License.swift and feeds it real keys.
license-check: ## Prove a minted licence key verifies in the app's own verifier
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/license-check \
		apps/apple/Bastion/License.swift apps/apple/Bastion/Revocations.swift \
		scripts/license-check.swift
	@node --env-file-if-exists=.env scripts/license-check.mjs \
		| apps/apple/.build/license-check

audit-check: ## Prove an export signature survives a round trip, with no app and no Keychain
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/audit-check \
		apps/apple/Bastion/AuditSigning.swift \
		scripts/audit-check.swift
	@apps/apple/.build/audit-check

wiring-check: ## Assert the config merge leaves other people's files alone
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/wiring-check \
		apps/apple/Bastion/ClientWiringMerge.swift \
		apps/apple/Bastion/ClientWiringTOML.swift \
		scripts/wiring-check.swift
	@apps/apple/.build/wiring-check

# Read-only. Parses your actual client configs, merges in memory, and asserts
# every pre-existing key comes back deep-equal. Fixtures only cover the shapes
# somebody thought of; this covers the ones nobody would have invented.
wiring-check-real: wiring-check ## Prove the merge against the real client configs (read-only)
	@apps/apple/.build/wiring-check \
		"$(HOME)/.claude.json" \
		"$(HOME)/Library/Application Support/Claude/claude_desktop_config.json" \
		"$(HOME)/Library/Application Support/Code/User/mcp.json" \
		"$(HOME)/.codex/config.toml"

audit: app remote-check ## Assert the listener is loopback-only and refuses foreign Origin/Host
	@scripts/audit-listener.sh

# The outbound half of the same question. `audit-listener.sh` asserts what may
# reach Bastion; this asserts where Bastion may reach. A remote server's URL is
# the analogue of a command line, so "nothing arriving over the wire can name
# one" needs the same kind of check the spawn rule already has -- including that
# a server cannot be pointed back at Bastion's own gateway, where a client's
# bearer token would be replayed against every other profile.
#
# No running app needed: the rules are a pure function of a URL, and the SSE
# collapse is a pure function of a body. Compiling the two files with the checks
# beside them is the same trade `wiring-check` makes.
# The two files that had no checks and could have.
#
# `Dialect` is the dual-era translation and `HTTP` is a hand-written parser on a
# listening socket. Both were covered only end to end, and end to end is where
# they are hardest to cover: `make dialect` needs a running app AND an installed
# catalog server, so it does not run at all on a machine that has installed
# none, and `audit-listener.sh` only ever sends the parser well-formed requests.
# Malformed input against a parser that runs BEFORE authentication is exactly
# the case worth having, and it needs no app at all.
unit: ## Assert the translation, the parser, call capture, the audit chain, the tool-cost estimate and the tool facade, with no app and no network
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/unit-check \
		apps/apple/Bastion/Dialect.swift \
		apps/apple/Bastion/ServerCatalog.swift \
		apps/apple/Bastion/HTTP.swift \
		apps/apple/Bastion/CallCapture.swift \
		apps/apple/Bastion/ToolReply.swift \
		apps/apple/Bastion/AuditChain.swift \
		apps/apple/Bastion/Log.swift \
		apps/apple/Bastion/ToolCost.swift \
		apps/apple/Bastion/WriteGate.swift \
		apps/apple/Bastion/ToolFacade.swift \
		scripts/unit-check.swift
	@apps/apple/.build/unit-check

remote-check: ## Assert where a remote server may live, the SSE collapse, the write gate, and OAuth
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/remote-check \
		apps/apple/Bastion/RemoteEndpoint.swift \
		apps/apple/Bastion/ServerSentEvents.swift \
		apps/apple/Bastion/WriteGate.swift \
		apps/apple/Bastion/RemoteOAuth.swift \
		apps/apple/Bastion/RemoteOAuthCallback.swift \
		apps/apple/Bastion/Log.swift \
		scripts/remote-check.swift
	@apps/apple/.build/remote-check

# The other half, against REAL remote servers and a running build.
#
# A local fake would have to live on 127.0.0.1, which `RemoteEndpoint` refuses
# by design and must go on refusing -- so rather than add a bypass that would
# delete the property under test, this points at two real endpoints, neither
# needing a credential. mcp.stripe.com answers an unauthenticated `initialize`
# with 401, which exercises DNS pre-flight, https, the POST, the profile's
# headers, the status mapping and the sentence a client is left holding.
# docs.mcp.cloudflare.com answers unauthenticated, so the same path is driven
# through to a real tools/list -- the successful call the Stripe half can
# never prove.
#
# Not in `make audit`: it needs the network, and an audit that fails on a train
# is an audit people learn to skip.
remote-live-check: app ## Assert the remote transport end to end against Stripe (401) and Cloudflare Docs (tools/list)
	@scripts/remote-live-check.sh

# ─── the manifest ────────────────────────────────────────────────────────────

migrate: ## Plan the .mcp.json credential migration (add REPOINT=1 to rewrite them)
	@node scripts/migrate-mcp-json.mjs $(if $(REPOINT),--repoint,--plan)

servers: ## Regenerate every copy of the server list from servers.json
	@node scripts/generate-servers.mjs

servers-check: ## Fail if any generated copy has drifted from servers.json
	@node scripts/generate-servers.mjs --check

# The other direction. `servers-check` asserts every generated copy matches the
# manifest; this asserts the MANIFEST matches the servers it describes, which no
# amount of regenerating can tell you.
#
# The servers written here need the mgcrea-ai checkout; the third-party entries
# need only npm, and are checked against the published tarball Bastion would
# actually install. `--strict` because an entry that could be checked against
# neither is not a passing entry, and reading it as "skipped" is how a green run
# comes to mean less than it looks.
catalog-check: ## Fail if servers.json disagrees with the servers it describes
	@MCP_ROOT="$(MCP_ROOT)" node scripts/catalog-check.mjs --strict

# The other other direction: what is NOT in the catalog. Never run by CI and it
# fails nothing — the catalog is a starting point rather than a closed list, and
# that only stays true if somebody occasionally looks at what has been published
# since. Ranked by monthly downloads, because every directory that ranks MCP
# servers ranks them badly; the script says why in its header.
discover: ## List popular MCP packages on npm that are not in the catalog
	@node scripts/discover-servers.mjs

# ─── the icon ────────────────────────────────────────────────────────────────

# The icon is generated, never hand-drawn: one mark, three renderings. The plate
# lives in the flags rather than the artwork so the .icon layers stay separable.
ICON_MARK    := design/bastion-mark.svg
# '#' opens a comment in a Makefile, so the hexes are spelled through a variable.
HASH         := \#
ICON_PLATE    = $(HASH)FFD08A,$(HASH)F2895C
ICON_RADIUS  := 230
# Two states, not one file: the wall around the fort is the running-server
# glyph, and `MenuBarLabel` swaps them in place.
ICON_MENUBAR := design/bastion-menubar.svg design/bastion-menubar-active.svg

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
	@# The menu bar glyphs are authored, not composed — but each imageset needs
	@# its file *inside* it, so design/ stays the one copy anyone edits.
	@cp design/bastion-menubar.svg \
		apps/apple/Bastion/Assets.xcassets/MenuBarIcon.imageset/
	@cp design/bastion-menubar-active.svg \
		apps/apple/Bastion/Assets.xcassets/MenuBarIconActive.imageset/
	@echo "  copied $(notdir $(ICON_MENUBAR)) into their imagesets"
	@# The website renders its favicon, touch icon and OG card from the same two
	@# files. It reads design/ directly, so nothing is copied — but the PNGs it
	@# derives are committed, and only this command's output makes them stale.
	@echo "  next: pnpm --filter @mgcrea/bastion-website icons"

# ─── app screenshots ─────────────────────────────────────────────────────────

# One tool, `appshot` — never a pile of per-project scripts. Install it with
# `cd ~/Projects/appshot && make install`. The same binary already builds the
# icon above.
#
# `appshot` has no notion of a project root: every path resolves against the
# PROCESS working directory, and nothing is ever resolved relative to the
# config file. That is invisible here because this Makefile lives at the repo
# root and every path below is relative to it — but it is why SHOT_WEBSITE is
# `$(abspath …)` and why nothing in this block should be run by hand from
# inside apps/apple.
#
# A capture run takes over the pointer and the active app at the moment of each
# shot — don't use the machine while it runs, and a stray click can land in an
# image. It needs Screen Recording permission for the TERMINAL running it;
# nothing is granted to Bastion itself. `--wait` queues behind another
# project's run on this Mac instead of failing, which is the ordinary case here
# because cupertino captures on the same machine and the lock has no project
# key.

SHOT_SCREENS := running server log client chat licence

# Dark only. `appshot capture` does not read the config's "appearances" key —
# only `appshot run` does — so it needs its own flag, defaulting to `dark,light`.
SHOT_APPEARANCES := dark

# Everything the plates depend on, passed explicitly.
#
# A flag not passed does not default to off: it falls back to whatever is
# persisted in the CAPTURING MAC's UserDefaults. Each of these is stable on the
# machine that set this up, which is exactly why an omission survives review and
# only shows up when somebody else captures.
#
# -clientKeyPrefix is the one specific to this app. `ClientWiring.prefix` reads
# it straight out of UserDefaults, so a developer who once set `bastion-` gets
# `bastion-shopify` on every entry row of the client plate. Empty is the
# product's default; the quotes are what make the empty string survive the
# shell, and they must stay single because the whole value is already inside
# --extra-args="…".
#
# -AppleShowScrollBars matters more here than in most apps: ServerDetail has an
# outer ScrollView, ClientDetail has that plus a nested 240pt project scroller,
# and `Always` bakes a bar into every one of them.
#
# The accent is deliberately NOT pinned. Assets.xcassets/AccentColor.colorset
# names Bastion's own ramp, so there is nothing ambient left to pin and a
# -AppleAccentColor here would be a flag that does nothing.
SHOT_ARGS := -ScreenshotMode YES \
             -clientKeyPrefix '' \
             -AppleLocale en_US \
             -AppleLanguages '(en)' \
             -AppleHighlightColor '0.698039 0.843137 1.000000 Blue' \
             -AppleShowScrollBars WhenScrolling

# A floor, not the whole wait: appshot then polls frames and shoots once the
# window holds still. Left at appshot's own default because `--ready-file` makes
# it moot — DemoSeed seeds every store synchronously before a window exists, so
# the body running IS the content existing, and the app says so.
SHOT_SETTLE := 0.3

SHOT_DIR      := apps/apple/Screenshots
SHOT_SOURCE   := $(SHOT_DIR)/source
SHOT_GOLDEN   := $(SHOT_DIR)/golden
SHOT_APPSTORE := $(SHOT_DIR)/appstore
SHOT_CONFIG   := $(SHOT_DIR)/screenshots.config.json

# Absolute, because it leaves the tree this Makefile's other paths live in.
# `$(abspath)` is purely lexical and never stats, so a typo here yields a
# plausible wrong path rather than an error — and `compose website` CREATES its
# output directory, so the run would go green having written a full set into a
# directory nobody reads.
#
# Pipeline-owned: `compose website` DELETES every .png in this directory before
# writing, so nothing hand-made may be parked in it.
SHOT_WEBSITE := $(abspath apps/website/src/assets/shots)

# Release, always, and as a target-specific variable so `$(APP)` follows —
# it is recursively expanded and reads $(CONFIG). A Debug build carries the
# `.debug` bundle identifier, and `MainView.sidebarStatus` renders
# "Version 1.0.0 (debug)" from it on all five main-window plates.
# `DemoSeed` also forces `AppInfo.isDebugBuild` false, so a capture taken while
# TUNING is not wrong either — belt and braces, because the failure is silent.
screenshots screenshots-capture: CONFIG := Release

screenshots: app ## Capture, gate against the goldens, and compose both sets
	appshot run \
		--app "$(APP)" \
		--config "$(SHOT_CONFIG)" \
		--source "$(SHOT_SOURCE)" \
		--golden "$(SHOT_GOLDEN)" \
		--appstore-out "$(SHOT_APPSTORE)" \
		--website-out "$(SHOT_WEBSITE)" \
		--screens $(SHOT_SCREENS) \
		--extra-args="$(SHOT_ARGS)" \
		--settle $(SHOT_SETTLE) \
		--ready-file \
		--wait

screenshots-capture: app ## Capture only (no gate, no compose)
	@# --config checks $(SHOT_SCREENS) against the config's screens[].id BEFORE
	@# launching anything, so a typo staging the wrong screen under the right
	@# filename fails now rather than two minutes later.
	@# --extra-args needs the `=`: the value starts with `-`, and without it
	@# ArgumentParser reads it as appshot's own flags.
	appshot capture \
		--app "$(APP)" \
		--out "$(SHOT_SOURCE)" \
		--config "$(SHOT_CONFIG)" \
		--screens $(SHOT_SCREENS) \
		--appearances $(SHOT_APPEARANCES) \
		--extra-args="$(SHOT_ARGS)" \
		--settle $(SHOT_SETTLE) \
		--ready-file \
		--wait

screenshots-check: ## Fail if the captures drifted from the goldens
	@# --config checks the exact expected SET, and it is the only thing that can
	@# see two captures that are the same image — the tell that a
	@# -ScreenshotStage value did nothing and one screen was photographed twice
	@# under two names. Count and file validity say nothing about that, and each
	@# would match its golden, because the golden came from the same broken run.
	@# --require-manifest refuses a baseline nothing can vouch for: `accept`
	@# seals the goldens (sha256 per file, plus who accepted them and with what
	@# arguments) and this verifies the seal before comparing anything.
	appshot check --source "$(SHOT_SOURCE)" --golden "$(SHOT_GOLDEN)" \
		--config "$(SHOT_CONFIG)" --require-manifest

screenshots-update: ## Accept the captures as the new goldens (review the diffs first)
	appshot accept --source "$(SHOT_SOURCE)" --golden "$(SHOT_GOLDEN)"
	@$(MAKE) --no-print-directory screenshots-compose

screenshots-seal: ## Adopt the goldens on disk as the sealed baseline (one-time)
	appshot seal --golden "$(SHOT_GOLDEN)"

screenshots-selftest: ## Prove the golden gate actually fails when it should
	appshot selftest --golden "$(SHOT_GOLDEN)"

screenshots-appstore: ## Compose the framed, captioned visuals
	appshot compose appstore \
		--config "$(SHOT_CONFIG)" --source "$(SHOT_SOURCE)" --out "$(SHOT_APPSTORE)"

screenshots-website: ## Emit bare app captures into apps/website/src/assets/shots
	appshot compose website \
		--config "$(SHOT_CONFIG)" --source "$(SHOT_SOURCE)" --out "$(SHOT_WEBSITE)"

screenshots-compose: screenshots-appstore screenshots-website ## Recompose both sets (no re-capture)

screenshots-doctor: ## Check what fails silently: font, Screen Recording, config
	appshot doctor --config "$(SHOT_CONFIG)"

screenshots-clean: ## Remove generated captures and composites (keeps the goldens)
	@# Deliberately not $(SHOT_WEBSITE): a clean target must not delete another
	@# half of the repo's assets, and only a full capture run regenerates them.
	@rm -rf $(SHOT_SOURCE) $(SHOT_APPSTORE) $(SHOT_DIR)/diff
	@echo "Removed generated screenshots. Goldens in $(SHOT_GOLDEN) kept."

# ─── the workspace ───────────────────────────────────────────────────────────

lint: ## oxlint the JavaScript half
	@pnpm lint

format: format-swift ## oxfmt the repo and swift-format the Swift half
	@pnpm format

format-check: format-swift-check ## Fail on unformatted files
	@pnpm format:check

# The Swift half, which had no formatter at all until this landed while the
# JavaScript half had been under oxfmt from the start.
#
# `xcrun swift-format`, not Homebrew's SwiftFormat: it ships inside the
# toolchain, so every machine that can build the app already has it and there is
# no second tool to install, pin or forget. Config is the committed
# `.swift-format`, which swift-format discovers by walking up from each file —
# no `--configuration` flag needed, and Xcode reads the same file.
#
# The paths are spelled out rather than pointing `-r` at `apps/apple`, and that
# is not tidiness: `.build/` lives under there, and swift-format has no ignore
# file — only `// swift-format-ignore-file` comments in source — so a recursive
# walk from the parent would reformat build artifacts. BastionBridge is one
# file and easy to leave out of this list; leaving it out means it silently
# stops being formatted.
SWIFT_SRC := apps/apple/Bastion apps/apple/BastionBridge scripts

# swift-format's version follows whichever Xcode is selected, so a toolchain bump
# can reformat the whole tree with no change to `.swift-format` and turn this
# gate red on code nobody touched. Assert it, so that day arrives as a sentence
# rather than a mystery diff.
SWIFT_FORMAT_VERSION := 6.3

swift-format-version:
	@v="$$(xcrun swift-format --version)"; \
	case "$$v" in \
	  $(SWIFT_FORMAT_VERSION).*) ;; \
	  *) echo "swift-format $$v, expected $(SWIFT_FORMAT_VERSION).x — the toolchain moved."; \
	     echo "Reformat deliberately and bump SWIFT_FORMAT_VERSION, or select the matching Xcode."; \
	     exit 1;; \
	esac

format-swift: swift-format-version ## swift-format the Swift half
	@xcrun swift-format format --in-place --recursive --parallel $(SWIFT_SRC)

# `--strict` is what makes this a gate: without it lint prints its findings and
# still exits 0, so CI would pass while reporting every violation it found.
format-swift-check: swift-format-version ## Fail on unformatted Swift
	@xcrun swift-format lint --recursive --parallel --strict $(SWIFT_SRC)

# `git blame` walks straight into the reformat commit unless it is told not to,
# and the file that says so is per-clone config, not something the repo can set
# for you. GitHub honours .git-blame-ignore-revs on its own; your terminal does
# not until this runs.
blame-setup: ## Teach git blame to skip the formatting-only commits
	@git config blame.ignoreRevsFile .git-blame-ignore-revs
	@echo "git blame will skip the commits in .git-blame-ignore-revs"

# The JavaScript half's tests: the Worker's vitest suite and the script tests
# under scripts/lib, which include the one asserting the Node minter and the
# Worker produce byte-identical licence keys against the public key compiled
# into the app. CI runs both; this is the same command.
test: ## Run the Worker and script test suites
	@pnpm test

typecheck: ## tsc the Worker and astro check the website
	@pnpm typecheck

.PHONY: help app run stop dev-config clean \
	sparkle sparkle-keys appcast node bundle sign notarize build-release \
	install install-release install-from uninstall \
	smoke dialect builtin wiring-check wiring-check-real remote-check remote-live-check unit license-check revocations audit audit-check migrate servers servers-check catalog-check discover icon \
	screenshots screenshots-capture screenshots-check screenshots-update \
	screenshots-seal screenshots-selftest screenshots-appstore \
	screenshots-website screenshots-compose screenshots-doctor screenshots-clean \
	lint format format-check format-swift format-swift-check swift-format-version blame-setup test typecheck
