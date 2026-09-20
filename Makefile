.PHONY: gen build test install run release clean

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

clean:
	rm -rf $(DERIVED) Packages/VentCore/.build
