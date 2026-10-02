#!/bin/bash
# Builds a release: three zips, one for people who use hub and one for each
# compiler a program for hub is built with.
#
#   hub-<version>.zip           unzip at the root of the SD card:
#       mos/hub.bin                 hub itself
#
#   hub-acc-<version>.zip       for acc. Unzip at the root of the SD card,
#                               where acc's own release put /lib/acc, and a
#                               program on the Agon builds with
#                               `acc main.c /lib/acc/libhub.a`; or anywhere
#                               on a PC or Mac, for acc there:
#       lib/acc/libhub.a            the client library
#       lib/acc/include/hub/        hub.h, hub.inc for zap programs, VERSION
#
#   hub-agondev-<version>.zip   for agondev. Unzip in agondev's own directory
#                               (agondev-config --prefix), which every
#                               agondev project searches, and a program needs
#                               only `LIBS := -lhub` in its Makefile:
#       lib/libhub.a                the client library
#       include/hub/                hub.h, hub.inc, VERSION
#
# VERSION gives hub's version and the commit the release was built from.
#
# Usage: ./mkrelease.sh [output directory]   (default: .)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^ *db *"\(.*\)".*/\1/p' src/version.inc)
DEST=$(cd "${1:-.}" && pwd)
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
make -s build/hub.bin build/lib/agondev/libhub.a build/lib/acc/libhub.a >/dev/null

# The commit -- marked -dirty when the tree had changes that commit does not
# hold, so a release built from work in progress does not claim to be
# something it is not.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$COMMIT" != unknown ] && ! git diff --quiet HEAD 2>/dev/null; then
    COMMIT="$COMMIT-dirty"
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# headers <dir>: the public headers and VERSION into <dir>.
headers() {
    mkdir -p "$1"
    cp include/hub/hub.h src/hub.inc "$1/"
    printf 'hub %s\ncommit %s\n' "$VERSION" "$COMMIT" > "$1/VERSION"
}

# pack <name> <stage dir>: zip the stage dir's contents as <name>.
pack() {
    rm -f "$DEST/$1"
    (cd "$2" && zip -q -r -X "$DEST/$1" .)
    echo "$DEST/$1"
}

mkdir -p "$STAGE/hub/mos"
cp build/hub.bin "$STAGE/hub/mos/"
pack "hub-$VERSION.zip" "$STAGE/hub"

mkdir -p "$STAGE/acc/lib/acc"
cp build/lib/acc/libhub.a "$STAGE/acc/lib/acc/"
headers "$STAGE/acc/lib/acc/include/hub"
pack "hub-acc-$VERSION.zip" "$STAGE/acc"

mkdir -p "$STAGE/agondev/lib"
cp build/lib/agondev/libhub.a "$STAGE/agondev/lib/"
headers "$STAGE/agondev/include/hub"
pack "hub-agondev-$VERSION.zip" "$STAGE/agondev"
