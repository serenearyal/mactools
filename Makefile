.PHONY: gen build test install run clean

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
	@echo "installed $(INSTALLED)"

run: install
	open "$(INSTALLED)"

clean:
	rm -rf $(DERIVED) Packages/VentCore/.build
