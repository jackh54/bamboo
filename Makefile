# Common tasks. `make run` builds everything and launches a debug build.
# Build output stays out of ~/Documents: macOS asks for folder access every time a
# freshly signed Bamboo loads its test bundle from a protected folder.
DERIVED := $(HOME)/Library/Developer/Xcode/DerivedData/Bamboo
APP := $(DERIVED)/Build/Products/Debug/Bamboo.app

.PHONY: core project app run test test-rust test-app lint clean

core:
	scripts/build-core.sh

project:
	cd app && xcodegen generate --quiet

app: core project
	xcodebuild -project app/Bamboo.xcodeproj -scheme Bamboo -configuration Debug \
		-derivedDataPath $(DERIVED) BAMBOO_SKIP_CORE_BUILD=1 build | xcbeautify 2>/dev/null || \
	xcodebuild -project app/Bamboo.xcodeproj -scheme Bamboo -configuration Debug \
		-derivedDataPath $(DERIVED) BAMBOO_SKIP_CORE_BUILD=1 build -quiet

run: app
	open $(APP)

test: test-rust test-app

test-rust:
	cargo test --workspace

test-app: core project
	xcodebuild -project app/Bamboo.xcodeproj -scheme Bamboo -derivedDataPath $(DERIVED) \
		BAMBOO_SKIP_CORE_BUILD=1 test -quiet

lint:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets -- -D warnings

clean:
	cargo clean
	rm -rf build app/Bamboo.xcodeproj app/Bamboo/Generated
