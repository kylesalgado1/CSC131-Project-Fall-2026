#!/usr/bin/env python3
"""Structural checks for the WAIT IT OUT UX prototype.

This script never compiles Swift. It verifies that the Xcode project, the shared scheme,
and the local package agree with the files on disk, so a chunk cannot ship a Swift file
that belongs to no target. A passing run is NOT a build or test pass.

It also guards the product contract with text checks. Each system API that reaches outside
the app is confined to an allow-list of exact repo-relative files, and every allow-listed
file must exist:
  - the system networking session and its companion types: only the backend transport
    (NETWORK_SESSION_FILE);
  - the system notification APIs (the notification center, its framework import, and the
    authorization request): only the host's two adapters (NOTIFICATION_FILES);
  - the application singleton and the registration with the push service: only the host's
    push adapter (PUSH_REGISTRAR_FILE);
  - loading the contents of a URL into memory: only the file access behind the JSON stores
    (FILE_ACCESS_FILE), where the URL is a file.
Every other Swift source in the host and the package is refused for all of them, and the
other ways onto the network that the SDK offers (the Network framework, web views, remote
images, raw streams) are refused everywhere. Location and calendar permission APIs and a
Calculate control stay refused everywhere. Comments are ignored, and "//" inside a string
literal is not mistaken for one. The package's unit tests may not name the networking
session at all; among the UI tests only the fixture probe (UI_TEST_NETWORK_FILE) may.

The host's Info.plist and entitlements are scanned too (check_host_configuration): no
privacy usage description, no background mode, App Transport Security relaxed only for local
networking, a push entitlement that agrees with the environment the app reports to the
server, and nothing else; every build configuration of the app target has to name both
files. Every application a UI test creates must be given its own storage folder and its
composition (WAIT_IT_OUT_STORAGE_FOLDER and WAIT_IT_OUT_DATA_MODE) before it is launched, and
one that composes the live backend must point it at this machine, so no UI test can reach a
real server. The one launch without them is named in BARE_UI_TEST_LAUNCHES.

Usage: python3 scripts/check_project_structure.py [--root <repo>] [--pending <path> ...]
  --pending  a file that is intentionally not yet a member of a target (later chunk owns it)
"""
from __future__ import annotations

import argparse
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

PROJECT = "WaitItOutUXPrototype.xcodeproj"
APP_TARGET = "WaitItOutUXPrototype"
UI_TEST_TARGET = "WaitItOutUXPrototypeUITests"
PACKAGE_DIR = Path("Packages/WaitItOutUX")
PACKAGE_TEST_TARGET = "WaitItOutUXTests"
SCHEME = Path(PROJECT) / "xcshareddata" / "xcschemes" / f"{APP_TARGET}.xcscheme"
# The only Swift file allowed to name the system networking session (the backend transport).
NETWORK_SESSION_FILE = PACKAGE_DIR / "Sources" / "WaitItOutUX" / "Backend" / "URLSessionTransport.swift"
# The only Swift files allowed to name the system notification APIs: the host's application
# delegate (notification responses, the push token) and its permission and registration adapter.
PUSH_REGISTRAR_FILE = Path(APP_TARGET) / "SystemPushRegistrar.swift"
NOTIFICATION_FILES = (Path(APP_TARGET) / "AppDelegate.swift", PUSH_REGISTRAR_FILE)
# The only Swift file allowed to load the contents of a URL: the file access of the JSON stores.
FILE_ACCESS_FILE = PACKAGE_DIR / "Sources" / "WaitItOutUX" / "Persistence" / "FileAccessing.swift"
# The only UI test file allowed to name the networking session: it asks this machine's
# loopback address whether the opt-in fixture server is running.
UI_TEST_NETWORK_FILE = Path(UI_TEST_TARGET) / "LiveModeUITests.swift"
# UI test launches without a storage folder and a data mode, by file. The closed-app
# end-to-end test (opt-in, see AGENTS.md "Host rules") relaunches once in the app's default
# storage, because a launch by the system (a tapped notification) carries no environment.
BARE_UI_TEST_LAUNCHES = {Path(UI_TEST_TARGET) / "LiveModeUITests.swift": 1}
# The host's partial Info.plist (merged with the generated one) and its entitlements.
HOST_INFO_PLIST = Path(APP_TARGET) / "Info.plist"
HOST_ENTITLEMENTS = Path(APP_TARGET) / f"{APP_TARGET}.entitlements"
BACKEND_URL_INFO_KEY = "WaitItOutBackendURL"
# The signed push entitlement and the push environment the app must report for it.
APS_ENVIRONMENTS = {"development": "sandbox", "production": "production"}
DATA_MODE_KEY = "WAIT_IT_OUT_DATA_MODE"
BACKEND_URL_KEY = "WAIT_IT_OUT_BACKEND_URL"
LOOPBACK_PREFIXES = ("http://127.0.0.1", "http://localhost", "http://[::1]")

OBJECT_RE = re.compile(r"^\t\t([0-9A-F]{24}) (?:/\* (.*?) \*/ )?= \{(.*)$", re.M)
FILE_REF_RE = re.compile(
    r"^\t\t([0-9A-F]{24}) /\* (.*?) \*/ = \{isa = PBXFileReference;.*?path = (\"[^\"]*\"|[^;]+);.*?\};$", re.M
)
BUILD_FILE_RE = re.compile(
    r"^\t\t([0-9A-F]{24}) /\* .*? \*/ = \{isa = PBXBuildFile; (fileRef|productRef) = ([0-9A-F]{24}).*?\};$", re.M
)


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.notes: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def note(self, msg: str) -> None:
        self.notes.append(msg)


def parse_sections(text: str) -> dict[str, str]:
    sections: dict[str, str] = {}
    for match in re.finditer(r"/\* Begin (\w+) section \*/\n(.*?)/\* End \1 section \*/", text, re.S):
        sections[match.group(1)] = match.group(2)
    return sections


def block_for(text: str, object_id: str) -> str:
    match = re.search(rf"^\t\t{object_id} ", text, re.M)
    if not match:
        return ""
    start = match.start()
    depth = 0
    i = text.find("{", start)
    j = i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[start : j + 1]
        j += 1
    return text[start:]


def ids_in_list(block: str, key: str) -> list[str]:
    match = re.search(rf"{key} = \((.*?)\);", block, re.S)
    if not match:
        return []
    return re.findall(r"([0-9A-F]{24})", match.group(1))


def check_pbxproj(root: Path, pending: set[Path], report: Report) -> None:
    pbx = root / PROJECT / "project.pbxproj"
    if not pbx.exists():
        report.error(f"missing {pbx}")
        return
    text = pbx.read_text()
    if not text.startswith("// !$*UTF8*$!"):
        report.error("project.pbxproj missing UTF8 header")
    if text.count("{") != text.count("}"):
        report.error("project.pbxproj braces unbalanced")
    if text.count("(") != text.count(")"):
        report.error("project.pbxproj parentheses unbalanced")

    all_ids = set(re.findall(r"^\t\t([0-9A-F]{24}) ", text, re.M))
    referenced = set(re.findall(r"([0-9A-F]{24})", text))
    for rid in referenced:
        if rid not in all_ids:
            report.error(f"pbxproj references undefined object {rid}")
    dup = [i for i in all_ids if len(re.findall(rf"^\t\t{i} ", text, re.M)) > 1]
    for d in dup:
        report.error(f"pbxproj defines object {d} more than once")

    sections = parse_sections(text)
    for required in ("PBXBuildFile", "PBXFileReference", "PBXNativeTarget", "PBXProject", "PBXSourcesBuildPhase",
                     "XCBuildConfiguration", "XCConfigurationList", "XCLocalSwiftPackageReference",
                     "XCSwiftPackageProductDependency"):
        if required not in sections:
            report.error(f"pbxproj missing section {required}")

    root_match = re.search(r"rootObject = ([0-9A-F]{24})", text)
    if not root_match:
        report.error("pbxproj missing rootObject")
        return
    project_block = block_for(text, root_match.group(1))
    target_ids = ids_in_list(project_block, "targets")
    package_refs = ids_in_list(project_block, "packageReferences")
    if not package_refs:
        report.error("PBXProject has no packageReferences")
    for pref in package_refs:
        pblock = block_for(text, pref)
        rel = re.search(r"relativePath = ([^;]+);", pblock)
        if not rel:
            report.error(f"package reference {pref} lacks relativePath")
        else:
            rel_path = rel.group(1).strip('"')
            if not (root / rel_path / "Package.swift").exists():
                report.error(f"package reference path {rel_path} has no Package.swift")
            else:
                report.note(f"local package reference resolves: {rel_path}")

    # file references -> on-disk path (resolve through groups)
    file_refs: dict[str, str] = {}
    for fid, _comment, path in FILE_REF_RE.findall(text):
        file_refs[fid] = path.strip('"')
    group_paths: dict[str, str] = {}
    group_children: dict[str, list[str]] = {}
    for gid in re.findall(r"^\t\t([0-9A-F]{24}) (?:/\* .*? \*/ )?= \{\n\t\t\tisa = PBXGroup;", text, re.M):
        gblock = block_for(text, gid)
        path = re.search(r"\n\t\t\tpath = ([^;]+);", gblock)
        group_paths[gid] = path.group(1).strip('"') if path else ""
        group_children[gid] = ids_in_list(gblock, "children")

    def resolve(fid: str) -> Path | None:
        if fid not in file_refs:
            return None
        parts = [file_refs[fid]]
        current = fid
        while True:
            parent = next((g for g, kids in group_children.items() if current in kids), None)
            if parent is None:
                break
            if group_paths.get(parent):
                parts.insert(0, group_paths[parent])
            current = parent
        return root.joinpath(*parts)

    build_files: dict[str, tuple[str, str]] = {}
    for bid, kind, ref in BUILD_FILE_RE.findall(text):
        build_files[bid] = (kind, ref)

    # check on-disk existence of every source/resource file reference (except products)
    for fid, path in file_refs.items():
        fblock = block_for(text, fid)
        if "BUILT_PRODUCTS_DIR" in fblock:
            continue
        resolved = resolve(fid)
        if resolved is None or not resolved.exists():
            report.error(f"file reference {path} does not exist on disk ({resolved})")

    # target membership
    target_sources: dict[str, set[Path]] = {}
    target_names: dict[str, str] = {}
    for tid in target_ids:
        tblock = block_for(text, tid)
        name = re.search(r"\n\t\t\tname = ([^;]+);", tblock)
        tname = name.group(1).strip('"') if name else tid
        target_names[tid] = tname
        sources: set[Path] = set()
        for phase in ids_in_list(tblock, "buildPhases"):
            pblock = block_for(text, phase)
            if "isa = PBXSourcesBuildPhase" not in pblock and "isa = PBXResourcesBuildPhase" not in pblock:
                continue
            for bid in ids_in_list(pblock, "files"):
                kind, ref = build_files.get(bid, ("", ""))
                if kind == "fileRef":
                    resolved = resolve(ref)
                    if resolved is not None:
                        sources.add(resolved.resolve())
        target_sources[tid] = sources
        if tname == APP_TARGET:
            deps = ids_in_list(tblock, "packageProductDependencies")
            if not deps:
                report.error(f"{APP_TARGET} does not depend on the WaitItOutUX package product")
            frameworks_ok = any(
                build_files.get(bid, ("", ""))[0] == "productRef"
                for phase in ids_in_list(tblock, "buildPhases")
                for bid in ids_in_list(block_for(text, phase), "files")
            )
            if not frameworks_ok:
                report.error(f"{APP_TARGET} Frameworks phase does not link the package product")
            if "com.apple.product-type.application" not in tblock:
                report.error(f"{APP_TARGET} is not an application target")
        if tname == UI_TEST_TARGET and "com.apple.product-type.bundle.ui-testing" not in tblock:
            report.error(f"{UI_TEST_TARGET} is not a UI testing bundle")

    expected = {APP_TARGET, UI_TEST_TARGET}
    missing = expected - set(target_names.values())
    for m in missing:
        report.error(f"target {m} missing from project")

    # every Swift file in host folders must belong to the matching target
    for folder, tname in ((APP_TARGET, APP_TARGET), (UI_TEST_TARGET, UI_TEST_TARGET)):
        tid = next((t for t, n in target_names.items() if n == tname), None)
        members = target_sources.get(tid, set()) if tid else set()
        for swift in sorted((root / folder).rglob("*.swift")):
            if swift.resolve() in members:
                continue
            if swift.resolve() in pending:
                report.warn(f"pending membership: {swift.relative_to(root)}")
            else:
                report.error(f"{swift.relative_to(root)} is not a member of target {tname}")
        for member in members:
            if member.suffix == ".swift" and folder not in member.parts:
                report.error(f"target {tname} compiles a file outside its folder: {member}")

    # build settings sanity
    for key, value in (("IPHONEOS_DEPLOYMENT_TARGET", "17.0"), ("SDKROOT", "iphoneos"), ("SWIFT_VERSION", "5.0"),
                       ("GENERATE_INFOPLIST_FILE", "YES"), ("CODE_SIGN_STYLE", "Automatic")):
        if f"{key} = {value};" not in text:
            report.error(f"build setting {key} = {value} not found")
    if re.search(r"DEVELOPMENT_TEAM = [A-Z0-9]{10};", text):
        report.error("a DEVELOPMENT_TEAM is hard-coded; simulator builds must not need one")
    if "PROVISIONING_PROFILE" in text:
        report.error("provisioning profile settings present")
    report.note(f"targets: {', '.join(target_names.values())}")


def check_scheme(root: Path, report: Report) -> None:
    scheme = root / SCHEME
    if not scheme.exists():
        report.error(f"missing shared scheme {SCHEME}")
        return
    try:
        tree = ET.parse(scheme)
    except ET.ParseError as exc:
        report.error(f"scheme is not well-formed XML: {exc}")
        return
    pbx_text = (root / PROJECT / "project.pbxproj").read_text()
    refs = tree.getroot().iter("BuildableReference")
    seen = []
    for ref in refs:
        container = ref.get("ReferencedContainer", "")
        blueprint = ref.get("BlueprintIdentifier", "")
        name = ref.get("BlueprintName", "")
        seen.append(name)
        if container == f"container:{PROJECT}":
            if f"\t\t{blueprint} /* {name} */ = {{" not in pbx_text:
                report.error(f"scheme references unknown project target {name} ({blueprint})")
        elif container.startswith("container:"):
            pkg = root / container[len("container:"):]
            manifest = pkg / "Package.swift"
            if not manifest.exists():
                report.error(f"scheme references package container without manifest: {container}")
            elif f'name: "{blueprint}"' not in manifest.read_text():
                report.error(f"scheme references package target {blueprint} not declared in {manifest}")
        else:
            report.error(f"scheme has unexpected container {container}")
    testables = tree.getroot().findall("./TestAction/Testables/TestableReference")
    if not testables:
        report.error("scheme has no testables")
    report.note(f"scheme buildables: {', '.join(dict.fromkeys(seen))}")


def check_package(root: Path, report: Report) -> None:
    pkg = root / PACKAGE_DIR
    manifest = pkg / "Package.swift"
    if not manifest.exists():
        report.error("package manifest missing")
        return
    text = manifest.read_text()
    if not text.startswith("// swift-tools-version:"):
        report.error("Package.swift must start with the swift-tools-version comment")
    if ".iOS(.v17)" not in text:
        report.error("package must declare iOS 17 as its platform floor")
    for target, path in (("WaitItOutUX", pkg / "Sources" / "WaitItOutUX"), (PACKAGE_TEST_TARGET, pkg / "Tests" / PACKAGE_TEST_TARGET)):
        if f'name: "{target}"' not in text:
            report.error(f"package target {target} not declared")
        swift_files = list(path.rglob("*.swift")) if path.exists() else []
        if not swift_files:
            report.error(f"package target {target} has no Swift sources at {path}")
        else:
            report.note(f"package target {target}: {len(swift_files)} Swift files")
    stray = [p for p in pkg.rglob("*.swift") if "Sources" not in p.parts and "Tests" not in p.parts and p.name != "Package.swift"]
    for s in stray:
        report.error(f"Swift file outside any package target: {s.relative_to(root)}")


def strip_line_comment(line: str) -> str:
    """The code of one Swift line without its trailing // comment.

    A "//" inside a string literal, such as the one in "http://localhost", is not a comment,
    so the scan keeps track of whether it is inside double quotes. Multi-line string
    literals and comment blocks are not followed across lines; a line is at worst scanned in
    full, which can only make the checks stricter.
    """
    in_string = False
    i = 0
    while i < len(line):
        char = line[i]
        if in_string:
            if char == "\\":
                i += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "/" and line[i + 1 : i + 2] == "/":
            return line[:i]
        i += 1
    return line


def scan_swift(root: Path, folder: Path, rules: list, report: Report) -> None:
    """Reports every code line under `folder` that matches a rule outside its allowed files."""
    for swift in sorted(folder.rglob("*.swift")):
        relative = swift.relative_to(root)
        for line_no, line in enumerate(swift.read_text().splitlines(), 1):
            code = strip_line_comment(line)
            for pattern, label, allowed in rules:
                if relative in allowed:
                    continue
                if pattern.search(code):
                    report.error(f"{label} at {relative}:{line_no}")


def check_ui_test_launches(root: Path, report: Report) -> None:
    """Every application a UI test creates is configured before it can be launched (stage S3).

    Each `XCUIApplication()` made inside a function has to be given a storage folder and a
    data mode before the function ends or the next application is made, so no launch can use
    the app's default storage or an unchosen composition by accident. One that composes the
    live backend has to name its server in the same place. Stored-property defaults (the
    placeholder a test replaces in setUp) and other apps (the system's, by bundle identifier)
    are not launches of the app under test.
    """
    data_mode_re = re.compile(rf'launchEnvironment\[\s*"{DATA_MODE_KEY}"\s*\]\s*=\s*"([^"]*)"')
    storage_re = re.compile(r'launchEnvironment\[\s*(?:"WAIT_IT_OUT_STORAGE_FOLDER"|[\w.]*[sS]torageFolderKey|[\w.]*folderEnvironmentKey)\s*\]\s*=')
    backend_re = re.compile(rf'launchEnvironment\[\s*"{BACKEND_URL_KEY}"\s*\]\s*=')
    creation_re = re.compile(r"XCUIApplication\(\s*\)")
    property_re = re.compile(r"^\s*(?:(?:private|fileprivate|internal|public|static|lazy)\s+)*(?:var|let)\s+\w+\s*:\s*XCUIApplication\b")
    function_re = re.compile(r"^\s*(?:(?:private|fileprivate|internal|public|override|static|final|class|@\w+)\s+)*func\s")
    for swift in sorted((root / UI_TEST_TARGET).rglob("*.swift")):
        relative = swift.relative_to(root)
        lines = swift.read_text().splitlines()
        bare = 0
        for index, line in enumerate(lines):
            code = strip_line_comment(line)
            if not creation_re.search(code) or property_re.search(code):
                continue
            # The configuration that belongs to this application: up to the next one, or to
            # the next function.
            end = index + 1
            while end < len(lines):
                following = strip_line_comment(lines[end])
                if creation_re.search(following) or function_re.search(following):
                    break
                end += 1
            block = "\n".join(strip_line_comment(text) for text in lines[index:end])
            modes = data_mode_re.findall(block)
            if not storage_re.search(block) or not modes:
                bare += 1
                continue
            if any(mode != "demo" for mode in modes) and not backend_re.search(block):
                report.error(f"{relative}:{index + 1} composes the live backend without setting {BACKEND_URL_KEY}")
        allowed = BARE_UI_TEST_LAUNCHES.get(relative, 0)
        if bare > allowed:
            report.error(
                f"{relative} creates {bare} application(s) without a storage folder and a data mode; "
                f"{allowed} allowed (BARE_UI_TEST_LAUNCHES)"
            )
        elif bare < allowed:
            report.error(f"{relative} no longer has the bare launch named in BARE_UI_TEST_LAUNCHES; remove the entry")


def check_product_contract(root: Path, report: Report) -> None:
    """Static guard rails for the product contract (step 0008). Text checks only, not a build."""
    sources = root / PACKAGE_DIR / "Sources" / "WaitItOutUX"
    tab_file = sources / "PrototypeTab.swift"
    tab_text = tab_file.read_text() if tab_file.exists() else ""
    if "displayOrder: [PrototypeTab] = [.map, .calendar, .settings]" not in tab_text:
        report.error("PrototypeTab.displayOrder must be exactly Map, Calendar, Settings")
    if re.findall(r"^\s*case (\w+)$", tab_text, re.M) != ["map", "calendar", "settings"]:
        report.error("PrototypeTab must declare exactly the cases map, calendar, settings")

    # The departure is derived and read-only: no stored or editable leave-home field.
    for relative in ("Activities/Activity.swift", "Editing/ActivityDraft.swift", "Preferences.swift"):
        path = sources / relative
        text = path.read_text() if path.exists() else ""
        if re.search(r"\b(?:var|let)\s+\w*(?:[dD]eparture|leaveHome(?!Reminders))\w*\s*:", text):
            report.error(f"{relative} declares a departure or leave-home property; it must stay derived")

    # No surprise permissions, no network access outside the one transport file, no notification
    # or push registration API outside the host's adapters, and no required Calculate button.
    # Each rule lists the exact repo-relative files it allows.
    # The session and every type named after it (its configuration, its tasks), except the
    # package's own adapter type, which is named after the one file that may use them.
    network_session = re.compile(r"\bURLSession(?!Transport\b)\w*")
    # The other ways onto the network: the Network framework, web views, remote images, and
    # raw streams and sockets. Nothing in the app uses any of them.
    other_network = re.compile(
        r"\bimport\s+(?:Network|WebKit|SafariServices|CFNetwork)\b|\bNW(?:Connection|Listener|Browser|PathMonitor)\b"
        r"|\bWKWebView\b|\bSFSafariViewController\b|\bAsyncImage\b|\bCF(?:Stream|Socket|ReadStream|WriteStream)\w*"
        r"|\b(?:Input|Output)Stream\s*\(\s*url\s*:|\bStream\.getStreamsToHost\b"
    )
    forbidden = [
        (re.compile(r"\bCLLocationManager\b|request(?:WhenInUse|Always)Authorization"), "location permission API", ()),
        (re.compile(r"\bUNUserNotificationCenter\b|\bimport UserNotifications\b|requestAuthorization\("), "notification permission API", NOTIFICATION_FILES),
        (re.compile(r"\bUIApplication\s*\.\s*shared\b"), "application singleton", (PUSH_REGISTRAR_FILE,)),
        (re.compile(r"\bEKEventStore\b|\brequestAccess\("), "calendar or other permission API", ()),
        (network_session, "network service", (NETWORK_SESSION_FILE,)),
        (other_network, "network access outside the backend transport", ()),
        (re.compile(r"\b(?:NS)?(?:Data|String|Dictionary|Array)\s*\(\s*contentsOf\s*:"), "loading the contents of a URL", (FILE_ACCESS_FILE,)),
        (re.compile(r'"Calculate(?:\s[^"]*)?"'), "Calculate control", ()),
    ]
    # In the host the registration with the push service is one call on an application object,
    # whichever way that object was obtained. (The package names the same word only as its own
    # protocol requirement, `PushRegistering.registerForRemoteNotifications()`.)
    host_only = [
        (re.compile(r"\b(?:un)?registerForRemoteNotifications\s*\("), "push registration API", (PUSH_REGISTRAR_FILE,)),
    ]
    for _pattern, label, allowed in forbidden + host_only:
        for allowed_file in allowed:
            if not (root / allowed_file).is_file():
                report.error(f"allow-listed file for {label} is missing: {allowed_file}")
    scan_swift(root, root / APP_TARGET, forbidden + host_only, report)
    scan_swift(root, sources, forbidden, report)
    # No test may open a connection: the unit tests use the scripted transport, and among the
    # UI tests only the fixture probe asks this machine whether the opt-in server is running.
    scan_swift(root, root / PACKAGE_DIR / "Tests", [(network_session, "network service in a unit test", ()), (other_network, "network access in a unit test", ())], report)
    scan_swift(root, root / UI_TEST_TARGET, [(network_session, "network service in a UI test", (UI_TEST_NETWORK_FILE,)), (other_network, "network access in a UI test", ())], report)
    if not (root / UI_TEST_NETWORK_FILE).is_file():
        report.error(f"allow-listed file for the UI test fixture probe is missing: {UI_TEST_NETWORK_FILE}")
    pbx = root / PROJECT / "project.pbxproj"
    if pbx.exists() and re.search(r"UsageDescription|UIBackgroundModes", pbx.read_text()):
        report.error("project.pbxproj declares a privacy usage description or background mode")

    # Swift only: no C, C++, Objective-C, or Python sources inside the app or the package.
    for folder in (root / APP_TARGET, root / UI_TEST_TARGET, root / PACKAGE_DIR):
        for extension in ("*.c", "*.cc", "*.cpp", "*.h", "*.hpp", "*.m", "*.mm", "*.py"):
            for stray in folder.rglob(extension):
                report.error(f"non-Swift app component {stray.relative_to(root)}")

    # Every UI test class starts from its own empty storage folder (step 0007) and chooses its
    # composition (stage S3): the standalone demo, or the live backend on this machine only.
    data_mode_re = re.compile(rf'launchEnvironment\[\s*"{DATA_MODE_KEY}"\s*\]\s*=\s*"([^"]*)"')
    for swift in sorted((root / UI_TEST_TARGET).rglob("*.swift")):
        text = swift.read_text()
        if "XCTestCase" not in text:
            continue
        relative = swift.relative_to(root)
        if "folderEnvironmentKey" not in text and "WAIT_IT_OUT_STORAGE_FOLDER" not in text:
            report.error(f"{relative} does not set the storage folder launch environment")
        modes = data_mode_re.findall(text)
        if not modes:
            report.error(f"{relative} does not set the {DATA_MODE_KEY} launch environment")
        for mode in modes:
            if mode not in ("demo", "live"):
                report.error(f"{relative} sets {DATA_MODE_KEY} to {mode!r}; use \"demo\" or \"live\"")
        addresses = re.findall(r'"(https?://[^"]*)"', text)
        if any(mode != "demo" for mode in modes):
            if not re.search(rf'launchEnvironment\[\s*"{BACKEND_URL_KEY}"\s*\]\s*=', text):
                report.error(f"{relative} composes the live backend without setting {BACKEND_URL_KEY}")
            if not addresses:
                report.error(f"{relative} composes the live backend without naming a loopback address")
        for address in addresses:
            if not address.startswith(LOOPBACK_PREFIXES):
                report.error(f"{relative} names a server that is not on this machine: {address}")
    # One assignment somewhere in the file is not enough: every application that is created
    # has to be configured before it is launched.
    check_ui_test_launches(root, report)


def plist_keys(value: object) -> list[str]:
    """Every dictionary key in a property list, at any depth."""
    keys: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            keys.append(key)
            keys.extend(plist_keys(child))
    elif isinstance(value, list):
        for child in value:
            keys.extend(plist_keys(child))
    return keys


def load_plist(path: Path, report: Report, root: Path) -> dict | None:
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except Exception as exc:  # malformed XML, wrong root, unreadable file
        report.error(f"{path.relative_to(root)} is not a readable property list: {exc}")
        return None
    if not isinstance(value, dict):
        report.error(f"{path.relative_to(root)} must be a dictionary at the top level")
        return None
    return value


def check_host_configuration(root: Path, report: Report) -> None:
    """The host's Info.plist and entitlements (stage S3). Text and plist checks only."""
    pbx = root / PROJECT / "project.pbxproj"
    pbx_text = pbx.read_text() if pbx.exists() else ""

    # The project may name only the one host Info.plist and the one entitlements file.
    for setting, expected in (("INFOPLIST_FILE", HOST_INFO_PLIST), ("CODE_SIGN_ENTITLEMENTS", HOST_ENTITLEMENTS)):
        named = {value.strip().strip('"') for value in re.findall(rf"\b{setting} = ([^;]+);", pbx_text)}
        for value in sorted(named):
            if Path(value) != expected:
                report.error(f"{setting} names {value}; only {expected} is checked and allowed")
        if (root / expected).is_file() and not named:
            report.error(f"{expected} exists but no build configuration sets {setting}")
        if named and not (root / expected).is_file():
            report.error(f"{setting} is set but {expected} is missing")
    # Every build configuration of the app target has to name both files: a Release build
    # without the partial Info.plist or the entitlements would be a different app.
    target = re.search(rf"^\t\t([0-9A-F]{{24}}) /\* {re.escape(APP_TARGET)} \*/ = \{{\n\t\t\tisa = PBXNativeTarget;", pbx_text, re.M)
    configurations = []
    if target:
        listed = re.search(r"buildConfigurationList = ([0-9A-F]{24})", block_for(pbx_text, target.group(1)))
        if listed:
            configurations = ids_in_list(block_for(pbx_text, listed.group(1)), "buildConfigurations")
    if not configurations:
        report.error(f"the build configurations of target {APP_TARGET} could not be read")
    for configuration in configurations:
        block = block_for(pbx_text, configuration)
        name = re.search(r"\n\t\t\tname = ([^;]+);", block)
        label = name.group(1).strip('"') if name else configuration
        for setting, expected in (("INFOPLIST_FILE", HOST_INFO_PLIST), ("CODE_SIGN_ENTITLEMENTS", HOST_ENTITLEMENTS)):
            if not (root / expected).is_file():
                continue
            if not re.search(rf"\b{setting} = \"?{re.escape(str(expected))}\"?;", block):
                report.error(f"the {label} configuration of {APP_TARGET} does not set {setting} to {expected}")
    # No other property list may sit in the host or the UI tests where it could be swapped in.
    for folder in (root / APP_TARGET, root / UI_TEST_TARGET):
        for extension in ("*.plist", "*.entitlements"):
            for found in sorted(folder.rglob(extension)):
                if found.relative_to(root) not in (HOST_INFO_PLIST, HOST_ENTITLEMENTS):
                    report.error(f"unexpected property list {found.relative_to(root)}")

    info_path = root / HOST_INFO_PLIST
    if info_path.is_file():
        info = load_plist(info_path, report, root)
        if info is not None:
            for key in plist_keys(info):
                if key.endswith("UsageDescription"):
                    report.error(f"{HOST_INFO_PLIST} declares the privacy usage description {key}")
                if key == "UIBackgroundModes":
                    report.error(f"{HOST_INFO_PLIST} declares a background mode")
            if "NSAppTransportSecurity" in info:
                ats = info["NSAppTransportSecurity"]
                if not isinstance(ats, dict):
                    report.error(f"{HOST_INFO_PLIST}: NSAppTransportSecurity must be a dictionary")
                else:
                    for key in sorted(set(ats) - {"NSAllowsLocalNetworking"}):
                        report.error(f"{HOST_INFO_PLIST}: NSAppTransportSecurity may contain only NSAllowsLocalNetworking, not {key}")
                    if "NSAllowsLocalNetworking" in ats and not isinstance(ats["NSAllowsLocalNetworking"], bool):
                        report.error(f"{HOST_INFO_PLIST}: NSAllowsLocalNetworking must be a boolean")
            if BACKEND_URL_INFO_KEY in info:
                address = info[BACKEND_URL_INFO_KEY]
                if not isinstance(address, str) or not re.fullmatch(r"https?://[^/\s?#@]+/?", address):
                    report.error(f"{HOST_INFO_PLIST}: {BACKEND_URL_INFO_KEY} must be an http or https server address without a path")
                elif address.startswith("http://") and not address.startswith(LOOPBACK_PREFIXES):
                    report.error(f"{HOST_INFO_PLIST}: {BACKEND_URL_INFO_KEY} uses plain http for a server that is not on this machine")
            report.note(f"host Info.plist keys: {', '.join(sorted(info))}")

    entitlements_path = root / HOST_ENTITLEMENTS
    if entitlements_path.is_file():
        entitlements = load_plist(entitlements_path, report, root)
        if entitlements is not None:
            for key in sorted(set(entitlements) - {"aps-environment"}):
                report.error(f"{HOST_ENTITLEMENTS} declares {key}; only aps-environment is allowed")
            signed = entitlements.get("aps-environment")
            if signed not in APS_ENVIRONMENTS:
                report.error(f"{HOST_ENTITLEMENTS}: aps-environment must be development or production")
            else:
                # The push environment follows the signed entitlement, so the value the app
                # reports to the server has to be changed together with it.
                registrar = root / PUSH_REGISTRAR_FILE
                registrar_text = registrar.read_text() if registrar.is_file() else ""
                reported = re.findall(r'\bapnsEnvironment\b[^\n"]*"([^"]*)"', registrar_text)
                if reported != [APS_ENVIRONMENTS[signed]]:
                    report.error(
                        f"{PUSH_REGISTRAR_FILE} must report apnsEnvironment \"{APS_ENVIRONMENTS[signed]}\" "
                        f"for the {signed} entitlement (found {reported})"
                    )
                report.note(f"push entitlement: {signed}")


def check_swift_hygiene(root: Path, report: Report) -> None:
    patterns = [(re.compile(r"\bTODO\b|\bFIXME\b"), "TODO/FIXME marker"), (re.compile(r"\bfatalError\("), "fatalError call")]
    folders = [root / APP_TARGET, root / UI_TEST_TARGET, root / PACKAGE_DIR / "Sources", root / PACKAGE_DIR / "Tests"]
    for folder in folders:
        for swift in folder.rglob("*.swift"):
            text = swift.read_text()
            for pattern, label in patterns:
                for line_no, line in enumerate(text.splitlines(), 1):
                    if pattern.search(line):
                        report.error(f"{label} at {swift.relative_to(root)}:{line_no}")
            if text.count("{") != text.count("}"):
                report.error(f"unbalanced braces in {swift.relative_to(root)}")
            if text.count("(") != text.count(")"):
                report.error(f"unbalanced parentheses in {swift.relative_to(root)}")
            for line_no, line in enumerate(text.splitlines(), 1):
                stripped = line.split("//")[0]
                if re.search(r"[\w\)\]]!(?=[\s\.\),;\]]|$)", stripped) and "!=" not in stripped:
                    report.error(f"possible force unwrap at {swift.relative_to(root)}:{line_no}: {line.strip()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--pending", action="append", default=[], help="file whose target membership a later chunk owns")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    pending = {(root / p).resolve() for p in args.pending}
    report = Report()
    check_pbxproj(root, pending, report)
    check_scheme(root, report)
    check_package(root, report)
    check_product_contract(root, report)
    check_host_configuration(root, report)
    check_swift_hygiene(root, report)
    for note in report.notes:
        print(f"note: {note}")
    for warning in report.warnings:
        print(f"warning: {warning}")
    for error in report.errors:
        print(f"error: {error}")
    print(f"structure check: {len(report.errors)} errors, {len(report.warnings)} warnings (static only; not a build)")
    return 1 if report.errors else 0


if __name__ == "__main__":
    sys.exit(main())
