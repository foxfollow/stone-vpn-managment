#!/bin/bash
# StoneVPNKit test coverage (after `swift test --enable-code-coverage`) → SonarQube generic
# coverage XML on stdout, paths relative to the repo root.
#   tools/coverage-to-sonar.sh app/Packages/StoneVPNKit > sonar-coverage.xml
set -euo pipefail
PKG="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --package-path "$PKG" --show-bin-path)"
PROF="$(find "$BIN" "$PKG/.build" -name default.profdata -path '*codecov*' 2>/dev/null | head -1)"
# Test bundle name differs between SwiftPM versions (<Pkg>PackageTests.xctest vs <Target>.xctest):
# take the one the last `swift test` built.
XCTEST="$(ls -td "$BIN"/*.xctest 2>/dev/null | head -1)"
[[ -n "$PROF" && -n "$XCTEST" ]] || { echo "no coverage data — run swift test --enable-code-coverage first" >&2; exit 1; }
EXE="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"

xcrun llvm-cov export -format=lcov -instr-profile "$PROF" "$EXE" \
  -ignore-filename-regex='/(\.build|Tests|checkouts)/' |
python3 -c '
import sys, os, html
root = os.path.realpath(sys.argv[1])
files, cur = {}, None
for line in sys.stdin:
    line = line.strip()
    if line.startswith("SF:"):
        path = os.path.relpath(os.path.realpath(line[3:]), root)
        cur = None if path.startswith("..") else files.setdefault(path, {})
    elif line.startswith("DA:") and cur is not None:
        n, hits = line[3:].split(",")[:2]
        cur[int(n)] = cur.get(int(n), 0) + int(hits)
    elif line == "end_of_record":
        cur = None
print("<coverage version=\"1\">")
for f in sorted(files):
    print(f"  <file path=\"{html.escape(f)}\">")
    for n in sorted(files[f]):
        print(f"    <lineToCover lineNumber=\"{n}\" covered=\"{str(files[f][n] > 0).lower()}\"/>")
    print("  </file>")
print("</coverage>")
' "$ROOT"
