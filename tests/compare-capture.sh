#!/bin/bash
# compare-capture.sh: byte-compare every file in sync-manifest.conf with a
# read-only capture of the VM (tools/node-capture), so drift between git and
# the live server shows up file by file.
#
# Usage: bash tests/compare-capture.sh <capture-fs-dir>
#   e.g. bash tests/compare-capture.sh source-material/node-capture-20261118/Monitoring-VM-001/fs
#
# Exit 0 when every file matches, 1 when any differs or is missing.

set -euo pipefail
cd "$(dirname "$0")/.."

FS=${1:?usage: $0 <capture-fs-dir>}
[[ -d "$FS" ]] || { echo "not a directory: $FS" >&2; exit 2; }

same=0 diff=0
while read -r repo dest _owner _mode _apply; do
    [[ -z "$repo" || "$repo" == \#* ]] && continue
    live="$FS$dest"
    if [[ ! -f "$live" ]]; then
        echo "MISSING  $dest (not in capture)"; diff=$((diff+1))
    elif cmp -s "$repo" "$live"; then
        echo "SAME     $repo"; same=$((same+1))
    else
        echo "DIFFERS  $repo"; diff=$((diff+1))
    fi
done < sync-manifest.conf

echo "same=$same differs=$diff"
(( diff == 0 ))
