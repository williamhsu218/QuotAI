#!/usr/bin/env python3
"""Register App/Core Swift sources without rewriting existing project objects."""
from pathlib import Path
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "QuotAI.xcodeproj/project.pbxproj"
text = PROJECT.read_text()
objects = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(PROJECT)]))["objects"]
groups = {}
files = set()


def identity(kind, path):
    return hashlib.sha1(f"QuotAI:{kind}:{path}".encode()).hexdigest()[:24].upper()


def walk(identifier, parent=""):
    item = objects[identifier]
    path = item.get("path", "")
    location = str(Path(parent) / path) if path else parent
    if item.get("isa") == "PBXGroup":
        groups[location] = identifier
        for child in item.get("children", []):
            walk(child, location)
    elif item.get("lastKnownFileType") == "sourcecode.swift":
        files.add(path if item.get("sourceTree") == "SOURCE_ROOT" else location)


walk("800000000000000000000001")


def insert(section, value):
    global text
    marker = f"/* End {section} section */"
    if marker not in text:
        raise ValueError(f"Missing project section: {section}")
    text = text.replace(marker, value + "\n" + marker, 1)


def append_list(identifier, key, child, label):
    global text
    pattern = rf"({identifier}\b[^=]*=\s*\{{.*?\b{key}\s*=\s*\()(.*?)(\);)"
    match = re.search(pattern, text, re.S)
    if not match:
        raise ValueError(f"Missing {key} for {identifier}")
    replacement = match.group(1) + match.group(2) + f"\n\t\t\t\t{child} /* {label} */,\n\t\t\t" + match.group(3)
    text = text[:match.start()] + replacement + text[match.end():]


def ensure_group(path):
    if path in groups:
        return groups[path]
    parent = str(Path(path).parent)
    if parent == ".":
        parent = ""
    parent_id = ensure_group(parent)
    identifier = identity("group", path)
    name = Path(path).name
    insert("PBXGroup", f'\t\t{identifier} /* {name} */ = {{isa = PBXGroup; children = (); path = "{name}"; sourceTree = "<group>"; }};')
    append_list(parent_id, "children", identifier, name)
    groups[path] = identifier
    return identifier


added = []
for path in sorted(list((ROOT / "App").rglob("*.swift")) + list((ROOT / "Core").rglob("*.swift"))):
    relative = path.relative_to(ROOT).as_posix()
    if relative in files:
        continue
    group_id = ensure_group(path.parent.relative_to(ROOT).as_posix())
    file_id, build_id = identity("file", relative), identity("app-source", relative)
    insert("PBXFileReference", f'\t\t{file_id} /* {path.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>"; }};')
    insert("PBXBuildFile", f"\t\t{build_id} /* {path.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id}; }};")
    append_list(group_id, "children", file_id, path.name)
    append_list("300000000000000000000001", "files", build_id, path.name + " in Sources")
    added.append(relative)

PROJECT.write_text("\n".join(line.rstrip() for line in text.splitlines()) + "\n")
subprocess.run(["plutil", "-lint", str(PROJECT)], check=True)
print(f"Registered {len(added)} new Swift sources.")
