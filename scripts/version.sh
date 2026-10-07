#!/usr/bin/env bash
# Prints the SDK's version, from Sources/TraceSDK/Version.swift, where it is set. Fails when it is not a plain x.y.z
# (Swift Package Manager wants the bare semver tag) or when the README's package line names a different one. Run
# from anywhere; used by version.yml and release.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^[[:space:]]*static let current = "\(.*\)"$/\1/p' Sources/TraceSDK/Version.swift)
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Sources/TraceSDK/Version.swift has no static let current = \"x.y.z\" line (found \"$version\")." >&2
  exit 1
fi
readme=$(sed -n 's/.*\.package(url: "https:\/\/github\.com\/use-trace\/trace-sdk-ios", from: "\([^"]*\)").*/\1/p' README.md)
if [ "$readme" != "$version" ]; then
  echo "README.md adds the package from \"$readme\" but Sources/TraceSDK/Version.swift says $version. Change both." >&2
  exit 1
fi
echo "$version"
