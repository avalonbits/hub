#!/bin/bash
# Packages hub's client library for programs built on a PC or Mac:
#
#   include/hub/hub.h         the C API
#   include/hub/hub.inc       the same for zap programs
#   lib/agondev/libhub.a      the glue, as an ELF archive for agondev
#   lib/acc/libhub.a          the same glue, as an ACC archive for acc
#   VERSION                   hub's version and the commit they were built from
#
# Both archives are assembled by zap from the one source, lib/hub_glue.s.
# mkrelease.sh attaches the result to each release as hub-libs-<version>.tar.gz;
# test/libs.sh builds against it.
#
# Usage: ./mklibs.sh [output directory]   (default: .)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(sed -n 's/^ *db *"\(.*\)".*/\1/p' src/version.inc)
DEST=${1:-.}
if [ -z "$VERSION" ]; then
    echo "mklibs: no version in src/version.inc" >&2

    exit 1
fi

# Built fresh, not whatever is lying in build/.
make -s build/lib/agondev/libhub.a build/lib/acc/libhub.a >/dev/null

NAME="hub-libs-$VERSION"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$NAME/include/hub" "$STAGE/$NAME/lib/agondev" "$STAGE/$NAME/lib/acc"
cp include/hub/hub.h src/hub.inc "$STAGE/$NAME/include/hub/"
cp build/lib/agondev/libhub.a "$STAGE/$NAME/lib/agondev/"
cp build/lib/acc/libhub.a "$STAGE/$NAME/lib/acc/"
# The commit they were built from -- marked -dirty when the tree had changes
# that commit does not hold, so a package built from work in progress does
# not claim to be something it is not.
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$COMMIT" != unknown ] && ! git diff --quiet HEAD 2>/dev/null; then
    COMMIT="$COMMIT-dirty"
fi
{
    echo "hub $VERSION"
    echo "commit $COMMIT"
} > "$STAGE/$NAME/VERSION"

OUT="$DEST/$NAME.tar.gz"
tar -C "$STAGE" -czf "$OUT" "$NAME"
echo "$OUT"
