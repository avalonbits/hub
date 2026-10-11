#!/bin/bash
# Nested shells: a HUB_SHELL job opens hub's prompt, and `exit` there ends the
# job -- the frame's continuation runs then, never before. Driven through
# scripts under `hub -f` in the CLI emulator, as test/run.sh is (see there for
# how and why); in a script, the next lines are what the nested shell reads.
#
# test/progs/client.s: `client s` opens a frame whose job is a nested shell,
# with `client Z` -- "shell back: ..." -- as its continuation.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMU=${AGON_EMU:-$HOME/fab-agon-emulator-1.2.4}
MOS=$EMU/firmware/mos_platform.bin     # MOS 3.0.2

status=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; status=1; }
has() { grep -qF -- "$2" <<< "$1"; }
count() { grep -cF -- "$2" <<< "$1"; }
# line_of <text> <text to find>: the line number of its first appearance, or 0.
line_of() { grep -nF -m1 -- "$2" <<< "$1" | cut -d: -f1 || echo 0; }
before() { local a b; a=$(line_of "$1" "$2"); b=$(line_of "$1" "$3"); [ "${a:-0}" -gt 0 ] && [ "${b:-0}" -gt "$a" ]; }

# boot <seconds>: a card with hub and the test programs, the script from
# stdin, run under hub -f; print the console.
boot() {
    local sd fifo hold
    sd=$(mktemp -d)
    cp -r "$EMU/sdcard/mos" "$sd/"
    cp "$EMU/sdcard/MOS.bin" "$EMU/sdcard/firmware.bin" "$sd/"
    mkdir -p "$sd/bin"
    cp "$ROOT/build/hub.bin" "$sd/mos/"
    for p in client hello fail reset; do
        cp "$ROOT/build/test/$p.bin" "$sd/bin/"
    done
    tr '\n' '\r' | sed 's/\r/\r\n/g' > "$sd/script.txt"
    printf 'hub -f /script.txt\r\nemulator_exit_success\r\n' > "$sd/autoexec.txt"

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

# --- one shell, and what runs in it ------------------------------------------
out=$(boot 120 <<'SCRIPT'
client s
hello
client o
client f
client w
exit
Echo after-the-shell
SCRIPT
)

has "$out" "hub: exit goes back to SHEL" \
    && pass "a HUB_SHELL job opens a nested shell, which says where exit goes" \
    || fail "a HUB_SHELL job opens a nested shell, which says where exit goes"

has "$out" "SHEL hub> hello" \
    && pass "  lines read in it carry its tag" \
    || fail "  lines read in it carry its tag"

# The continuation waits for exit, past everything run in the shell.
if before "$out" "hello from a child" "shell back" \
   && before "$out" "SHEL hub> exit" "shell back" \
   && [ "$(count "$out" "shell back")" = 1 ] \
   && has "$out" "shell back: last 0, failed job 255"; then
    pass "the frame's continuation runs after exit, and only then"
else
    fail "the frame's continuation runs after exit, and only then"
fi

# A hub client run in the shell: its frames and continuation run, and the
# shell takes the next line -- the outer continuation doesn't.
if before "$out" "outer back" "SHEL hub> client f" \
   && before "$out" "inner back" "outer back"; then
    pass "a hub client in the shell runs its frames and comes back to the shell"
else
    fail "a hub client in the shell runs its frames and comes back to the shell"
fi

# A failure in the shell skips to its own frame's continuation -- with one
# (client f) or without (client w) -- and never into the held one.
if before "$out" "failed job 0, result 19" "shell back" \
   && before "$out" "SHEL hub> client w" "shell back" \
   && ! has "$out" "NOT-W" && ! has "$out" "SHOULD-NOT-RUN"; then
    pass "a failure in the shell never skips the jobs it holds"
else
    fail "a failure in the shell never skips the jobs it holds"
fi

if has "$out" "hub: back to SHEL" && before "$out" "shell back" "after-the-shell"; then
    pass "exit closes the shell, and hub carries on"
else
    fail "exit closes the shell, and hub carries on"
fi

# --- shells in shells, and the depth limit -----------------------------------
# Five nested shells, MAX_SHELLS. A sixth `client s` opens its frame, but its
# shell is refused, cleanly: its continuation runs at once with 100 and
# nothing is held. Inside them, `client P` pushes without opening a frame of
# its own: the frames below the shell are out of reach, so both calls are
# refused and nothing it pushed runs. Then five exits, each closing one.
out=$(boot 180 <<'SCRIPT'
client s
client s
client s
client s
client s
client s
client P
hello
exit
exit
exit
exit
exit
Echo all-closed
SCRIPT
)
if [ "$(count "$out" "hub: exit goes back to SHEL")" = 5 ] \
   && has "$out" "hub: shells nested too deep" \
   && [ "$(count "$out" "shell back: last 100, failed job 255")" = 1 ] \
   && [ "$(count "$out" "shell back: last 0, failed job 255")" = 5 ] \
   && before "$out" "hello from a child" "shell back: last 0" \
   && before "$out" "shell back: last 0" "all-closed"; then
    pass "shells nest five deep, a sixth is refused, and each exit closes one"
else
    fail "shells nest five deep, a sixth is refused, and each exit closes one"
fi
if [ "$(count "$out" "hub refused a call: 1")" = 2 ] && ! has "$out" "LEAKED"; then
    pass "a program in a shell can't push into the frames below it"
else
    fail "a program in a shell can't push into the frames below it"
fi

# Each exit lets go of its own shell's continuation, and no more: after the
# first exit, one "shell back" runs, before the second exit is read.
out=$(boot 120 <<'SCRIPT'
client s
client s
exit
Echo between
exit
SCRIPT
)
if [ "$(count "$out" "shell back")" = 2 ] \
   && before "$out" "shell back" "between" \
   && [ "$(sed -n '/between/,$p' <<< "$out" | grep -c 'shell back')" = 1 ]; then
    pass "an exit releases only its own shell's jobs"
else
    fail "an exit releases only its own shell's jobs"
fi

# --- a reset in the shell ----------------------------------------------------
# The machine is reset while the shell is open; hub, started again by
# autoexec.txt, resumes in the shell, with its jobs still held, and the
# script's exit lets them go.
out=$(boot 120 <<'SCRIPT'
client s
reset
exit
SCRIPT
)
if has "$out" "resumed after a reset" \
   && before "$out" "resumed after a reset" "shell back" \
   && [ "$(count "$out" "shell back")" = 1 ] \
   && has "$out" "shell back: last 0, failed job 255"; then
    pass "after a reset in the shell, hub resumes in it and exit still works"
else
    fail "after a reset in the shell, hub resumes in it and exit still works"
fi

exit $status
