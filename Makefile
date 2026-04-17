BUNDLE_ID ?= com.parassharmaa.cua-mcp
APP_NAME ?= CuaMcp
VERSION ?= 0.1.0
BUILD_DIR := .build/release
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build release app sign clean test perf bench report dist

build:
	swift build

release:
	swift build -c release

test: release
	python3 -u harness/run_all.py

perf: release
	python3 -u harness/test_perf.py

bench: perf
	python3 -u harness/test_input_latency.py
	python3 -u harness/test_stability.py

report: release
	python3 -u harness/run_all.py
	@echo "Report written to harness/REPORT.md"

app: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BUILD_DIR)/cua-mcp $(APP_BUNDLE)/Contents/MacOS/cua-mcp
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleExecutable</key>\n\t<string>cua-mcp</string>\n\t<key>CFBundleIdentifier</key>\n\t<string>$(BUNDLE_ID)</string>\n\t<key>CFBundleName</key>\n\t<string>$(APP_NAME)</string>\n\t<key>CFBundleShortVersionString</key>\n\t<string>$(VERSION)</string>\n\t<key>CFBundleVersion</key>\n\t<string>$(VERSION)</string>\n\t<key>LSUIElement</key>\n\t<true/>\n\t<key>LSMinimumSystemVersion</key>\n\t<string>13.0</string>\n\t<key>NSAccessibilityUsageDescription</key>\n\t<string>Needed to read the accessibility tree of target apps and post synthetic clicks and keystrokes on your behalf.</string>\n\t<key>NSScreenCaptureUsageDescription</key>\n\t<string>Needed to take screenshots of the target app as part of get_app_state.</string>\n\t<key>NSAppleEventsUsageDescription</key>\n\t<string>Optional fallback for a few apps whose state is easier to reach via AppleScript.</string>\n</dict>\n</plist>\n' > $(APP_BUNDLE)/Contents/Info.plist
	@echo "Bundle built at $(APP_BUNDLE)"

sign: app
	codesign --force --sign - --deep $(APP_BUNDLE)
	codesign -dvvv $(APP_BUNDLE) 2>&1 | head -8
	@echo "Ad-hoc signed. For stable TCC grants use a Developer ID identity instead of -."

clean:
	rm -rf .build dist

dist: sign
	rm -rf dist
	mkdir -p dist/mac-cua-mcp-$(VERSION)/docs
	cp -R $(APP_BUNDLE) dist/mac-cua-mcp-$(VERSION)/
	cp README.md NOTES.md dist/mac-cua-mcp-$(VERSION)/
	cp harness/HARNESS.md harness/REPORT.md dist/mac-cua-mcp-$(VERSION)/docs/ 2>/dev/null || true
	printf '{\n  "mcpServers": {\n    "mac-cua": {\n      "command": "%s"\n    }\n  }\n}\n' "$$(pwd)/dist/mac-cua-mcp-$(VERSION)/$(APP_NAME).app/Contents/MacOS/cua-mcp" > dist/mac-cua-mcp-$(VERSION)/example.mcp.json
	cd dist && zip -qr mac-cua-mcp-$(VERSION).zip mac-cua-mcp-$(VERSION)
	@ls -lh dist/mac-cua-mcp-$(VERSION).zip
	@echo ""
	@echo "Dist bundle ready:"
	@echo "  dist/mac-cua-mcp-$(VERSION).zip"
	@echo "  dist/mac-cua-mcp-$(VERSION)/"
	@echo "    $(APP_NAME).app     ad-hoc signed, ready to install"
	@echo "    README.md           project overview"
	@echo "    NOTES.md            Sky CUA reverse-engineering notes"
	@echo "    example.mcp.json    MCP client registration example"
	@echo "    docs/HARNESS.md     comparator harness catalog"
	@echo "    docs/REPORT.md      last run_all.py scoreboard"
