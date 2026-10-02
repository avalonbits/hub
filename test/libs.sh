#!/bin/bash
# The release's zips, as the people they are for use them.
#
# hub-agondev-<version>.zip is unzipped into a copy of agondev's own
# directory, and the C client is built by a project whose Makefile names
# nothing but `LIBS := -lhub`. hub-acc-<version>.zip is unzipped, and acc's
# host build builds the client from it. Each build must come out byte for
# byte the same as the client test/run.sh runs under hub in the emulator, so
# what the zips hold is what was tested. (test/run.sh unzips hub's zip and
# the acc zip onto a card, and has acc build the client on the Agon.)
#
# Needs agondev (AGONDEV, default ~/agondev) and acc's host build (ACC).
set -uo pipefail
cd "$(dirname "$0")/.."

AGONDEV=${AGONDEV:-$HOME/agondev}
ACC=${ACC:-$HOME/code/acc/bin/acc}

status=0
check() {
    if [ "$2" = "$3" ]; then
        printf 'PASS  %-56s %s\n' "$1" "$2"
    else
        printf 'FAIL  %-56s got %s, want %s\n' "$1" "$2" "$3"
        status=1
    fi
}
same() { cmp -s "$1" "$2" && echo same || echo different; }
contents() { unzip -Z1 "$1" | grep -v '/$' | sort | tr '\n' ' '; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

make -s >/dev/null 2>&1 || { echo "FAIL  libs: the build failed"; exit 1; }
./mkrelease.sh "$W" >/dev/null 2>&1 || { echo "FAIL  libs: mkrelease.sh failed"; exit 1; }
V=$(sed -n 's/^ *db *"\(.*\)".*/\1/p' src/version.inc)

check "hub's zip holds hub" "$(contents "$W/hub-$V.zip")" "mos/hub.bin "
check "the acc zip holds the library and headers" "$(contents "$W/hub-acc-$V.zip")" \
      "lib/acc/include/hub/VERSION lib/acc/include/hub/hub.h lib/acc/include/hub/hub.inc lib/acc/libhub.a "
check "the agondev zip holds them too" "$(contents "$W/hub-agondev-$V.zip")" \
      "include/hub/VERSION include/hub/hub.h include/hub/hub.inc lib/libhub.a "
want="$(git rev-parse HEAD)"
git diff --quiet HEAD || want="$want-dirty"
unzip -q "$W/hub-agondev-$V.zip" include/hub/VERSION -d "$W/v"
check "  and VERSION names the commit they were built from" \
      "$(sed -n 's/^commit //p' "$W/v/include/hub/VERSION")" "$want"

# agondev: its own directory, copied -- the tools linked, include and lib
# copied, so unzipping into it leaves the real one alone.
T="$W/agondev"
mkdir -p "$T"
ln -s "$AGONDEV/bin" "$AGONDEV/config" "$T/"
cp -r "$AGONDEV/include" "$AGONDEV/lib" "$T/"
unzip -q "$W/hub-agondev-$V.zip" -d "$T"
mkdir -p "$W/agclient/src"
cp test/c/src/main.c "$W/agclient/src/"
printf 'NAME=cclient\ninclude $(shell agondev-config --makefile)\nLIBS := -lhub\n' \
    > "$W/agclient/Makefile"
(cd "$W/agclient" && AGONDEV_TOOLCHAIN="$T" PATH="$AGONDEV/bin:$PATH" make >/dev/null 2>&1)
check "agondev, with the zip in its directory, builds the tested client" \
      "$(same "$W/agclient/bin/cclient.bin" build/test/cclient.bin)" same

# acc on the host, from the unzipped files.
unzip -q "$W/hub-acc-$V.zip" -d "$W/acc"
"$ACC" test/c/src/main.c -DCLIENT_ACC -I"$W/acc/lib/acc/include" "$W/acc/lib/acc/libhub.a" \
    -o "$W/cclienta.bin" >/dev/null 2>&1
check "acc, from the acc zip, builds the tested client" \
      "$(same "$W/cclienta.bin" build/test/cclienta.bin)" same

exit $status
