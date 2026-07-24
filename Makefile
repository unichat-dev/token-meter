# Convenience wrapper for the XcodeGen workflow.
.PHONY: bootstrap generate build test clean update-pricing release icon

# Regenerate pricing-feed/pricing.json + the bundled default from upstream.
update-pricing:
	python3 pricing-feed/generate_pricing.py

# Regenerate the macOS app icon set (proper squircle + margin) from source.
icon:
	python3 scripts/generate_appicon.py

# One-time setup after cloning.
bootstrap:
	brew install xcodegen gitleaks
	git config core.hooksPath .githooks
	$(MAKE) generate

# Regenerate TokenMeter.xcodeproj from project.yml (run after pulling changes).
generate:
	xcodegen generate

build: generate
	xcodebuild -scheme TokenMeter -destination 'platform=macOS' build

test: generate
	xcodebuild -scheme TokenMeter -destination 'platform=macOS' test

# Build a signed, notarized Developer ID DMG for direct download.
# Requires a Developer ID cert + a stored notarytool profile (see docs/RELEASE.md).
release:
	./scripts/build-release.sh

clean:
	rm -rf TokenMeter.xcodeproj build dist
	xcodebuild -scheme TokenMeter clean 2>/dev/null || true
