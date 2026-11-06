"""Conservative local retention policy, used only after public release verification.

No installer, process termination, registration reset, or user-data migration.
The caller supplies manifests verified against signed public release archives.
"""
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

APP_ID = "com.willhsu.QuotAI"
LEGACY_IDS = {"com.willhsu.CodexQuota", "com.willhsu.Codexcator", "com.willhsu.CodexIndicator"}
MACHO = {bytes.fromhex(x) for x in ("cffaedfe", "cefaedfe", "feedfacf", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
DATA_NAMES = {"quota-history-v1.json", "settings.json", "preferences.plist"}
EVIDENCE_WORDS = {"fixture", "snapshot", "before", "backup", "source"}
RECORD_SUFFIXES = {".json", ".jsonl", ".ndjson", ".plist", ".log", ".txt", ".csv", ".tsv",
                   ".md", ".yaml", ".yml", ".toml", ".xml", ".crash", ".ips", ".png", ".jpg",
                   ".jpeg", ".pdf", ".html", ".db", ".zip", ".tar", ".gz", ".xz", ".tgz"}
CODE_BUNDLES = {".app", ".appex", ".framework", ".bundle", ".xcframework", ".dSYM"}


class SafetyError(RuntimeError):
    pass


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1_048_576), b""):
            value.update(chunk)
    return value.hexdigest()


def manifest(directory):
    """Do not follow links, including links to data outside the bundle/cache."""
    result = {}
    for folder, dirs, files in os.walk(directory, followlinks=False):
        for name in dirs[:] + files:
            path = Path(folder) / name
            if path.is_symlink():
                result[str(path.relative_to(directory))] = "link:" + os.readlink(path)
                if name in dirs:
                    dirs.remove(name)
            elif path.is_file():
                result[str(path.relative_to(directory))] = digest(path)
    return result


def info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def owned(identifier):
    return isinstance(identifier, str) and (identifier == APP_ID or identifier.startswith(APP_ID + ".") or identifier in LEGACY_IDS)


def contains_data(directory):
    for folder, dirs, files in os.walk(directory, followlinks=False):
        dirs[:] = [d for d in dirs if not (Path(folder) / d).is_symlink()]
        if {"Application Support", "Insights", "DataSnapshots"}.intersection(dirs):
            return True
        if any(n in DATA_NAMES or ".sqlite" in n.lower() for n in files):
            return True
    return False


class MacRuntime:
    def validate(self, app):
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True)

    def in_use(self, path):
        command = ["lsof", "-Fpn", "+D", str(path)] if path.is_dir() else ["lsof", "-Fpn", "--", str(path)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            return True  # An unverified use check never authorizes deletion.
        return result.returncode not in (0, 1) or bool(result.stdout.strip()) or bool(result.stderr.strip())

    def unregister(self, app):
        # Only remove the exact existing obsolete copy, never reset/reseed the
        # database or force-register the running host (which can affect intents).
        tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        result = subprocess.run([tool, "-u", str(app)], capture_output=True, text=True)
        if result.returncode:
            raise SafetyError(f"Could not unregister obsolete application: {app}")


@dataclass
class Entry:
    path: Path
    kind: str
    files: dict
    logical_bytes: int
    apps: list = field(default_factory=list)


class Cleanup:
    def __init__(self, *, project, build_roots, cache_roots, scan_roots, receipt,
                 installed, rollback, current_files, previous_files, build, runtime=None):
        self.project = project.resolve()
        self.build_roots = [p.absolute() for p in build_roots]
        self.cache_roots = [p.absolute() for p in cache_roots]
        self.scan_roots = [p.absolute() for p in scan_roots]
        self.receipt = receipt.resolve()
        if installed.is_symlink() or rollback.is_symlink():
            raise SafetyError("Retained application paths must not be symlinks")
        self.installed, self.rollback = installed.resolve(), rollback.resolve()
        self.keep = {self.installed: current_files, self.rollback: previous_files}
        self.build = int(build)
        self.runtime = runtime or MacRuntime()
        self.entries = []
        self.skipped = []
        self.blocked_roots = []
        self.recovered_records = []
        self.unregistered_apps = []

    def retained_valid(self):
        for app, expected in self.keep.items():
            if app.is_symlink() or manifest(app) != expected:
                raise SafetyError(f"Retained application does not match its verified public archive: {app}")
            self.runtime.validate(app)

    def skip(self, path, reason):
        self.skipped.append({"path": str(path), "reason": reason})

    def add(self, path, kind, apps=()):
        if path.is_symlink() or self.receipt == path or self.receipt in path.parents:
            return
        resolved = path.resolve()
        if any(resolved == keep or resolved in keep.parents or keep in resolved.parents for keep in self.keep):
            raise SafetyError(f"Deletion overlaps retained application: {path}")
        if any(e.path == path or e.path in path.parents for e in self.entries):
            return
        if self.runtime.in_use(path):
            self.skip(path, "in use, or use could not be established")
            if path.is_dir():
                self.blocked_roots.append(path)
            return
        files = manifest(path) if path.is_dir() else {"": digest(path)}
        size = sum((path / rel).stat().st_size for rel, value in files.items() if not value.startswith("link:")) if path.is_dir() else path.stat().st_size
        self.entries.append(Entry(path, kind, files, size, list(apps)))

    def apps_under(self, root):
        result = []
        for folder, dirs, _ in os.walk(root, followlinks=False):
            path = Path(folder)
            dirs[:] = [d for d in dirs if d != ".git" and not (path / d).is_symlink()]
            if path.suffix != ".app":
                continue
            dirs[:] = []
            try:
                if owned(info(path).get("CFBundleIdentifier", "")):
                    result.append(path)
            except (OSError, ValueError, plistlib.InvalidFileException):
                continue
        return result

    def installer_zip(self, path):
        if not re.fullmatch(r"QuotAI(?:[-_].*)?\.zip", path.name, re.I):
            return False
        if any(word in path.stem.lower() for word in EVIDENCE_WORDS):
            return False
        try:
            with zipfile.ZipFile(path) as archive:
                names = [n for n in archive.namelist() if not n.startswith("__MACOSX/") and n != ".DS_Store"]
                # An archive containing data, source or acceptance fixtures is
                # never treated as an installer, regardless of its filename.
                if not names or any(not n.startswith("QuotAI.app/") for n in names):
                    return False
                if any(Path(n).name in DATA_NAMES or ".sqlite" in Path(n).name.lower() for n in names):
                    return False
                metadata = plistlib.loads(archive.read("QuotAI.app/Contents/Info.plist"))
                return metadata.get("CFBundleIdentifier") == APP_ID and int(metadata["CFBundleVersion"]) <= self.build
        except (OSError, KeyError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException):
            return False

    def duplicate_sdk(self, path):
        if path.parent.name != "SparkleSDK" or not re.fullmatch(r"Sparkle-[\d.]+\.zip", path.name):
            return False
        try:
            with zipfile.ZipFile(path) as archive:
                for name in ("sign_update", "generate_keys", "generate_appcast"):
                    matches = [n for n in archive.namelist() if n == "bin/" + name or n.endswith("/bin/" + name)]
                    if len(matches) != 1 or hashlib.sha256(archive.read(matches[0])).hexdigest() != digest(path.parent / "distribution/bin" / name):
                        return False
            return True
        except (OSError, zipfile.BadZipFile):
            return False

    def plan(self):
        self.retained_valid()
        for base in self.build_roots:
            if base.is_symlink():
                self.skip(base, "linked build root; external contents retained")
                self.blocked_roots.append(base)
        for cache in self.cache_roots:
            if any(p == cache or p in cache.parents for p in self.blocked_roots):
                continue
            if cache.is_symlink():
                self.skip(cache, "linked cache; external contents retained")
                self.blocked_roots.append(cache)
                continue
            if not cache.exists():
                continue
            if contains_data(cache):
                self.skip(cache, "contains possible user data; cache retained")
                self.blocked_roots.append(cache)
                continue
            apps = self.apps_under(cache)
            try:
                newer = any(int(info(p).get("CFBundleVersion")) > self.build for p in apps)
            except (TypeError, ValueError):
                newer = True
            if newer:
                self.skip(cache, "contains newer or unrecognized development build")
                self.blocked_roots.append(cache)
                continue
            self.add(cache, "cache", apps)
        for base in dict.fromkeys(self.build_roots + self.scan_roots):
            if not base.exists() or base.is_symlink():
                continue
            for app in self.apps_under(base):
                if app.resolve() in self.keep:
                    continue
                if any(p == app or p in app.parents for p in self.blocked_roots):
                    continue
                if any(e.path == app or e.path in app.parents for e in self.entries):
                    continue
                metadata = info(app)
                try:
                    app_build = int(metadata.get("CFBundleVersion"))
                except (TypeError, ValueError):
                    self.skip(app, "unknown development build")
                    continue
                if app_build > self.build:
                    self.skip(app, "newer development build")
                elif contains_data(app):
                    self.skip(app, "contains possible user data")
                else:
                    self.add(app, "app", [app])
            for folder, dirs, files in os.walk(base, followlinks=False):
                here = Path(folder)
                dirs[:] = [d for d in dirs if not d.endswith(".app") and d != ".git" and not (here / d).is_symlink()
                           and not any(e.path == here / d or e.path in (here / d).parents for e in self.entries)
                           and not any(p == here / d or p in (here / d).parents for p in self.blocked_roots)
                           and here / d != self.receipt]
                for name in files:
                    path = here / name
                    if path.is_symlink() or not path.is_file():
                        continue
                    if self.installer_zip(path) or self.duplicate_sdk(path):
                        self.add(path, "installer")
                    elif any(base == b or b in path.parents for b in self.build_roots) and "SparkleSDK" not in path.parts:
                        if "probe" in name.lower() and not any(w in name.lower() for w in EVIDENCE_WORDS):
                            with path.open("rb") as stream:
                                if stream.read(4) in MACHO:
                                    self.add(path, "compiled-probe")
        return self.entries

    def archive_records(self, entry):
        sources = []
        if (entry.path / "Logs").is_dir():
            sources.append(entry.path / "Logs")
        sources += [p for p in entry.path.rglob("*.xcresult") if not any(base in p.parents for base in sources)]
        for source in sources:
            if source.is_symlink():
                raise SafetyError(f"Build records contain an external directory link: {source}")
            destination = self.receipt / "Recovered-Build-Records" / hashlib.sha256(str(entry.path).encode()).hexdigest()[:12] / source.relative_to(entry.path)
            destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copytree(source, destination, symlinks=True)
            records = manifest(source)
            if records != manifest(destination):
                raise SafetyError(f"Build/test records were not archived intact: {source}")
            self.recovered_records.append({"source": str(source), "saved": str(destination),
                                           "files": len(records), "manifestSHA256": hashlib.sha256(
                                               json.dumps(records, sort_keys=True).encode()).hexdigest()})
        # Reports, screenshots and fixture inputs can live beside Logs. Keep
        # those too, while excluding reproducible code-bundle resources.
        for folder, dirs, files in os.walk(entry.path, followlinks=False):
            here = Path(folder)
            dirs[:] = [d for d in dirs if d != ".git" and not (here / d).is_symlink()
                       and Path(d).suffix not in CODE_BUNDLES
                       and not any(p == here / d or p in (here / d).parents for p in sources)]
            for name in files:
                source = here / name
                if source.suffix.lower() not in RECORD_SUFFIXES or name == "build.db":
                    continue
                if source.is_symlink():
                    raise SafetyError(f"Cache record is linked to external data: {source}")
                destination = self.receipt / "Recovered-Build-Records" / hashlib.sha256(str(entry.path).encode()).hexdigest()[:12] / source.relative_to(entry.path)
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                shutil.copy2(source, destination)
                value = digest(source)
                if value != digest(destination):
                    raise SafetyError(f"Cache record could not be preserved: {source}")
                self.recovered_records.append({"source": str(source), "saved": str(destination), "sha256": value})

    def apply(self):
        self.retained_valid()
        protected = {}
        for base in self.build_roots:
            if not base.exists() or base.is_symlink():
                continue
            for relative, value in manifest(base).items():
                path = base / relative
                if self.receipt == path or self.receipt in path.parents:
                    continue
                if not any(e.path == path or e.path in path.parents for e in self.entries):
                    protected[path] = value
        # Check every entry and recover every record before the first deletion.
        for entry in self.entries:
            if entry.path.is_symlink():
                raise SafetyError(f"Planned path became a symlink: {entry.path}")
            actual = manifest(entry.path) if entry.path.is_dir() else {"": digest(entry.path)}
            if actual != entry.files:
                raise SafetyError(f"Planned artifact changed; re-plan required: {entry.path}")
            if self.runtime.in_use(entry.path):
                raise SafetyError(f"Artifact became active; cleanup deferred: {entry.path}")
            if entry.kind == "cache":
                self.archive_records(entry)
        for entry in self.entries:
            # A build or app may start after the all-entry preflight. Do not
            # remove newly changed work even when earlier entries were cleared.
            actual = manifest(entry.path) if entry.path.is_dir() else {"": digest(entry.path)}
            if entry.path.is_symlink() or actual != entry.files or self.runtime.in_use(entry.path):
                raise SafetyError(f"Artifact changed or became active during cleanup: {entry.path}")
            for app in entry.apps:
                self.runtime.unregister(app)
                self.unregistered_apps.append(str(app))
            if entry.path.is_dir():
                shutil.rmtree(entry.path)
            else:
                entry.path.unlink()
        self.retained_valid()
        for path, expected in protected.items():
            actual = "link:" + os.readlink(path) if path.is_symlink() else digest(path)
            if actual != expected:
                raise SafetyError(f"Protected data/record changed during cleanup: {path}")
        self.preserved_files = len(protected)

    def summary(self):
        return {"retained": [str(p) for p in self.keep],
                "entries": [{"path": str(e.path), "kind": e.kind, "logicalBytes": e.logical_bytes} for e in self.entries],
                "logicalBytes": sum(e.logical_bytes for e in self.entries), "skipped": self.skipped,
                "preservedDataAndRecordFiles": getattr(self, "preserved_files", None),
                "recoveredRecords": self.recovered_records, "unregisteredAppPaths": self.unregistered_apps}
