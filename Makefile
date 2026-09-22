.PHONY: gen build test install run release clean window-selftest

PROJECT      := MacTools.xcodeproj
SCHEME       := MacTools
CONFIG       := Debug
DERIVED      := $(CURDIR)/build
PRODUCTS     := $(DERIVED)/Build/Products/$(CONFIG)
APP          := $(PRODUCTS)/MacTools.app
INSTALLED    := /Applications/MacTools.app
DESTINATION  := platform=macOS,arch=arm64

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	-derivedDataPath $(DERIVED) -destination '$(DESTINATION)'

gen:
	xcodegen generate

$(PROJECT):
	$(MAKE) gen

build: $(PROJECT)
	$(XCODEBUILD) build

test: $(PROJECT)
	swift test --package-path Packages/MacToolsCore
	$(XCODEBUILD) test

install: build
	@test -d "$(APP)" || { echo "error: $(APP) is missing"; exit 1; }
	codesign --verify --strict "$(APP)"
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	@echo "installed $(INSTALLED) ($(CONFIG))"
	@# An instance that was already running keeps the old binary in memory, and
	@# `open` on a running app starts nothing. Restart it AFTER the copy, in
	@# the background, so the user is never left on the build before this one.
	@pid=$$(pgrep -f "^$(INSTALLED)/Contents/MacOS/MacTools" | head -1); \
	if [ -n "$$pid" ]; then \
		kill $$pid; \
		while kill -0 $$pid 2>/dev/null; do /bin/sleep 0.2; done; \
		open -g "$(INSTALLED)"; \
		echo "restarted the running MacTools in the background"; \
	fi

# The shipping build: optimised, hardened runtime, signed with the same Apple
# Development identity as everything else. There is no Developer ID on this
# machine, so the result is not notarized and Gatekeeper will refuse it on any
# other Mac; `make install CONFIG=Release` is how it is used here.
release:
	$(MAKE) build CONFIG=Release
	@test -d "$(DERIVED)/Build/Products/Release/MacTools.app" \
		|| { echo "error: the Release app is missing"; exit 1; }
	codesign --verify --strict --verbose=2 "$(DERIVED)/Build/Products/Release/MacTools.app"
	codesign --verify --strict --verbose=2 \
		"$(DERIVED)/Build/Products/Release/MacTools.app/Contents/MacOS/MacToolsHelper"
	@echo ""
	@echo "release app: $(DERIVED)/Build/Products/Release/MacTools.app"
	@du -sh "$(DERIVED)/Build/Products/Release/MacTools.app" | cut -f1 | xargs echo "size:      "
	@echo "not notarized: this machine has no Developer ID certificate."

# A disk image with the Release app and an Applications shortcut, plus its
# SHA-256. Signed with whatever identity the build used: without a Developer
# ID certificate it is not notarized, and `release` says so above.
DMG = $(DERIVED)/MacTools-$(VERSION).dmg
VERSION = $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(DERIVED)/Build/Products/Release/MacTools.app/Contents/Info.plist" 2>/dev/null || echo dev)
dmg: release
	rm -rf "$(DERIVED)/dmg-root" "$(DMG)"
	mkdir -p "$(DERIVED)/dmg-root"
	ditto "$(DERIVED)/Build/Products/Release/MacTools.app" "$(DERIVED)/dmg-root/MacTools.app"
	ln -s /Applications "$(DERIVED)/dmg-root/Applications"
	hdiutil create -volname "MacTools" -srcfolder "$(DERIVED)/dmg-root" -ov -format UDZO -quiet "$(DMG)"
	@if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then \
		codesign --sign "Developer ID Application" --timestamp "$(DMG)"; \
	fi
	shasum -a 256 "$(DMG)" | tee "$(DMG).sha256"
	@echo "dmg: $(DMG)"

run: install
	open "$(INSTALLED)"

# The window mover against a real accessibility server.
#
# It runs the app built here, never the installed one, and it drives one probe
# window of ours: no window of the user's is touched, and nothing takes the
# front. Accessibility is granted by code identity, so this build inherits the
# grant of com.serenearyal.mactools.
SELFTEST_DIR := $(DERIVED)/selftest
PROBE        := $(PRODUCTS)/MacToolsAXProbe.app

window-selftest: build
	@test -d "$(PROBE)" || { echo "error: $(PROBE) is missing"; exit 1; }
	@rm -f "$(SELFTEST_DIR)/window-selftest.txt"
	@mkdir -p "$(SELFTEST_DIR)"
	open -g -n "$(APP)" --args --no-activate \
		--window-selftest "$(PROBE)" --window-selftest-out "$(SELFTEST_DIR)"
	@for i in $$(seq 1 60); do \
		test -f "$(SELFTEST_DIR)/window-selftest.txt" && break; \
		sleep 1; \
	done
	@test -f "$(SELFTEST_DIR)/window-selftest.txt" \
		|| { echo "error: the self test wrote no table"; exit 1; }
	@cat "$(SELFTEST_DIR)/window-selftest.txt"
	@grep -q "WINDOW SELFTEST: PASS" "$(SELFTEST_DIR)/window-selftest.txt"

clean:
	rm -rf $(DERIVED) Packages/MacToolsCore/.build
