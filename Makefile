.PHONY: help run build-linux dev-android build-apk bridge test test-rust test-flutter test-integration clean

# If already inside `nix develop`, run commands directly.
# Otherwise wrap with `nix develop --command` so the toolchain is available.
ifdef IN_NIX_SHELL
  NX = bash -c
else
  NX = nix develop --command bash -c
endif

help: ## Show available targets
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Linux ────────────────────────────────────────────────────────────────────

run: ## Build Rust (debug) and run on Linux desktop
	$(NX) "cd rust && cargo build && cd ../flutter_app && flutter run -d linux"

build-linux: ## Build Rust (release) and package Flutter for Linux
	$(NX) "cd rust && cargo build --release && cd ../flutter_app && flutter build linux --release"
	@echo ""
	@echo "Output: flutter_app/build/linux/x64/release/bundle/"

# ── Android ──────────────────────────────────────────────────────────────────

dev-android: ## Cross-compile Rust for arm64 and run Flutter on connected device
	$(NX) "cd rust && ./build_android.sh && cd ../flutter_app && flutter run"

build-apk: ## Cross-compile Rust for arm64 and build a release APK
	$(NX) "cd rust && ./build_android.sh && cd ../flutter_app && flutter build apk"
	@echo ""
	@echo "Output: flutter_app/build/app/outputs/flutter-apk/app-release.apk"

# ── Bridge ───────────────────────────────────────────────────────────────────

bridge: ## Regenerate Flutter↔Rust bridge (run after editing rust/src/api.rs)
	./generate_bridge.sh

# ── Tests ────────────────────────────────────────────────────────────────────

test: test-rust test-flutter ## Run all tests

test-rust: ## Run Rust unit tests
	$(NX) "cd rust && cargo test"

test-flutter: ## Run Flutter unit tests
	$(NX) "cd flutter_app && flutter test"

test-integration: ## Run Flutter integration tests (requires a running device/emulator)
	$(NX) "cd flutter_app && flutter test integration_test/"

# ── Maintenance ───────────────────────────────────────────────────────────────

clean: ## Remove Flutter build artefacts
	$(NX) "cd flutter_app && flutter clean"
