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
# Maintainer-only: the signing script and runbook are not part of the public
# repo, because they describe this project's specific Apple credentials. Build
# from source with `make build` instead — that needs no certificate.
release:
	@if [ -x ./scripts/build-release.sh ]; then \
		./scripts/build-release.sh; \
	else \
		echo "make release is maintainer-only — the signing script isn't in the public repo."; \
		echo "Use 'make build' to build from source, or download a notarized DMG from:"; \
		echo "  https://github.com/unichat-dev/token-meter/releases"; \
		exit 1; \
	fi

clean:
	rm -rf TokenMeter.xcodeproj build dist
	xcodebuild -scheme TokenMeter clean 2>/dev/null || true
