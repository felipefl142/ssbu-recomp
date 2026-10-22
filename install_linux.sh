#!/usr/bin/env bash
# The Linux counterpart of "Install SSBU.bat" (scripts/install.py is Windows-only): from your own game packages to a
# playable native build. Every step is skipped when its result is already there, so run it again after a stop.
#
#   ./install_linux.sh --base <base.nsp> --update <13.0.4 or 13.0.5 update.nsp> [--dlc <folder or .nsp>]...
#                      [--keys <prod.keys>] [--jobs N] [--no-desktop]
#
# Steps: 1. deps (scripts/linux/install_deps.sh, once)   2. keys (~/.switch/prod.keys, or --keys)
#        3. dump  build-linux/dump from base + update (tools/extract/dump_folder.py)
#        4. dlc   build-linux/config/dlc.txt from the DLC file names (the runtime unlocks that content; names only)
#        5. build scripts/setup.py --target linux (about 1.5 hours, resumable)
#        6. a "Super Smash Bros. Ultimate (recomp)" entry in the application menu (scripts/linux/install_desktop.sh)
# Then play with ./play.sh (the counterpart of "Play SSBU.bat").
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PY="$REPO/deps/venv/bin/python"
BUILD="$REPO/build-linux"
DUMP="$BUILD/dump"

BASE="" UPDATE="" KEYS="" JOBS="" DESKTOP=1
DLC=()
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="$2"; shift 2 ;;
        --update) UPDATE="$2"; shift 2 ;;
        --dlc) DLC+=("$2"); shift 2 ;;
        --keys) KEYS="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --no-desktop) DESKTOP=0; shift ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (--help lists them)" >&2; exit 2 ;;
    esac
done

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------- 1. deps
# the venv's own python must run (a venv whose lib/ is gone still has bin/python, but not its packages)
if "$PY" -c 'import numpy, lz4, zstandard, unicorn, Crypto' 2>/dev/null \
        && [ -f "$REPO/deps/Vulkan-Headers/include/vulkan/vulkan.h" ]; then
    say "1. deps: present"
else
    say "1. deps: scripts/linux/install_deps.sh"
    "$PY" -m pip --version >/dev/null 2>&1 || rm -rf "$REPO/deps/venv"
    "$REPO/scripts/linux/install_deps.sh" --no-system
fi

# ---------------------------------------------------------------------------------------------- 2. keys
if [ -n "$KEYS" ]; then
    [ -f "$KEYS" ] || die "--keys $KEYS: no such file"
    export SSBU_PROD_KEYS="$(readlink -f "$KEYS")"          # read by tools/extract/romfs_extract.py; no copy is made
    say "2. keys: $SSBU_PROD_KEYS"
elif [ -f "$HOME/.switch/prod.keys" ]; then
    say "2. keys: ~/.switch/prod.keys"
else
    die "no prod.keys: put yours in ~/.switch/prod.keys or pass --keys <file>"
fi

# ---------------------------------------------------------------------------------------------- 3. dump
if [ -f "$DUMP/exefs/main" ] && [ -f "$DUMP/romfs/data.arc" ]; then
    say "3. dump: $DUMP is there"
else
    [ -n "$BASE" ] && [ -n "$UPDATE" ] || die "no dump yet: give --base <base game .nsp/.xci> and --update <13.0.4 or 13.0.5 .nsp>"
    [ -f "$BASE" ] || die "--base $BASE: no such file"
    [ -f "$UPDATE" ] || die "--update $UPDATE: no such file"
    # the update's version is in its file name more often than not: catch a wrong one before a 16 GB extraction
    case "$(basename "$UPDATE")" in
        *v1966080*|*v2031616*) ;;
        *\[v[0-9]*\]*) die "$(basename "$UPDATE") is not 13.0.4 (v1966080) or 13.0.5 (v2031616), the only versions this port runs" ;;
    esac
    if [ -f "$DUMP/romfs/data.arc" ]; then
        say "3. dump: the RomFS is there, extracting the ExeFS only"
        "$PY" -I "$REPO/tools/extract/dump_folder.py" "$BASE" "$UPDATE" "$DUMP" --exefs-only
    else
        say "3. dump: base + update -> $DUMP (about 16 GB; takes a few minutes)"
        rm -rf "$DUMP.partial"
        mkdir -p "$BUILD"
        "$PY" -I "$REPO/tools/extract/dump_folder.py" "$BASE" "$UPDATE" "$DUMP.partial"
        rm -rf "$DUMP"
        mv "$DUMP.partial" "$DUMP"
    fi
fi

# ---------------------------------------------------------------------------------------------- 4. dlc
if [ ${#DLC[@]} -eq 0 ]; then
    say "4. dlc: none given (--dlc <folder>); nothing is unlocked"
else
    say "4. dlc: $BUILD/config/dlc.txt"
    # same rule as scripts/install.py dlc_rows: add-on id = application id + 0x1000 + index, read from [01006A800016Fxxx]
    "$PY" -I - "$BUILD/config/dlc.txt" "${DLC[@]}" <<'EOF'
import os, re, sys
out, paths = sys.argv[1], sys.argv[2:]
names = []
for p in paths:
    names += sorted(os.listdir(p)) if os.path.isdir(p) else [os.path.basename(p)]
rows = {}
for name in names:
    for m in re.finditer(r'\[([0-9A-Fa-f]{16})\]', name):
        index = int(m.group(1), 16) - 0x01006A800016E000 - 0x1000
        if 0 < index < 0x1000:
            rows[index] = ' '.join(re.sub(r'\[[^\]]*\]', ' ', os.path.splitext(name)[0]).split())
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, 'w', encoding='utf-8') as f:
    f.write('# add-on contents owned (index = add-on content id - application id - 0x1000); written by install_linux.sh\n')
    for index in sorted(rows):
        f.write('0x%03x   # %s\n' % (index, rows[index]))
print('   %d add-on contents listed' % len(rows))
EOF
fi

# ---------------------------------------------------------------------------------------------- 5. build
say "5. build: scripts/setup.py --target linux (about 1.5 hours the first time; Ctrl+C and run again to resume)"
SETUP=("$PY" "$REPO/scripts/setup.py" --target linux --dump "$DUMP")
[ -n "$JOBS" ] && SETUP+=(--jobs "$JOBS")
"${SETUP[@]}"

# ---------------------------------------------------------------------------------------------- 6. menu entry
if [ "$DESKTOP" = 1 ]; then
    say "6. application menu entry"
    "$REPO/scripts/linux/install_desktop.sh"
fi

say "done. Play: ./play.sh (or \"Super Smash Bros. Ultimate (recomp)\" in your application menu)"
