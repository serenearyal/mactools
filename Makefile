.PHONY: gen build test install run release clean window-selftest

PROJECT      := Vent.xcodeproj
SCHEME       := Vent
CONFIG       := Debug
DERIVED      := $(CURDIR)/build
PRODUCTS     := $(DERIVED)/Build/Products/$(CONFIG)
APP          := $(PRODUCTS)/Vent.app
INSTALLED    := /Applications/Vent.app
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
	swift test --package-path Packages/VentCore
	$(XCODEBUILD) test

install: build
	@test -d "$(APP)" || { echo "error: $(APP) is missing"; exit 1; }
	codesign --verify --strict "$(APP)"
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	@echo "installed $(INSTALLED) ($(CONFIG))"

# The shipping build: optimised, hardened runtime, signed with the same Apple
# Development identity as everything else. There is no Developer ID on this
# machine, so the result is not notarized and Gatekeeper will refuse it on any
# other Mac; `make install CONFIG=Release` is how it is used here.
release:
	$(MAKE) build CONFIG=Release
	@test -d "$(DERIVED)/Build/Products/Release/Vent.app" \
		|| { echo "error: the Release app is missing"; exit 1; }
	codesign --verify --strict --verbose=2 "$(DERIVED)/Build/Products/Release/Vent.app"
	codesign --verify --strict --verbose=2 \
		"$(DERIVED)/Build/Products/Release/Vent.app/Contents/MacOS/VentHelper"
	@echo ""
	@echo "release app: $(DERIVED)/Build/Products/Release/Vent.app"
	@du -sh "$(DERIVED)/Build/Products/Release/Vent.app" | cut -f1 | xargs echo "size:      "
	@echo "not notarized: this machine has no Developer ID certificate."

run: install
	open "$(INSTALLED)"

# The window mover against a real accessibility server.
#
# It runs the app built here, never the installed one, and it drives one probe
# window of ours: no window of the user's is touched, and nothing takes the
# front. Accessibility is granted by code identity, so this build inherits the
# grant of com.serenearyal.vent.
SELFTEST_DIR := $(DERIVED)/selftest
PROBE        := $(PRODUCTS)/VentAXProbe.app

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
	rm -rf $(DERIVED) Packages/VentCore/.build
