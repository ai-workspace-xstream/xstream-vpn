.PHONY: help check-flutter check-go check-macos check-git-submodules \
	pub-get prepare-macos sync-macos-config clean-macos \
	build-macos-arm64 build-macos-x64 package-mac
help: ## Show this help message
	@echo "XStream VPN Build System"
	@echo ""
	@echo "Usage: make <target> [ARCH=<arch>]"
	@echo ""
	@echo "Platform targets:"
	@echo "  package-mac        Build macOS release + DMG (native arch)"
	@echo "  build-macos-arm64   Build macOS ARM64 release + DMG"
	@echo "  build-macos-x64     Build macOS x64 release + DMG"
	@echo "  build-windows-x64   Build Windows x64 release"
	@echo "  build-linux-x64     Build Linux x64 release"
	@echo "  build-ios-ipa       Build iOS IPA (requires macOS)"
	@echo "  build-android-apk   Build Android APK"
	@echo ""
	@echo "Utility targets:"
	@echo "  analyze             Run Flutter static analysis"
	@echo "  format              Format Dart code"
	@echo "  clean               Clean build artifacts"
	@echo "  sync-macos-config   Sync pubspec.yaml version to macOS config"



DIR := $(shell pwd)
FLUTTER := flutter
GO := go

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

VERSION := $(shell grep "^version:" pubspec.yaml | cut -d: -f2 | tr -d ' ')
BUILD := $(shell echo "$(VERSION)" | cut -d+ -f2)
MAJOR := $(shell echo "$(VERSION)" | cut -d. -f1)
MINOR := $(shell echo "$(VERSION)" | cut -d. -f2)
PATCH := $(shell echo "$(VERSION)" | cut -d. -f3 | cut -d+ -f1)

BRANCH := $(shell git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_ID := $(shell git rev-parse --short HEAD 2>/dev/null || echo "0000000")
BUILD_DATE := $(shell date '+%Y-%m-%d')

MAKE_SCRIPT_DIR := scripts/make
RUN_TARGET_SCRIPT := $(MAKE_SCRIPT_DIR)/run-target.sh

DMG_TAG := $(shell git describe --tags --exact-match 2>/dev/null || echo "")
DMG_NAME := $(shell \
	if [ "$(DMG_TAG)" != "" ]; then \
		echo "xstream-release-$(DMG_TAG).dmg"; \
	else \
		echo "xstream-dev-$(BUILD_ID).dmg"; \
	fi)

DART_DEFINES := --dart-define=BRANCH_NAME=$(BRANCH) --dart-define=BUILD_ID=$(BUILD_ID) --dart-define=BUILD_DATE=$(BUILD_DATE)

export PATH := /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$(PATH)

$(shell mkdir -p build/linux/x64/release/bundle/lib)
$(shell mkdir -p build/windows/x64/runner/Release)
$(shell mkdir -p build/app/outputs/flutter-apk)
$(shell mkdir -p build/ios/ipa)
$(shell mkdir -p build/ios/iphoneos)

check-flutter:
	@which $(FLUTTER) >/dev/null 2>&1 || { echo "Flutter not found. Install Flutter SDK first."; exit 1; }

check-go:
	@which $(GO) >/dev/null 2>&1 || { echo "Go not found. Install Go 1.20+ first."; exit 1; }

check-macos:
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo "This target requires macOS"; \
		exit 1; \
	fi

check-git-submodules:
	@if [ ! -d "libXray" ] || [ ! -f "libXray/go.mod" ]; then \
		echo "libXray submodule not initialized. Run:"; \
		echo "  git submodule update --init --recursive libXray"; \
		exit 1; \
	fi

pub-get: check-flutter
	$(FLUTTER) pub get

# Generate Flutter's plugin symlinks before any Xcode/macOS build. Without
# this dependency Xcode cannot resolve modules such as device_info_plus and
# shared_preferences_foundation when the build is started from Xcode.
prepare-macos: pub-get check-macos
	@echo ">>> Installing macOS CocoaPods dependencies..."
	@command -v pod >/dev/null 2>&1 || { echo "CocoaPods not found. Install with: brew install cocoapods"; exit 1; }
	@cd macos && LANG=en_US.UTF-8 pod install

sync-macos-config: check-flutter check-macos
	@echo ">>> Syncing version $(VERSION)+$(BUILD) to macOS config"
	$(FLUTTER) pub get
	@cd macos && \
		$(FLUTTER) build macos --version 2>/dev/null || true

clean-macos: check-flutter check-macos
	@echo ">>> Cleaning Flutter caches..."
	$(FLUTTER) clean
	@echo ">>> Fetching dependencies..."
	$(FLUTTER) pub get
	@echo ">>> Regenerating macOS config..."
	$(FLUTTER) build macos --config-only
	@echo ">>> Installing CocoaPods..."
	cd macos && LANG=en_US.UTF-8 pod install
	@echo ">>> Done. Please open macos/Runner.xcworkspace in Xcode to build."

build-macos-arm64: check-flutter check-macos check-git-submodules prepare-macos
	@UNAME_S="$(UNAME_S)" UNAME_M="$(UNAME_M)" FLUTTER="$(FLUTTER)" \
		BRANCH="$(BRANCH)" BUILD_ID="$(BUILD_ID)" BUILD_DATE="$(BUILD_DATE)" \
		DMG_NAME="$(DMG_NAME)" \
		"$(RUN_TARGET_SCRIPT)" macos-arm64

build-macos-x64: check-flutter check-macos check-git-submodules prepare-macos
	@UNAME_S="$(UNAME_S)" UNAME_M="$(UNAME_M)" FLUTTER="$(FLUTTER)" \
		BRANCH="$(BRANCH)" BUILD_ID="$(BUILD_ID)" BUILD_DATE="$(BUILD_DATE)" \
		DMG_NAME="$(DMG_NAME)" \
		"$(RUN_TARGET_SCRIPT)" macos-intel

package-mac: check-flutter check-macos check-git-submodules prepare-macos ## Build macOS release + DMG (native arch)
	@if [ "$(UNAME_M)" = "arm64" ]; then \
		$(MAKE) build-macos-arm64; \
	elif [ "$(UNAME_M)" = "x86_64" ]; then \
		$(MAKE) build-macos-x64; \
	else \
		echo "Unsupported macOS architecture: $(UNAME_M)"; \
		exit 1; \
	fi

build-windows-x64: check-flutter check-go
	@echo ">>> Building Windows x64 release"
	./build_scripts/build_windows.sh
	$(FLUTTER) build windows --release $(DART_DEFINES)
	@cp bindings/libgo_native_bridge.dll build/windows/x64/runner/Release/ 2>/dev/null || true
	@echo ">>> Build complete: build/windows/x64/runner/Release/xstream.exe"

build-linux-x64: check-flutter check-go
	@echo ">>> Building Linux x64 release"
	./build_scripts/build_linux.sh
	CC=/snap/flutter/current/usr/bin/clang \
	CXX=/snap/flutter/current/usr/bin/clang++ \
	$(FLUTTER) build linux --release -v $(DART_DEFINES)
	@cp linux/lib/libgo_native_bridge.so build/linux/x64/release/bundle/lib/ 2>/dev/null || true
	@echo ">>> Build complete: build/linux/x64/release/bundle/xstream"

build-ios-ipa: check-flutter check-macos check-git-submodules
	@echo ">>> Building iOS IPA"
	./build_scripts/build_ios_ipa.sh
	@echo ">>> IPA ready: build/ios/ipa/XStream.ipa"

build-android-apk: check-flutter check-go check-git-submodules
	@echo ">>> Building Android APK"
	./build_scripts/build_android_apk.sh
	@echo ">>> APK ready: build/app/outputs/flutter-apk/app-release.apk"

analyze: check-flutter
	$(FLUTTER) analyze

format: check-flutter
	$(FLUTTER) format .

clean:
	$(FLUTTER) clean
	rm -rf build/
	rm -rf linux/lib/
	rm -rf bindings/libgo_native_bridge.*
	rm -rf android/app/src/main/jniLibs/
	rm -rf ios/Flutter/Flutter.framework
	rm -rf ios/Flutter/Flutter.podspec
	rm -rf ios/Flutter/App.framework
	rm -rf .dart_tool/
	rm -rf *.lock
	find . -name "*.g.dart" ! -path "./lib/app/darwin_host_api.g.dart" -delete 2>/dev/null || true
	find . -name "*.freezed.dart" -delete 2>/dev/null || true

package-linux-deb:
	./build_scripts/package_linux_deb.sh

package-linux-rpm:
	./build_scripts/package_linux_rpm.sh

package-linux-bundle:
	./build_scripts/package_linux_bundle.sh

package-windows-bundle:
	pwsh -File ./build_scripts/package_windows_bundle.ps1

package-windows-msi:
	pwsh -File ./build_scripts/package_windows_msi.ps1

package-android-apk:
	$(FLUTTER) build apk --release $(DART_DEFINES)

test:
	$(FLUTTER) test

run:
	$(FLUTTER) run
