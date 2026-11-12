PKG = Packages/HeadsetKit

.PHONY: build test check docs app dist preview clean

build:
	swift build --package-path $(PKG)

test:
	swift test --package-path $(PKG)

# What CI runs: tests, a release build of the app, and a smoke test of the command line.
# Nothing here launches Sennsei.app. With the app not running, `status` must exit 3 (app not
# running); if a copy happens to be running on this Mac it answers with exit 0 instead.
check: test app
	build/sennsei --help > /dev/null
	build/sennsei --version
	@if pgrep -x SennseiApp > /dev/null; then want=0; else want=3; fi; \
	build/sennsei status > /dev/null 2>&1; code=$$?; \
	if [ $$code -ne $$want ]; then echo "error: 'sennsei status' exited $$code, expected $$want"; exit 1; fi
	@build/sennsei noise loud > /dev/null 2>&1; code=$$?; \
	if [ $$code -ne 2 ]; then echo "error: 'sennsei noise loud' exited $$code, expected 2 (usage error)"; exit 1; fi

# README and documentation checks. Needs build/sennsei, so run it after `make check` or `make app`.
docs:
	scripts/check-docs.sh

app:
	bash Tools/app/build_app.sh

# Release artifacts for a version, without publishing: make dist VERSION=1.2.3
dist:
	@test -n "$(VERSION)" || { echo "usage: make dist VERSION=1.2.3"; exit 2; }
	scripts/package-release.sh $(VERSION)

# Screenshots for the README, drawn from invented sample data (no headphones, no Bluetooth, nothing read from
# the real app). Only runs the binary with --render-previews, which exits by itself.
preview:
	swift build --package-path $(PKG) -c release --product SennseiApp
	mkdir -p build/preview docs/images
	$(shell swift build --package-path $(PKG) -c release --show-bin-path)/SennseiApp --render-previews build/preview -AppleLanguages "(en)" -AppleLocale en_US
	cp build/preview/hero.png build/preview/panel.png build/preview/insights.png build/preview/shortcuts.png build/preview/social-preview.png docs/images/

clean:
	rm -rf .build $(PKG)/.build build dist
