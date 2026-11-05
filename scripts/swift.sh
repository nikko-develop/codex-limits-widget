#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
mkdir -p "$project_dir/.build/toolchain"

# Some upgraded Command Line Tools retain stale interface/module-map files.
# A build-local VFS overlay avoids changing anything in the installed toolchain.
python3 - "$project_dir/.build/toolchain" "$(xcode-select -p)" <<'PY'
import json
import pathlib
import sys

output, developer = map(pathlib.Path, sys.argv[1:])
toolchain = developer / 'Toolchains/XcodeDefault.xctoolchain'
if not toolchain.exists():
    toolchain = developer
roots = []
legacy = toolchain / 'usr/include/swift/module.modulemap'
modern = toolchain / 'usr/include/swift/bridging.modulemap'
if legacy.exists() and modern.exists() and 'module SwiftBridging' in legacy.read_text():
    empty = output / 'empty.modulemap'
    empty.write_text('// Legacy duplicate module map hidden for this build.\n')
    roots.append({'type': 'file', 'name': str(legacy), 'external-contents': str(empty)})
interfaces = toolchain / 'usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule'
for private in interfaces.glob('*.private.swiftinterface'):
    public = private.with_name(private.name.replace('.private.swiftinterface', '.swiftinterface'))
    if public.exists() and 'swiftLanguageModes' in public.read_text() and 'swiftLanguageModes' not in private.read_text():
        roots.append({'type': 'file', 'name': str(private), 'external-contents': str(public)})
(output / 'overlay.json').write_text(json.dumps({'version': 0, 'case-sensitive': 'false', 'roots': roots}))
(output / 'needs-overlay').write_text('yes' if roots else '')
PY

swift_command="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
flags=(--cache-path "$project_dir/.build/cache" --config-path "$project_dir/.build/config"
       --security-path "$project_dir/.build/security")
if [ -s "$project_dir/.build/toolchain/needs-overlay" ]; then
    export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCacheOverlay"
    overlay="$project_dir/.build/toolchain/overlay.json"
    flags+=(-Xbuild-tools-swiftc -vfsoverlay -Xbuild-tools-swiftc "$overlay"
            -Xbuild-tools-swiftc -Xcc -Xbuild-tools-swiftc -ivfsoverlay
            -Xbuild-tools-swiftc -Xcc -Xbuild-tools-swiftc "$overlay"
            -Xswiftc -vfsoverlay -Xswiftc "$overlay" -Xcc -ivfsoverlay -Xcc "$overlay")
fi
exec swift "$swift_command" "${flags[@]}" "$@"
