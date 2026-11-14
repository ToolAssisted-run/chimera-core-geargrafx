#!/bin/sh
# Applies patches/ to the extern/geargrafx submodule's working tree. The
# submodule is pinned to unmodified upstream; this runs at every meson
# configure and does nothing when the patches are already in.
#
# All or nothing: one marker string decides. After changing patches/, put the
# submodule back to its pinned commit (git -C extern/geargrafx checkout .)
# before the next configure.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
sub="$root/extern/geargrafx"

# a clone made without its submodule has an empty folder here, and git would
# then answer for this repository instead
[ "$(git -C "$sub" rev-parse --show-toplevel 2>/dev/null)" = "$sub" ] || {
	echo "extern/geargrafx is not checked out: git submodule update --init" >&2; exit 1; }

if grep -q "GG_CHIMERA" "$sub/src/defines.h" 2>/dev/null; then
	exit 0
fi

for p in "$root"/patches/*.patch; do
	git -C "$sub" apply "$p"
	echo "applied $(basename "$p")"
done
