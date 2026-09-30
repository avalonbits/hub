#!/bin/bash
# The library package mklibs.sh builds, as a program on a PC or Mac gets it.
#
# The C client is built against the package and nothing else -- by agondev
# with the lines the README gives, and by acc's host build -- and each build
# must come out byte for byte the same as the client test/run.sh runs under
# hub in the emulator. So what the package holds is what was tested.
#
# Needs agondev (AGONDEV, default ~/agondev) and acc's host build (ACC).
set -uo pipefail
cd "$(dirname "$0")/.."

AGONDEV=${AGONDEV:-$HOME/agondev}
ACC=${ACC:-$HOME/code/acc/bin/acc}

status=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'PASS  %-52s %s\n' "$1" "$2"
    else
        printf 'FAIL  %-52s got %s, want %s\n' "$1" "$2" "$3"
        status=1
    fi
}

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

make -s >/dev/null 2>&1 || { echo "FAIL  libs: the build failed"; exit 1; }
TGZ=$(./mklibs.sh "$W" 2>/dev/null) || { echo "FAIL  libs: mklibs.sh failed"; exit 1; }
tar -C "$W" -xzf "$TGZ"
VERSION=$(sed -n 's/^ *db *"\(.*\)".*/\1/p' src/version.inc)
PKG="$W/hub-libs-$VERSION"

check "the package is named after src/version.inc" "$(basename "$TGZ")" "hub-libs-$VERSION.tar.gz"
check "  and holds the headers and both archives" \
      "$(cd "$PKG" && find . -type f | sort | tr '\n' ' ')" \
      "./VERSION ./include/hub/hub.h ./include/hub/hub.inc ./lib/acc/libhub.a ./lib/agondev/libhub.a "
want="$(git rev-parse HEAD)"
git diff --quiet HEAD || want="$want-dirty"
check "  and names the commit it was built from" \
      "$(sed -n 's/^commit //p' "$PKG/VERSION")" "$want"

# agondev: a project using only the package, set up as the README says.
d="$W/agondev"
mkdir -p "$d/src"
cp test/c/src/main.c "$d/src/"
cat > "$d/Makefile" <<MK
NAME=cclient
include \$(shell agondev-config --makefile)
CFLAGS += -I$PKG/include
PROJECTLIBDIR := $PKG/lib/agondev
LIBS := -lhub
MK
(cd "$d" && PATH="$AGONDEV/bin:$PATH" make >/dev/null 2>&1)
if cmp -s "$d/bin/cclient.bin" build/test/cclient.bin; then
    check "agondev builds the tested client from the package" same same
else
    check "agondev builds the tested client from the package" different same
fi

# acc on the host: the package's header directory and archive, named.
"$ACC" test/c/src/main.c -DCLIENT_ACC -I"$PKG/include" "$PKG/lib/acc/libhub.a" \
    -o "$W/cclienta.bin" >/dev/null 2>&1
if cmp -s "$W/cclienta.bin" build/test/cclienta.bin; then
    check "acc builds the tested client from the package" same same
else
    check "acc builds the tested client from the package" different same
fi

exit $status
