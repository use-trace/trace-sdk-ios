#!/usr/bin/env python3
"""The privacy manifest, checked against the code and against the built package. Run from the repository root.

Sources/TraceSDK/PrivacyInfo.xcprivacy is a statement every app that links this SDK makes to Apple. It fails in
three ways nobody would see until a customer's submission did:

1. It is not in the package. Xcode ignores an .xcprivacy file that Package.swift does not declare as a resource,
   so the SDK would ship with no manifest at all. The package is built for the iOS simulator and the built bundle
   has to hold the same manifest.
2. It holds a key or value Apple does not list. App Store Connect rejects an app with an invalid manifest, so a
   typo here would block every customer's release. Only the values on Apple's pages are accepted below.
3. The code uses a required reason API the manifest does not declare. Apple's list is matched by pattern over
   Sources, with comment lines skipped. **A pattern match, not a compiler**: it finds the API's name, so a call
   through a wrapper with another name, or one inside a dependency (there are none, check-privacy.sh), is not seen.

It also holds the rules from CLAUDE.md that the manifest states: no tracking and no tracking domains.

Apple's values were read on 6 October 2026 from
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatypepurposes
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
"""
import glob
import os
import plistlib
import re
import shutil
import subprocess
import sys

MANIFEST = "Sources/TraceSDK/PrivacyInfo.xcprivacy"

TOP_LEVEL = {"NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"}
DATA_TYPE_KEYS = {"NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking",
                  "NSPrivacyCollectedDataTypePurposes"}
DATA_TYPES = {"NSPrivacyCollectedDataType" + name for name in (
    "Name EmailAddress PhoneNumber PhysicalAddress OtherUserContactInfo Health Fitness PaymentInfo CreditInfo "
    "OtherFinancialInfo PreciseLocation CoarseLocation SensitiveInfo Contacts EmailsOrTextMessages PhotosorVideos "
    "AudioData GameplayContent CustomerSupport OtherUserContent BrowsingHistory SearchHistory UserID DeviceID "
    "PurchaseHistory ProductInteraction AdvertisingData OtherUsageData CrashData PerformanceData OtherDiagnosticData "
    "EnvironmentScanning Hands Head OtherDataTypes").split()}
PURPOSES = {"NSPrivacyCollectedDataTypePurpose" + name for name in (
    "ThirdPartyAdvertising DeveloperAdvertising Analytics ProductPersonalization AppFunctionality Other").split()}

# Apple's required reason APIs, by category, as patterns over Swift, Objective-C and C. getattrlist and its
# relatives are in two categories on Apple's page, so they are in both here.
GETATTRLIST = r"\b(f?getattrlist(bulk|at)?)\s*\("
REQUIRED_REASON = {
    "NSPrivacyAccessedAPICategoryFileTimestamp":
        r"\b(creationDate|modificationDate|fileModificationDate|contentModificationDateKey|creationDateKey)\b"
        r"|\b(stat|fstat|fstatat|lstat)\s*\(|" + GETATTRLIST,
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\b(systemUptime|mach_absolute_time)\b",
    "NSPrivacyAccessedAPICategoryDiskSpace":
        r"\b(volumeAvailableCapacity(ForImportantUsage|ForOpportunisticUsage)?Key|volumeTotalCapacityKey|systemFreeSize"
        r"|systemSize)\b|\b(statfs|statvfs|fstatfs|fstatvfs)\s*\(|" + GETATTRLIST,
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"\bactiveInputModes\b",
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\b(NS)?UserDefaults\b|@AppStorage\b",
}
COMMENT = re.compile(r"^\s*(//|/\*|\*)")

failures = []


def fail(message):
    failures.append(message)
    print("::error::" + message)


def used_categories(lines):
    """{category: [line, ...]} for every required reason API the given (path:number:text) lines use."""
    used = {}
    for line in lines:
        text = line.split(":", 2)[-1]
        if COMMENT.match(text):
            continue
        for category, pattern in REQUIRED_REASON.items():
            if re.search(pattern, text):
                used.setdefault(category, []).append(line)
    return used


def self_test():
    """The patterns, against lines they must and must not match, so a broken pattern fails here and not silently."""
    must = {
        "a.swift:1:let d = UserDefaults.standard": "NSPrivacyAccessedAPICategoryUserDefaults",
        "a.swift:1:@AppStorage(\"x\") var x = 0": "NSPrivacyAccessedAPICategoryUserDefaults",
        "a.swift:1:let t = ProcessInfo.processInfo.systemUptime": "NSPrivacyAccessedAPICategorySystemBootTime",
        "a.m:1:uint64_t t = mach_absolute_time();": "NSPrivacyAccessedAPICategorySystemBootTime",
        "a.swift:1:let d = attrs[.modificationDate]": "NSPrivacyAccessedAPICategoryFileTimestamp",
        "a.c:1:if (stat(path, &st) == 0) {}": "NSPrivacyAccessedAPICategoryFileTimestamp",
        "a.swift:1:url.resourceValues(forKeys: [.volumeAvailableCapacityKey])": "NSPrivacyAccessedAPICategoryDiskSpace",
        "a.swift:1:let m = UITextInputMode.activeInputModes": "NSPrivacyAccessedAPICategoryActiveKeyboards",
    }
    for line, category in must.items():
        if category not in used_categories([line]):
            fail("self test: the %s pattern no longer matches: %s" % (category, line))
    for line in ["a.swift:1:/// Not UserDefaults either", "a.swift:1:    // mach_absolute_time is not used",
                 "a.swift:1:FileManager.default.fileExists(atPath: p)", "a.swift:1:let status = 1"]:
        if used_categories([line]):
            fail("self test: a line that uses no required reason API matched: " + line)


def check_values(manifest):
    extra = set(manifest) - TOP_LEVEL
    if extra:
        fail("%s has keys Apple does not list: %s" % (MANIFEST, ", ".join(sorted(extra))))
    if manifest.get("NSPrivacyTracking") is not False:
        fail("NSPrivacyTracking must be false: the SDK does not track (CLAUDE.md, no advertising identifier).")
    if manifest.get("NSPrivacyTrackingDomains") != []:
        fail("NSPrivacyTrackingDomains must be empty: the SDK contacts no tracking domain.")
    for entry in manifest.get("NSPrivacyCollectedDataTypes", []):
        if set(entry) != DATA_TYPE_KEYS:
            fail("a collected data type needs exactly the keys %s, and has %s" % (sorted(DATA_TYPE_KEYS), sorted(entry)))
        if entry.get("NSPrivacyCollectedDataType") not in DATA_TYPES:
            fail("not a data type Apple lists: %s" % entry.get("NSPrivacyCollectedDataType"))
        if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
            fail("%s is declared as used for tracking, and the SDK does not track" % entry.get("NSPrivacyCollectedDataType"))
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes") or []
        if not purposes or not set(purposes) <= PURPOSES:
            fail("%s needs purposes from Apple's list, and has %s" % (entry.get("NSPrivacyCollectedDataType"), purposes))
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        if entry.get("NSPrivacyAccessedAPIType") not in REQUIRED_REASON:
            fail("not a required reason API category Apple lists: %s" % entry.get("NSPrivacyAccessedAPIType"))
        if not entry.get("NSPrivacyAccessedAPITypeReasons"):
            fail("%s is declared with no reason" % entry.get("NSPrivacyAccessedAPIType"))


def check_code(manifest):
    declared = {entry.get("NSPrivacyAccessedAPIType") for entry in manifest.get("NSPrivacyAccessedAPITypes", [])}
    lines = subprocess.run(["git", "grep", "-nI", "-e", ".", "--", "Sources"], capture_output=True, text=True,
                           check=True).stdout.splitlines()
    for category, hits in sorted(used_categories(lines).items()):
        if category not in declared:
            fail("the code uses a required reason API in %s, and %s does not declare it. Declare the category with "
                 "the reason that is true, from Apple's list, and say why in README.md:\n%s"
                 % (category, MANIFEST, "\n".join(hits)))


def check_built(manifest):
    """Builds the package for the iOS simulator, as it ships, and finds the manifest inside the built bundle."""
    # From nothing every time: an incremental build kept a bundle from before a change to Package.swift, and said
    # the manifest was missing, or there, when it no longer was.
    scratch = ".build/privacy-manifest"
    shutil.rmtree(scratch, ignore_errors=True)
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True, text=True,
                         check=True).stdout.strip()
    subprocess.run(["swift", "build", "--triple", "arm64-apple-ios16.0-simulator", "--sdk", sdk,
                    "--scratch-path", scratch], check=True, stdout=sys.stderr)
    shipped = glob.glob(os.path.join(scratch, "**", "TraceSDK_TraceSDK.bundle", "**", "PrivacyInfo.xcprivacy"),
                        recursive=True)
    if not shipped:
        fail("the built package has no PrivacyInfo.xcprivacy. Declare it as a resource of the TraceSDK target in "
             "Package.swift, or Xcode leaves it out and every app ships the SDK with no manifest.")
        return
    for path in shipped:
        with open(path, "rb") as built:
            if plistlib.load(built) != manifest:
                fail("the manifest in the built package differs from %s: %s" % (MANIFEST, path))


self_test()
try:
    with open(MANIFEST, "rb") as source:
        manifest = plistlib.load(source)
except (OSError, plistlib.InvalidFileException) as error:
    fail("cannot read %s as a property list: %s" % (MANIFEST, error))
    sys.exit(1)
check_values(manifest)
check_code(manifest)
check_built(manifest)

if failures:
    print("The privacy manifest does not match the code or did not ship. See above.", file=sys.stderr)
    sys.exit(1)
print("The privacy manifest is valid, declares every required reason API the code uses, and ships in the package.")
