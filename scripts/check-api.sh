#!/usr/bin/env bash
# The public API, as the compiler sees it, compared with api/TraceSDK.swiftinterface. Run from the repository root.
#
# A change to anything public shows up in a pull request's diff, so it is reviewed as an API change rather than
# noticed by a customer. After a deliberate change, run `scripts/check-api.sh --update` and commit the file.
#
# Built for the iOS simulator, because the SDK ships for iOS and some of its surface exists only there. The header
# comments and imports are left out: they name the compiler and its implicit modules, which move with Xcode.
set -euo pipefail

committed=api/TraceSDK.swiftinterface

swift build \
  --triple arm64-apple-ios16.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  --scratch-path .build/api \
  -Xswiftc -enable-library-evolution \
  -Xswiftc -emit-module-interface >&2

current=$(grep -vE '^(// swift-|import )' .build/api/arm64-apple-ios-simulator/debug/TraceSDK.build/TraceSDK.swiftinterface)

if [ "${1:-}" = "--update" ]; then
  printf '%s\n' "$current" > "$committed"
  echo "Wrote $committed."
  exit 0
fi

if ! diff -u "$committed" <(printf '%s\n' "$current"); then
  echo "::error::The public API changed. If that was meant, run scripts/check-api.sh --update and commit $committed." >&2
  exit 1
fi
echo "The public API matches $committed."
