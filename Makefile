# Convenience wrapper for the XcodeGen workflow.
.PHONY: bootstrap generate build test clean update-pricing

# Regenerate pricing-feed/pricing.json + the bundled default from upstream.
update-pricing:
	python3 pricing-feed/generate_pricing.py

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

clean:
	rm -rf TokenMeter.xcodeproj
	xcodebuild -scheme TokenMeter clean 2>/dev/null || true
