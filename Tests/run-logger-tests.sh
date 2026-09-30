#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/usbprober-logger-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun clang -fno-objc-arc -Wno-deprecated-declarations -I. -framework Cocoa -framework IOKit \
    USBLogger.m USBLoggerController.m Tests/USBLoggerTests.m -o "$test_dir/USBLoggerTests"
"$test_dir/USBLoggerTests" "$@"
