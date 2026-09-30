#!/bin/bash
# Builds the release zip: unzip it at the root of an SD card and hub, and the
# library for programs compiled on the Agon, land where they are looked for.
#
#   mos/hub.bin                     a moslet, so `hub` works as a command
#   lib/acc/libhub.a                the client library, for acc on the Agon
#   lib/acc/include/hub/hub.h       its header; acc searches lib/acc/include
#                                   for every #include
#
# A program on the Agon then builds with nothing more than
#
#   acc main.c /lib/acc/libhub.a
#
# and includes <hub/hub.h>. Also builds hub-libs-<version>.tar.gz, the library
# for agondev and acc on a PC or Mac, with mklibs.sh.
#
# Usage: ./mkrelease.sh [output directory]   (default: .)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^ *db *"\(.*\)".*/\1/p' src/version.inc)
DEST=${1:-.}
if [ -z "$VERSION" ]; then
    echo "mkrelease: no version in src/version.inc" >&2

    exit 1
fi
if ! command -v zip >/dev/null; then
    echo "mkrelease: zip is not installed" >&2

    exit 1
fi

# Built fresh, not whatever is lying in build/. A release made from a stale
# binary is the kind of mistake that is only found by a user.
make -s build/hub.bin build/lib/acc/libhub.a >/dev/null

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/mos" "$STAGE/lib/acc/include/hub"
cp build/hub.bin "$STAGE/mos/"
cp build/lib/acc/libhub.a "$STAGE/lib/acc/"
cp include/hub/hub.h "$STAGE/lib/acc/include/hub/"

OUT="$(cd "$DEST" && pwd)/hub-$VERSION.zip"
rm -f "$OUT"
(cd "$STAGE" && zip -q -r -X "$OUT" .)
echo "$OUT"

./mklibs.sh "$DEST"
