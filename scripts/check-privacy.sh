#!/usr/bin/env bash
# The privacy rules in CLAUDE.md, as a check rather than a promise. Run from the repository root.
#
# Each rule is a pattern that must not appear in code. Comment lines are skipped, so a doc comment saying "it does
# not import AdSupport" is not a violation. A rule that has to change is changed here, in a reviewed pull request.
set -uo pipefail

failed=0

# forbid <reason> <extended regex> <pathspec>...
forbid() {
  local reason=$1 pattern=$2
  shift 2
  local hits
  hits=$(git grep -nIE -e "$pattern" -- "$@" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//')
  if [ -n "$hits" ]; then
    echo "::error::$reason"
    echo "$hits"
    failed=1
  fi
}

forbid "No advertising identifier and no tracking prompt: never AdSupport or AppTrackingTransparency." \
  'import[[:space:]]+(AdSupport|AppTrackingTransparency)|ASIdentifierManager|ATTrackingManager|advertisingIdentifier' \
  'Sources'

# A vendor identifier is a device identifier shared by every app from one developer: a fingerprint by another name.
forbid "No device identifier: the install id is the only identity this SDK holds." \
  'identifierForVendor' \
  'Sources'

# Keychain items survive the app being deleted, so an id kept there would outlive an uninstall.
forbid "No Keychain: the install id lives in a file in Application Support, excluded from backup." \
  'SecItem(Add|CopyMatching|Update|Delete)|kSecClass|kSecAttr' \
  'Sources'

# Decided 11 September 2026. Hashing is how an email becomes a hashed identifier, so the libraries for it are out too.
forbid "No identify, and no hashed email or customer id." \
  'func[[:space:]]+identify|hashedEmail|emailHash|import[[:space:]]+(CryptoKit|CommonCrypto)' \
  'Sources'

# Every line goes through TraceLog, which redacts anything identity shaped at the sink. A log call anywhere else
# skips the redaction, so a visitor identity could reach a log line.
forbid "Log only through TraceLog, which redacts identities. No print, NSLog, os_log or Logger elsewhere." \
  '(^|[^A-Za-z_.])(print|debugPrint|dump|NSLog|os_log)[[:space:]]*\(|Logger[[:space:]]*\(|FileHandle\.standard(Error|Output)' \
  'Sources' ':!Sources/TraceSDK/TraceLog.swift'

# Every dependency is code that runs inside a customer's app with the SDK's privileges and none of its rules.
forbid "No dependencies in Package.swift." \
  '\.package[[:space:]]*\(' \
  'Package.swift'

if [ "$failed" -ne 0 ]; then
  echo "A privacy rule from CLAUDE.md is broken. See above." >&2
  exit 1
fi
echo "Privacy rules hold."
