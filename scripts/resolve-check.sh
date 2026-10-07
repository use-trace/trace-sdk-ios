#!/usr/bin/env bash
# Builds a throwaway package that depends on this one by its GitHub URL, the way a customer's app does, so a release
# is proved to resolve and build. Used by release.yml.
#
#   scripts/resolve-check.sh <version>            the tag, exactly
#   scripts/resolve-check.sh --revision <commit>  a pushed commit (the dry run, before any tag exists)
set -euo pipefail
if [ "$1" = --revision ]; then
  requirement="revision: \"$2\""
else
  requirement="exact: \"$1\""
fi
dir=$(mktemp -d)
mkdir -p "$dir/Sources/ResolveCheck"
cat > "$dir/Package.swift" <<SWIFT
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ResolveCheck",
    platforms: [.iOS(.v16), .macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/use-trace/trace-sdk-ios", $requirement),
    ],
    targets: [
        .target(name: "ResolveCheck", dependencies: [.product(name: "TraceSDK", package: "trace-sdk-ios")]),
    ]
)
SWIFT
# Naming the public API makes the build fail unless the package that resolved is the SDK.
cat > "$dir/Sources/ResolveCheck/Check.swift" <<'SWIFT'
import TraceSDK

public func check() {
    Trace.initialise(TraceConfig(apiKey: "placeholder"))
}
SWIFT
cd "$dir"
swift package resolve
grep -A6 '"trace-sdk-ios"' Package.resolved
if [ "$1" != --revision ] && ! grep -q "\"version\" : \"$1\"" Package.resolved; then
  echo "::error::trace-sdk-ios did not resolve to $1."
  exit 1
fi
swift build
echo "trace-sdk-ios ($requirement) resolved and built into a package."
