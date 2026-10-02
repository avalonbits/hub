#!/bin/bash
# The examples in examples/, run as a user would run them: under hub in the
# CLI emulator, driven by a script on the card (see test/run.sh for how and
# why). And built by acc as well as agondev, as docs/API.md says they can be.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMU=${AGON_EMU:-$HOME/fab-agon-emulator-1.2.4}
MOS=$EMU/firmware/mos_platform.bin     # MOS 3.0.2
ACC=${ACC:-$HOME/code/acc/bin/acc}

status=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; status=1; }
has() { grep -qF -- "$2" <<< "$1"; }

# boot <seconds> <autoexec>: a card with hub, the examples and hub's test
# programs hello and fail; print the console.
boot() {
    local sd fifo hold
    sd=$(mktemp -d)
    cp -r "$EMU/sdcard/mos" "$sd/"
    cp "$EMU/sdcard/MOS.bin" "$EMU/sdcard/firmware.bin" "$sd/"
    mkdir -p "$sd/bin"
    cp "$ROOT/build/hub.bin" "$sd/mos/"
    cp "$ROOT"/examples/bin/*.bin "$ROOT/build/test/hello.bin" "$ROOT/build/test/fail.bin" "$sd/bin/"
    cat > "$sd/script.txt"
    printf "$2" > "$sd/autoexec.txt"

    fifo=$(mktemp -u)
    mkfifo "$fifo"
    tail -f /dev/null > "$fifo" & hold=$!
    (cd "$EMU" && timeout "$1" ./agon-cli-emulator -u --sdcard "$sd" --mos "$MOS" \
        < "$fifo" 2>&1) | tr -d '\r'
    kill "$hold" 2>/dev/null
    wait "$hold" 2>/dev/null
    rm -rf "$sd" "$fifo"
}

make -s -C "$ROOT" >/dev/null 2>&1 || { echo "FAIL  build"; exit 1; }

# After the script, hub has gone and the examples run at MOS's prompt; seq,
# failing there, runs through Try so that autoexec.txt carries on.
out=$(boot 120 'hub -f /script.txt\r\nhubinfo\r\nTry seq hello\r\nEcho seq-gave <Try$ReturnCode>\r\nemulator_exit_success\r\n' <<'SCRIPT'
hubinfo
seq hello ; hello
seq hello ; fail ; hello
rep 3 hello
rep 2 fail
seq rep 2 hello ; hubinfo
SCRIPT
)

has "$out" "hub API 0.4, 9 calls, 0 frames open" \
    && pass "hubinfo finds hub from assembly and calls it" \
    || fail "hubinfo finds hub from assembly and calls it"

seq_ok=$(sed -n '/^hub> seq hello ; hello$/,/^hub> /p' <<< "$out")
if [ "$(grep -c 'hello from a child' <<< "$seq_ok")" = 2 ] \
   && has "$seq_ok" "seq: 2 commands done"; then
    pass "seq runs its commands and says they all worked"
else
    fail "seq runs its commands and says they all worked"
fi

seq_bad=$(sed -n '/^hub> seq hello ; fail ; hello$/,/^hub> /p' <<< "$out")
if [ "$(grep -c 'hello from a child' <<< "$seq_bad")" = 1 ] \
   && has "$seq_bad" "seq: command 2 (fail) failed with 19"; then
    pass "seq stops at the command that fails, and names it"
else
    fail "seq stops at the command that fails, and names it"
fi

rep_ok=$(sed -n '/^hub> rep 3 hello$/,/^hub> /p' <<< "$out")
if [ "$(grep -c 'hello from a child' <<< "$rep_ok")" = 3 ] \
   && has "$rep_ok" "rep: 3 runs, 0 failed"; then
    pass "rep runs a command as often as asked, chaining to itself"
else
    fail "rep runs a command as often as asked, chaining to itself"
fi

has "$out" "rep: 2 runs, 2 failed" \
    && pass "rep counts the runs that failed" \
    || fail "rep counts the runs that failed"

# rep, run by seq, opens its frames inside seq's; hubinfo, seq's second
# command, runs with seq's frame still open; and seq comes back at the end.
nest=$(sed -n '/^hub> seq rep 2 hello ; hubinfo$/,/^hub> /p' <<< "$out")
if has "$nest" "rep: 2 runs, 0 failed" && has "$nest" "9 calls, 1 frames open" \
   && has "$nest" "seq: 2 commands done"; then
    pass "seq and rep nest: rep's frames run inside seq's"
else
    fail "seq and rep nest: rep's frames run inside seq's"
fi

# After the script, hub has gone. seq fails with 100, which MOS passes back
# as it is -- not 1, which MOS turns into its own "Invalid command".
if has "$out" "hub is not running" && has "$out" "seq: needs hub" \
   && has "$out" "seq-gave 100"; then
    pass "without hub, the examples say so"
else
    fail "without hub, the examples say so"
fi

# see waits for a key once the program has run, so this boot ends at its
# timeout: by then see has offered to show the screen hub captured.
out=$(boot 20 'hub -f /script.txt\r\n' <<'SCRIPT'
Set Hub$NoPause 1
see fail
SCRIPT
)
if has "$out" "Press a key to return" && has "$out" "see: the program returned 19" \
   && has "$out" "see: Space shows its screen"; then
    pass "see runs a user program, pauses, and offers its captured screen"
else
    fail "see runs a user program, pauses, and offers its captured screen"
fi

# acc builds the C examples too, from the same source.
if [ -x "$ACC" ]; then
    W=$(mktemp -d)
    ok=1
    for ex in seq rep see; do
        "$ACC" "$ROOT/examples/src/$ex.c" -I"$ROOT/include" "$ROOT/build/lib/acc/libhub.a" \
            -o "$W/$ex.bin" > /dev/null 2>&1 || ok=0
    done
    rm -rf "$W"
    [ $ok = 1 ] && pass "acc builds the C examples" || fail "acc builds the C examples"
else
    echo "SKIP  acc: no host build at $ACC"
fi

exit $status
