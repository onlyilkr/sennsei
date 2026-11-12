#!/usr/bin/env python3
"""Fail when two SwiftPM modules define the same async function pointer with different context sizes.

usage: scripts/check-async-odr.py BUILD_DIR [BUILD_DIR ...]

BUILD_DIR is a SwiftPM release build directory, for example
Packages/HeadsetKit/.build/arm64-apple-macosx/release (`swift build --show-bin-path`).

Background. Generic stdlib async functions such as Clock.sleep(for:tolerance:) are specialized inside every
module that calls them and emitted as weak symbols; the linker keeps one copy. Each specialization has a
function body and an async function pointer record (symbol suffix `Tu`) that states how many bytes of async
context a caller must allocate. The linker merges the two independently. When modules were compiled with
different language features (a dependency built with its own swift-tools-version or default isolation), the
copies can need different context sizes, and the linked binary can pair one module's body with another
module's record. Callers then allocate too little and corrupt the task allocator at run time.

This script reads the context size of every weak `Tu` symbol in every non-test module object and reports any
symbol defined in more than one module with differing sizes. Exit status: 0 consistent, 1 mismatch found,
2 usage error or missing tool/directory. Needs Xcode command line tools (nm, otool, swift-demangle).
"""
import collections
import glob
import os
import re
import struct
import subprocess
import sys

NM_LINE = re.compile(r"^([0-9a-f]{16}) \((\S+)\) (.*) (\S+)$")
SECTION = re.compile(r"addr (0x[0-9a-f]+)\n\s+size (0x[0-9a-f]+)\n\s+offset (\d+)")


def fail(message):
    print(f"check-async-odr: error: {message}", file=sys.stderr)
    sys.exit(2)


def run(*cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        fail(f"{cmd[0]} not found; install the Xcode command line tools")
    except subprocess.CalledProcessError as error:
        fail(f"{' '.join(cmd)} failed: {error.stderr.strip()}")
    return result.stdout


def module_of(obj):
    return os.path.basename(os.path.dirname(obj))[: -len(".build")]


def scan(obj):
    """Returns {symbol: context size} for the weak async function pointers defined in obj."""
    pointers = []
    for line in run("nm", "-m", obj).splitlines():
        m = NM_LINE.match(line)
        if m and m.group(4).endswith("Tu") and "weak" in m.group(3):
            pointers.append((int(m.group(1), 16), m.group(4)))
    if not pointers:
        return {}
    sections = [(int(a, 16), int(s, 16), int(o)) for a, s, o in SECTION.findall(run("otool", "-l", obj))]
    with open(obj, "rb") as handle:
        data = handle.read()
    sizes = {}
    for address, symbol in pointers:
        for start, length, offset in sections:
            if start <= address < start + length:
                # AsyncFunctionPointer: int32 relative function pointer, uint32 expected context size.
                _, size = struct.unpack_from("<iI", data, offset + address - start)
                sizes[symbol] = size
                break
    return sizes


def demangle(symbol):
    out = run("xcrun", "swift-demangle", symbol.lstrip("_")).strip()
    return out.split(" ---> ", 1)[-1] if out else symbol


def check_directory(directory):
    """Returns (objects, symbols, shared, problems) for one build directory."""
    by_symbol = collections.defaultdict(lambda: collections.defaultdict(set))  # symbol -> module -> sizes
    objects = 0
    for obj in sorted(glob.glob(os.path.join(directory, "*.build", "*.o"))):
        module = module_of(obj)
        if module.endswith("Tests") or module.endswith("PackageTests"):
            continue
        objects += 1
        for symbol, size in scan(obj).items():
            by_symbol[symbol][module].add(size)
    if objects == 0:
        fail(f"no *.build/*.o module objects under {directory}; is this a SwiftPM build directory?")
    problems = [
        (symbol, modules)
        for symbol, modules in sorted(by_symbol.items())
        if len(modules) > 1 and len({s for v in modules.values() for s in v}) > 1
    ]
    shared = sum(1 for modules in by_symbol.values() if len(modules) > 1)
    return objects, len(by_symbol), shared, problems


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        sys.exit(0 if argv else 2)
    for directory in argv:
        if not os.path.isdir(directory):
            fail(f"{directory} is not a directory")
    status = 0
    for directory in argv:  # each directory (for example one per architecture) is checked on its own
        objects, symbols, shared, problems = check_directory(directory)
        if not problems:
            print(f"check-async-odr: ok ({directory}): {symbols} weak async function pointers in {objects} module "
                  f"objects, {shared} defined in more than one module, all with matching context sizes")
            continue
        status = 1
        print(f"check-async-odr: FAILED ({directory}): async function pointers defined in several modules "
              "with different context sizes:\n")
        for symbol, modules in problems:
            print(f"  {demangle(symbol)}\n  {symbol}")
            for module, sizes in sorted(modules.items()):
                print(f"      {module}: {', '.join(str(s) for s in sorted(sizes))} bytes")
            print()
    if status:
        print(textwrap_explanation())
    return status


def textwrap_explanation():
    return (
        "Why this matters: the linker coalesces the weak function body and its async function pointer record\n"
        "independently, so the linked binary can contain one module's body with another module's (smaller) context\n"
        "size; callers then allocate too little async context and the task allocator aborts at run time. Modules\n"
        "compiled with different language features (a dependency with another swift-tools-version, default\n"
        "isolation or NonisolatedNonsendingByDefault) can emit incompatible copies of the same generic stdlib\n"
        "specialization. What to do: stop calling the generic API from our modules (for sleeping use Pause.sleep,\n"
        "which calls the non-generic Task.sleep(nanoseconds:)), or align the language settings, then rebuild."
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
