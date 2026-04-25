BUNDLE_ID ?= com.parassharmaa.cua-mcp
APP_NAME ?= CuaMcp
VERSION ?= 0.1.0
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build release app sign clean test eval format lint dist install uninstall

SWIFT_FORMAT := $(shell command -v swift-format 2>/dev/null || \
                        ls /opt/homebrew/var/homebrew/tmp/.cellar/swift-format/*/bin/swift-format 2>/dev/null | head -1)

format:
	@test -x "$(SWIFT_FORMAT)" || { echo "swift-format not found. brew install swift-format"; exit 1; }
	$(SWIFT_FORMAT) format --in-place --recursive --configuration .swift-format Sources/

lint:
	@test -x "$(SWIFT_FORMAT)" || { echo "swift-format not found. brew install swift-format"; exit 1; }
	$(SWIFT_FORMAT) lint --recursive --configuration .swift-format Sources/

build:
	swift build

release:
	swift build -c release

test: release
	$(BUILD_DIR)/cua-mcp eval

eval: release
	$(BUILD_DIR)/cua-mcp eval

app: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/cua-mcp $(APP_BUNDLE)/Contents/MacOS/cua-mcp
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>cua-mcp</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>$(BUNDLE_ID)</string>\n\t<key>CFBundleName</key>\n\t<string>$(APP_NAME)</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>$(VERSION)</string>\n\t<key>CFBundleVersion</key>\n\t<string>$(VERSION)</string>\n\t<key>LSUIElement</key>\n\t<true/>\n\t<key>LSMinimumSystemVersion</key>\n\t<string>13.0</string>\n\t<key>LSEnvironment</key>\n\t<dict>\n\t\t<key>CUA_MCP_UI_MODE</key>\n\t\t<string>1</string>\n\t</dict>\n\t<key>NSAccessibilityUsageDescription</key>\n\t<string>Needed to read the accessibility tree of target apps and post synthetic clicks and keystrokes on your behalf.</string>\n\t<key>NSScreenCaptureUsageDescription</key>\n\t<string>Needed to take screenshots of the target app as part of get_app_state.</string>\n\t<key>NSAppleEventsUsageDescription</key>\n\t<string>Optional fallback for a few apps whose state is easier to reach via AppleScript.</string>\n</dict>\n</plist>\n' > $(APP_BUNDLE)/Contents/Info.plist
	@echo "Bundle built at $(APP_BUNDLE)"
	@echo "  Double-click to open UI (permission flow)."
	@echo "  Use $(APP_BUNDLE)/Contents/MacOS/cua-mcp as the MCP client command."

sign: app
	codesign --force --sign - --deep $(APP_BUNDLE)
	codesign -dvvv $(APP_BUNDLE) 2>&1 | head -8
	@echo "Ad-hoc signed. For stable TCC grants use a Developer ID identity instead of -."

INSTALL_PATH := /Applications/CuaMcp.app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

install: sign
	@echo "Installing to $(INSTALL_PATH)…"
	@# Remove stale LaunchServices entries for any previous build paths so
	@# macOS always opens the install in /Applications. Otherwise `open`
	@# can silently launch an older build with an invalid TCC grant.
	-$(LSREGISTER) -u "$(INSTALL_PATH)" 2>/dev/null || true
	-$(LSREGISTER) -u "$(APP_BUNDLE)" 2>/dev/null || true
	-pkill -9 -f "CuaMcp.app/Contents" 2>/dev/null || true
	rm -rf "$(INSTALL_PATH)"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_PATH)"
	$(LSREGISTER) -f "$(INSTALL_PATH)"
	@echo ""
	@echo "Installed. Open from /Applications or run:"
	@echo "  open $(INSTALL_PATH)"
	@echo ""
	@echo "MCP client command path (stable across rebuilds):"
	@echo "  $(INSTALL_PATH)/Contents/MacOS/cua-mcp"
	@echo ""
	@echo "If permissions are flaky after re-install, run: make uninstall && make install"

uninstall:
	-pkill -9 -f "CuaMcp.app/Contents" 2>/dev/null || true
	-$(LSREGISTER) -u "$(INSTALL_PATH)" 2>/dev/null || true
	rm -rf "$(INSTALL_PATH)"
	@echo "Removed $(INSTALL_PATH). You may also need to remove stale TCC entries:"
	@echo "  System Settings → Privacy & Security → Accessibility / Screen Recording"

clean:
	rm -rf .build dist

dist: sign
	rm -rf dist
	mkdir -p dist/mac-cua-mcp-$(VERSION)/docs
	cp -R $(APP_BUNDLE) dist/mac-cua-mcp-$(VERSION)/
	cp README.md PLAN.md STATUS.md CLAUDE.md dist/mac-cua-mcp-$(VERSION)/ 2>/dev/null || true
	printf '{\n  "mcpServers": {\n    "mac-cua": {\n      "command": "%s"\n    }\n  }\n}\n' "$$(pwd)/dist/mac-cua-mcp-$(VERSION)/$(APP_NAME).app/Contents/MacOS/cua-mcp" > dist/mac-cua-mcp-$(VERSION)/example.mcp.json
	cd dist && zip -qr mac-cua-mcp-$(VERSION).zip mac-cua-mcp-$(VERSION)
	@ls -lh dist/mac-cua-mcp-$(VERSION).zip
	@echo ""
	@echo "Dist bundle ready:"
	@echo "  dist/mac-cua-mcp-$(VERSION).zip"
	@echo "  dist/mac-cua-mcp-$(VERSION)/"
	@echo "    $(APP_NAME).app     ad-hoc signed, ready to install"
	@echo "    README.md           project overview"
	@echo "    PLAN.md             architecture + invariants"
	@echo "    STATUS.md           latest eval results"
	@echo "    CLAUDE.md           conventions for future edits"
	@echo "    example.mcp.json    MCP client registration example"
