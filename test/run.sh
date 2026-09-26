#!/bin/bash
# Phase 0: hub in the emulator, driven through a script on the card.
#
#   test/run.sh             the spike's checks, and the controls that show
#                           each check fails without the feature it covers
#
# The emulator is driven the way zap's and acc's harnesses drive it: a release
# build run from its own directory, a card seeded with MOS's own files, the
# command in autoexec.txt (never typed into stdin), stdin held open with a
# fifo, and both output streams captured. The script's last line runs
# emulator_exit_success, which stops the emulator when hub gets that far.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMU=${AGON_EMU:-$HOME/fab-agon-emulator-1.2.4}
MOS=$EMU/firmware/mos_platform.bin     # MOS 3.0.2
ROUNDS=${ROUNDS:-100}

status=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; status=1; }

# card <build dir>: a fresh card with MOS's files, hub and the programs.
card() {
    local sd
    sd=$(mktemp -d)
    cp -r "$EMU/sdcard/mos" "$sd/"
    cp "$EMU/sdcard/MOS.bin" "$EMU/sdcard/firmware.bin" "$sd/"
    mkdir -p "$sd/bin"
    cp "$1/hub.bin" "$sd/mos/"
    cp "$1/test/stomp.bin" "$sd/mos/"
    for p in hello fail kbhook kbprobe leak fprobe vechook vecprobe client cclient; do
        cp "$1/test/$p.bin" "$sd/bin/"
    done

    {
        echo "# phase 0 spike"
        echo "hello"
        echo "fail"
        echo "kbhook"
        echo "kbprobe"
        echo "leak"
        echo "fprobe"
        echo "stomp"
        echo "hello"
        echo "Echo |<once> from Echo"
        for ((i = 0; i < ROUNDS; i++)); do echo "hello"; done
        echo "Echo rounds done"
        echo "vechook"
        echo "vecprobe"
        echo "client c"
        echo "client o"
        echo "client f"
        echo "cclient"
    } > "$sd/script.txt"

    # The script ends by running out of lines, which leaves hub; the lines
    # after it run at MOS's own prompt, with hub gone.
    printf 'hub -f /script.txt\r\nclient c\r\ncclient\r\nemulator_exit_success\r\n' \
        > "$sd/autoexec.txt"

    echo "$sd"
}

# run <card> <timeout>: boot it and print the console.
run() {
    local sd=$1 limit=$2 fifo cap hold

    fifo=$(mktemp -u); cap=$(mktemp)
    mkfifo "$fifo"
    tail -f /dev/null > "$fifo" & hold=$!
    (cd "$EMU" && timeout "$limit" ./agon-cli-emulator -u --sdcard "$sd" \
        --mos "$MOS" < "$fifo" > "$cap" 2>&1)
    kill "$hold" 2>/dev/null; wait "$hold" 2>/dev/null
    rm -f "$fifo"
    tr -d '\r' < "$cap"; rm -f "$cap"
}

has() { grep -qF -- "$2" <<< "$1"; }
count() { grep -cF -- "$2" <<< "$1"; }

# --- hub as built --------------------------------------------------------

make -s -C "$ROOT" >/dev/null || { echo "FAIL  build"; exit 1; }
sd=$(card "$ROOT/build")
out=$(run "$sd" 300)
rm -rf "$sd"

has "$out" "hub 0.1" && pass "hub starts" || fail "hub starts"

want=$((ROUNDS + 2))
got=$(count "$out" "hello from a child")
[ "$got" -eq "$want" ] && pass "every child ran and returned ($got)" \
    || fail "children that returned: got $got, want $want"

has "$out" "Invalid parameter" && pass "a failing command gets MOS's message" \
    || fail "a failing command gets MOS's message"

has "$out" "kbvector: clear" && pass "a leftover keyboard hook is cleared" \
    || fail "a leftover keyboard hook is cleared"

has "$out" "free handles: 8" && pass "leaked files are closed" \
    || fail "leaked files are closed"

has "$out" "hub: shell reloaded" && pass "a moslet over the shell is repaired" \
    || fail "a moslet over the shell is repaired"

# GSTrans turns |< into <. Expanded a second time, <once> would become the
# (empty) value of a variable called "once".
grep -qx '<once> from Echo' <<< "$out" && pass "a line is expanded once, as at MOS's prompt" \
    || fail "a line is expanded once, as at MOS's prompt"

has "$out" "rounds done" && pass "reached the end of the script" \
    || fail "reached the end of the script"

has "$out" "vector: mos" && pass "a leftover interrupt handler is replaced" \
    || fail "a leftover interrupt handler is replaced"

# --- the scheduler ------------------------------------------------------------

counts=$(grep -cE '^count [0-9]+$' <<< "$out")
if [ "$counts" -eq 50 ] && has "$out" "count 50" && has "$out" "count done"; then
    pass "a client chained to itself 50 times, keeping its count in a block"
else
    fail "a client chained to itself 50 times ($counts runs)"
fi

# Nesting: the inner frame's work, continuation included, comes before the
# rest of the outer frame, and the outer continuation comes last.
order=$(grep -xE 'outer|inner|inner-job|inner back|outer-second|outer back' <<< "$out" \
    | tr '\n' ',')
[ "$order" = "outer,inner,inner-job,inner back,outer-second,outer back," ] \
    && pass "nested frames run in order" \
    || fail "nested frames run in order: $order"

if has "$out" "failed job 0, result 19" && ! has "$out" "SHOULD-NOT-RUN"; then
    pass "a failed stop-on-error job skips to the continuation, which sees why"
else
    fail "a failed stop-on-error job skips to the continuation, which sees why"
fi

# The C client, through include/hub.h and lib/hub_glue.s: its third run's
# frame fails on purpose, and the fourth run, that frame's continuation, sees
# which job and why.
if has "$out" "cclient 1: last 0, failed -1, depth 0" \
   && has "$out" "cclient 4: last 19, failed 0, depth 0" \
   && has "$out" "cclient 5: last 0, failed -1, depth 0" \
   && has "$out" "cclient done" && ! has "$out" "cclient-not-run"; then
    pass "a C client chains through hub.h, and sees a failed frame"
else
    fail "a C client chains through hub.h, and sees a failed frame"
fi

! has "$out" "a long command was accepted" \
    && pass "hub_push refuses a command longer than HUB_CMD_MAX" \
    || fail "hub_push refuses a command longer than HUB_CMD_MAX"

! has "$out" "hub refused a call" && pass "no API call was refused" \
    || fail "no API call was refused"

# After the script, hub has gone: the same client finds no API.
tail_out=$(sed -n '/^outer back$/,$p' <<< "$out")
has "$tail_out" "no hub" && pass "leaving hub withdraws Hub\$API" \
    || fail "leaving hub withdraws Hub\$API"
has "$tail_out" "cclient: no hub" && pass "hub_present() is false without hub" \
    || fail "hub_present() is false without hub"

# --- controls: each check above must fail without its feature ---------------

make -s -C "$ROOT" B=build/noguards GUARDS=0 >/dev/null || { echo "FAIL  build"; exit 1; }
sd=$(card "$ROOT/build/noguards")
out=$(run "$sd" 300)
rm -rf "$sd"

has "$out" "kbvector: SET" && pass "control: without guards the hook stays" \
    || fail "control: without guards the hook stays"
has "$out" "free handles: 5" && pass "control: without guards the files leak" \
    || fail "control: without guards the files leak"
has "$out" "vector: user" && pass "control: without guards the handler stays" \
    || fail "control: without guards the handler stays"

make -s -C "$ROOT" B=build/norepair REPAIR=0 >/dev/null || { echo "FAIL  build"; exit 1; }
sd=$(card "$ROOT/build/norepair")
out=$(run "$sd" 30)
rm -rf "$sd"

if has "$out" "stomp: a moslet ran" && ! has "$out" "rounds done"; then
    pass "control: without repair hub is lost after a moslet"
else
    fail "control: without repair hub is lost after a moslet"
fi

exit $status
