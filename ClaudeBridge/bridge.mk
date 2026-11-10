# Claude Bridge additions to the upstream Makefile (included from its last line).
# Builds the Go/tsnet static library the runner links against, and rebuilds it
# when the Go sources change.

CB_XCFRAMEWORK := ClaudeBridge/build/ClaudeBridgeTS.xcframework

$(CB_XCFRAMEWORK): ClaudeBridge/go/bridge.go ClaudeBridge/go/go.mod ClaudeBridge/go/go.sum ClaudeBridge/go/build-ios.sh
	@./ClaudeBridge/go/build-ios.sh

build: $(CB_XCFRAMEWORK)

.PHONY: bridge-test
bridge-test:
	cd ClaudeBridge && swift test
	cd ClaudeBridge/go && go test ./...
