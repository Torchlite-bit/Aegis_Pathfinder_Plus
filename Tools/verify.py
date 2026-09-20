#!/usr/bin/env python3
"""Offline verification for TurtleGuide.

Checks what can be checked without a WoW client:

  syntax   every Lua file parses
  lua50    no Lua 5.1-only constructs that would fail on the 1.12 client
  toc      every file the .toc loads exists, in order
  xml      every Guides.xml lists files that exist, and lists all of them
  media    every texture is a TGA the 1.12 client can load

Run from the repository root:  python3 Tools/verify.py
Exits non-zero if any check fails.
"""

import os
import re
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUAC = "luac5.1"

# Vendored Ace2 libraries are upstream code we do not police.
SKIP_DIRS = {".git", "libs", ".release"}


def walk(exts, skip=SKIP_DIRS):
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if os.path.splitext(fn)[1] in exts:
                yield os.path.join(dirpath, fn)


def rel(path):
    return os.path.relpath(path, ROOT)


class Report:
    def __init__(self):
        self.failures = []
        self.counts = {}

    def ok(self, check, n):
        self.counts[check] = n

    def fail(self, check, path, detail):
        self.failures.append((check, rel(path) if path else "-", detail))

    def summary(self):
        for check, n in self.counts.items():
            print("  %-8s %d passed" % (check, n))
        if not self.failures:
            print("\nAll checks passed.")
            return 0
        print("\n%d failure(s):\n" % len(self.failures))
        for check, path, detail in self.failures:
            print("  [%s] %s\n      %s" % (check, path, detail))
        return 1


def check_syntax(rep):
    files = sorted(walk({".lua"}))
    for path in files:
        proc = subprocess.run([LUAC, "-p", "-o", os.devnull, path],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            rep.fail("syntax", path, proc.stderr.strip().splitlines()[0])
    rep.ok("syntax", len(files))


# Constructs that parse under 5.1 but are absent from the 5.0 runtime in the
# 1.12 client. Each is (regex, explanation, replacement to use instead).
LUA50_BANNED = [
    (re.compile(r"[^%\w]#[A-Za-z_({\"']"), "# length operator", "table.getn() / string.len()"),
    (re.compile(r"\bstring\.gmatch\b|:gmatch\("), "string.gmatch", "string.gfind()"),
    # Bare select() only. TurtleGuide.select is the addon's own 5.0-safe
    # shim, so a qualified call is fine.
    (re.compile(r"(?<![.:\w])select\s*\(\s*[\"'#]"), "select()", "explicit named parameters"),
    (re.compile(r"\bmodule\s*\("), "module()", "a plain global table"),
    (re.compile(r"\b\d+//\d+"), "// integer division", "math.floor(a/b)"),
]


def pkgmeta_ignored():
    """Paths .pkgmeta excludes from the packaged addon.

    These are desktop-side tooling (converters, docs, task notes) that run on a
    normal Lua/Python install and never reach the 1.12 client, so the Lua 5.0
    restrictions do not apply to them.
    """
    path = os.path.join(ROOT, ".pkgmeta")
    if not os.path.exists(path):
        return set()
    body = open(path, encoding="utf-8").read()
    block = re.search(r"^ignore:\s*\n((?:\s+-\s+\S+\n?)+)", body, re.M)
    if not block:
        return set()
    return {m.strip() for m in re.findall(r"-\s+(\S+)", block.group(1))}


def is_shipped(path):
    relative = rel(path)
    for ignored in pkgmeta_ignored():
        if relative == ignored or relative.startswith(ignored.rstrip("/") + os.sep):
            return False
    return True


def strip_lua_noise(src):
    """Blank out comments and string literals so we only scan real code."""
    src = re.sub(r"--\[(=*)\[.*?\]\1\]", " ", src, flags=re.S)
    src = re.sub(r"--[^\n]*", " ", src)
    src = re.sub(r"\[(=*)\[.*?\]\1\]", '""', src, flags=re.S)
    src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)
    src = re.sub(r"'(?:\\.|[^'\\])*'", "''", src)
    return src


def check_lua50(rep):
    files = [p for p in sorted(walk({".lua"})) if is_shipped(p)]
    for path in files:
        code = strip_lua_noise(open(path, encoding="utf-8", errors="replace").read())
        for lineno, line in enumerate(code.splitlines(), 1):
            for pattern, what, instead in LUA50_BANNED:
                if pattern.search(line):
                    rep.fail("lua50", path,
                             "line %d uses %s (1.12 is Lua 5.0 -- use %s)"
                             % (lineno, what, instead))
    rep.ok("lua50", len(files))


def toc_entries(toc_path):
    for raw in open(toc_path, encoding="utf-8", errors="replace"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        yield line.replace("\\", os.sep)


def check_toc(rep):
    tocs = sorted(walk({".toc"}))
    if not tocs:
        rep.fail("toc", None, "no .toc file found")
        return
    n = 0
    for toc in tocs:
        # WoW requires Interface/AddOns/<Folder>/<Folder>.toc -- the packager
        # supplies the folder name, so the .toc basename must match package-as.
        pkg = os.path.join(ROOT, ".pkgmeta")
        if os.path.exists(pkg):
            m = re.search(r"^package-as:\s*(\S+)", open(pkg).read(), re.M)
            if m and m.group(1) != os.path.splitext(os.path.basename(toc))[0]:
                rep.fail("toc", toc, "basename must match .pkgmeta package-as (%s)" % m.group(1))
        for entry in toc_entries(toc):
            target = os.path.join(os.path.dirname(toc), entry)
            if not os.path.exists(target):
                rep.fail("toc", toc, "missing file: %s" % entry)
            n += 1
    rep.ok("toc", n)


def check_xml(rep):
    n = 0
    for xml in sorted(walk({".xml"})):
        body = open(xml, encoding="utf-8", errors="replace").read()
        listed = set(re.findall(r'<Script\s+file="([^"]+)"', body))
        folder = os.path.dirname(xml)
        for entry in sorted(listed):
            if not os.path.exists(os.path.join(folder, entry)):
                rep.fail("xml", xml, "lists missing file: %s" % entry)
            n += 1
        # A guide file nobody lists never loads -- silent content loss.
        on_disk = {f for f in os.listdir(folder) if f.endswith(".lua")}
        for orphan in sorted(on_disk - listed):
            rep.fail("xml", xml, "file on disk is not listed: %s" % orphan)
    rep.ok("xml", n)


def check_media(rep):
    files = sorted(walk({".tga", ".blp"}))
    for path in files:
        if path.endswith(".blp"):
            continue
        with open(path, "rb") as fh:
            header = fh.read(18)
        if len(header) < 18:
            rep.fail("media", path, "truncated TGA header")
            continue
        image_type = header[2]
        width, height, depth = struct.unpack("<HHB", header[12:17])
        if image_type not in (2, 10):
            rep.fail("media", path, "image type %d; 1.12 wants uncompressed/RLE truecolor" % image_type)
        if depth != 32:
            rep.fail("media", path, "%d-bit; 1.12 textures must be 32-bit" % depth)
        for label, value in (("width", width), ("height", height)):
            if value == 0 or (value & (value - 1)) != 0:
                rep.fail("media", path, "%s %d is not a power of two" % (label, value))
    rep.ok("media", len(files))


def main():
    print("Verifying %s\n" % ROOT)
    rep = Report()
    check_syntax(rep)
    check_lua50(rep)
    check_toc(rep)
    check_xml(rep)
    check_media(rep)
    return rep.summary()


if __name__ == "__main__":
    sys.exit(main())
