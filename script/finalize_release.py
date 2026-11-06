#!/usr/bin/env python3
"""Verify published/installed artifacts, then retain one app and one rollback.

Default: audited dry run. --apply is used by verify_and_release.sh --publish
and --finalize. Never installs an app or stops a process. A missing/mismatched
installed release defers cleanup, leaving every candidate available for review.
"""
import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

sys.dont_write_bytecode = True
from release_cleanup import APP_ID, Cleanup, MacRuntime, SafetyError, digest, info, manifest

SOURCE = Path(__file__).resolve().parent.parent
REPO = "williamhsu218/QuotAI"
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(arguments):
    return subprocess.run([str(a) for a in arguments], capture_output=True, text=True, check=True).stdout.strip()


def project_root():
    common = Path(run(["git", "-C", SOURCE, "rev-parse", "--path-format=absolute", "--git-common-dir"]))
    project = common.parent if common.name == ".git" else SOURCE
    if not (project / "QuotAI.xcodeproj").is_dir():
        raise SafetyError("Not a QuotAI checkout; cleanup roots cannot be established")
    return project.resolve()


def download(url, destination):
    if not url.startswith(f"https://github.com/{REPO}/releases/download/"):
        raise SafetyError("Release asset URL is outside the project's public releases")
    run(["curl", "--fail", "--location", "--proto", "=https", "--proto-redir", "=https",
         "--silent", "--show-error", "--retry", "1",
         "--connect-timeout", "15", "--max-time", "120", "--max-filesize", "134217728",
         "--output", destination, url])


def verify_bundle(app, installed):
    run([sys.executable, SOURCE / "script/validate_bundle.py", app, "--universal"])
    # Keep the distribution identity and App Group used by the installed app.
    for field in ("CFBundleIdentifier", "QuotAIAppGroup", "SUPublicEDKey"):
        if info(app).get(field) != info(installed).get(field):
            raise SafetyError(f"Public bundle has different {field}")
    def requirement(path):
        result = subprocess.run(["codesign", "-dr", "-", str(path)], capture_output=True, text=True, check=True)
        return re.search(r"designated => (.+)", result.stdout + result.stderr).group(1)
    if requirement(app) != requirement(installed):
        raise SafetyError("Public release and installed app have different signing requirements")


def verify_archive(item, directory, installed, sparkle):
    version, build = item.findtext(NS + "shortVersionString"), item.findtext(NS + "version")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version or "") or not (build or "").isdigit():
        raise SafetyError("Invalid release version/build in public feed")
    enclosure = item.find("enclosure")
    name = f"QuotAI-{version}-macos-universal.zip"
    url = f"https://github.com/{REPO}/releases/download/v{version}/{name}"
    if enclosure is None or enclosure.get("url") != url:
        raise SafetyError("Unexpected public enclosure URL")
    directory.mkdir(mode=0o700)
    archive = directory / name
    download(url, archive)
    if archive.stat().st_size != int(enclosure.get("length", "-1")):
        raise SafetyError("Public archive length mismatch")
    run([sparkle / "sign_update", "--account", APP_ID, "--verify", archive, enclosure.attrib[NS + "edSignature"]])
    with zipfile.ZipFile(archive) as package:
        for name in package.namelist():
            parts = Path(name).parts
            if name.startswith("/") or ".." in parts or not parts or parts[0] not in ("QuotAI.app", "__MACOSX"):
                raise SafetyError("Unexpected file outside the packaged application")
    run(["ditto", "-x", "-k", archive, directory])
    app = directory / "QuotAI.app"
    verify_bundle(app, installed)
    if info(app)["CFBundleShortVersionString"] != version or info(app)["CFBundleVersion"] != build:
        raise SafetyError("Public app version differs from its signed feed entry")
    return app, archive


def public_proof(version, project, installed, temporary, receipt):
    if installed.is_symlink():
        raise SafetyError("Installed app path must not be a symlink")
    metadata = info(installed)
    if metadata.get("CFBundleIdentifier") != APP_ID or metadata.get("CFBundleShortVersionString") != version:
        raise SafetyError(f"Install and accept QuotAI {version} first, then run verify_and_release.sh {version} --finalize")
    MacRuntime().validate(installed)
    sparkle = project / "build/SparkleSDK/distribution/bin"
    key = run([sparkle / "generate_keys", "--account", APP_ID, "-p"])
    if key != metadata.get("SUPublicEDKey") or len(base64.b64decode(key, validate=True)) != 32:
        raise SafetyError("The release verification key does not match the installed app")
    feed = temporary / "appcast.xml"
    base = f"https://github.com/{REPO}/releases/download/v{version}/"
    download(base + f"appcast-{version}.xml", feed)
    items = ET.parse(feed).getroot().findall("channel/item")
    current = [x for x in items if x.findtext(NS + "shortVersionString") == version]
    if len(current) != 1 or current[0].findtext(NS + "version") != metadata.get("CFBundleVersion"):
        raise SafetyError("Installed build does not match the published release")
    build = int(metadata["CFBundleVersion"])
    previous = [x for x in items if (x.findtext(NS + "version") or "").isdigit()
                and int(x.findtext(NS + "version")) < build]
    if not previous:
        raise SafetyError("No previous published release to retain; cleanup deferred")
    previous = max(previous, key=lambda x: int(x.findtext(NS + "version")))
    app, archive = verify_archive(current[0], temporary / "current", installed, sparkle)
    sums = temporary / "SHA256SUMS.txt"
    download(base + f"SHA256SUMS-{version}.txt", sums)
    if sums.read_text().strip() != f"{digest(archive)}  {archive.name}":
        raise SafetyError("Public SHA256SUMS does not match the signed archive")
    current_files = manifest(app)
    if manifest(installed) != current_files:
        raise SafetyError("Installed files differ from the public release; no cleanup performed")
    previous_app, previous_archive = verify_archive(previous, temporary / "previous", installed, sparkle)
    shutil.copy2(feed, receipt / "verified-public-appcast.xml")
    shutil.copy2(sums, receipt / f"SHA256SUMS-{version}.txt")
    details = {"version": version, "build": build, "archiveSHA256": digest(archive),
               "previousVersion": info(previous_app)["CFBundleShortVersionString"],
               "previousBuild": info(previous_app)["CFBundleVersion"],
               "previousArchiveSHA256": digest(previous_archive),
               "installedMatchesPublicArchive": True, "ed25519Verified": True}
    return details, current_files, previous_app, manifest(previous_app)


def choose_rollback(project, previous, expected, apply):
    project = project.resolve()
    backups = project / "build/InstallBackups"
    if backups.resolve() != backups.absolute():
        raise SafetyError("Linked backup path; existing data and external contents were left untouched")
    matches = []
    if backups.is_dir():
        for path in backups.rglob("*.app"):
            if path.is_symlink():
                continue
            try:
                if info(path).get("CFBundleIdentifier") == APP_ID and manifest(path) == expected:
                    MacRuntime().validate(path)
                    matches.append(path)
            except (OSError, ValueError, subprocess.CalledProcessError):
                continue
    if matches:
        return sorted(matches, key=lambda p: (len(p.parts), str(p)))[0]
    metadata = info(previous)
    destination = backups / f"rollback-{metadata['CFBundleShortVersionString']}-{metadata['CFBundleVersion']}" / "QuotAI.app"
    if destination.exists():
        raise SafetyError("Rollback destination has different contents; it was left untouched")
    if apply:
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        run(["ditto", previous, destination])
        if manifest(destination) != expected:
            raise SafetyError("Rollback copy verification failed; no cleanup performed")
        MacRuntime().validate(destination)
    return destination


def roots(project):
    worktrees = [Path(x.removeprefix("worktree ")) for x in run(["git", "-C", project, "worktree", "list", "--porcelain"]).splitlines() if x.startswith("worktree ")]
    builds = list(dict.fromkeys([project / "build", SOURCE / "build"] + [p / "build" for p in worktrees]))
    caches = [p / ".build" for p in worktrees]
    caches += [p / n for p in builds for n in ("DerivedData", "ReleaseDerivedData", "SignedQA", "SourcePackages")]
    caches += list((Path.home() / "Library/Developer/Xcode/DerivedData").glob("QuotAI-*"))
    scan = [Path("/Applications"), Path.home() / "Applications", Path.home() / "Downloads", Path.home() / "Desktop"]
    return builds, list(dict.fromkeys(caches)), scan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--apply", action="store_true", help="Delete only after all release/retention checks pass")
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.version):
        parser.error("Expected a semantic release version")
    os.umask(0o077)
    project = project_root()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    receipt = project / "build/qa" / f"release-{args.version}" / f"post-release-cleanup-{stamp}"
    if receipt.parent.resolve() != receipt.parent.absolute():
        print("CLEANUP_STATUS=deferred: linked build/qa path; no cleanup performed", file=sys.stderr)
        return 2
    receipt.mkdir(mode=0o700, parents=True)
    report = {"version": args.version, "apply": args.apply, "status": "verifying"}
    cleanup = None
    try:
        with tempfile.TemporaryDirectory(prefix="quotai-finalize-") as directory:
            installed = Path("/Applications/QuotAI.app")
            details, current_files, previous, previous_files = public_proof(args.version, project, installed, Path(directory), receipt)
            rollback = choose_rollback(project, previous, previous_files, args.apply)
            report["verification"] = details
            report["rollback"] = str(rollback)
            if not rollback.exists():
                report["status"] = "dry-run; verified previous public app would be retained first"
                return 0
            builds, caches, scan = roots(project)
            cleanup = Cleanup(project=project, build_roots=builds, cache_roots=caches, scan_roots=scan,
                              receipt=receipt, installed=installed, rollback=rollback,
                              current_files=current_files, previous_files=previous_files, build=details["build"])
            cleanup.plan()
            report["plan"] = cleanup.summary()
            if args.apply:
                cleanup.apply()
                report["plan"] = cleanup.summary()
            report["status"] = "deferred" if cleanup.skipped else ("complete" if args.apply else "dry-run")
            return 2 if cleanup.skipped else 0
    except (SafetyError, OSError, ValueError, ET.ParseError, subprocess.CalledProcessError) as error:
        report["status"] = "deferred"
        report["reason"] = str(error)
        if cleanup is not None:
            report["removedBeforeFailure"] = [str(e.path) for e in cleanup.entries if not e.path.exists()]
        print(f"Cleanup deferred: {error}", file=sys.stderr)
        return 2
    finally:
        (receipt / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(f"CLEANUP_STATUS={report['status']}")
        print(f"CLEANUP_RECEIPT={receipt / 'verification.json'}")


if __name__ == "__main__":
    sys.exit(main())
