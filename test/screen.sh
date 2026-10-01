#!/bin/bash
# The user screen, on a real VDP: the full emulator, with SDL's dummy video
# driver, runs the VDP's own firmware -- which the CLI emulator's stand-in
# does not -- so what hub captures can be drawn back and read.
#
# Under hub, in each mode, test/shot/src/main.c queues a user program that
# fills a red rectangle; its continuation clears the screen, reads a pixel
# inside the rectangle (black), draws HUB_SCREEN_BUFFER back and reads it
# again (red), and writes what it saw to /shot.txt. The control, a hub built
# with CAPTURE=0, must draw nothing back.
#
# The card is driven as test/run.sh drives it: a script in autoexec.txt,
# stdin held open with a fifo. The emulator is stopped once /shot.txt is
# written.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMU=${AGON_EMU:-$HOME/fab-agon-emulator-1.2.4}

status=0
check() {
    if [ "$2" = "$3" ]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1"
        echo "      got:  $2"
        echo "      want: $3"
        status=1
    fi
}

# shot <build dir> <mode> [<program's mode> [<font>]]: /shot.txt from a boot
# running the client at hub's prompt in <mode>, its user program switching
# to the second mode first if one is given. <font> "boot" makes an 8x16 font
# and selects it in autoexec.txt, before hub starts; "prompt" selects it at
# hub's prompt instead.
shot() {
    local sd fifo hold emu i
    sd=$(mktemp -d)
    mkdir -p "$sd/bin"
    cp -r "$EMU/sdcard/mos" "$sd/"
    cp "$EMU/sdcard/MOS.bin" "$EMU/sdcard/firmware.bin" "$sd/"
    cp "$1/hub.bin" "$sd/mos/"
    cp "$1/test/shot.bin" "$sd/bin/"
    local font=${4:-} select='VDU 23 0 149 0 100 0 0\r\n' boot='' prompt=''
    [ "$font" = boot ] && boot=$select
    [ "$font" = prompt ] && prompt=$select
    printf "${prompt}Set Hub\$NoPause 1\\r\\nshot p %s\\r\\n" "${3:-}" > "$sd/script.txt"
    printf "shot f\\r\\nVDU 22 %s\\r\\n${boot}hub -f /script.txt\\r\\n" "$2" \
        > "$sd/autoexec.txt"

    fifo=$(mktemp -u)
    mkfifo "$fifo"
    tail -f /dev/null > "$fifo" & hold=$!
    (cd "$EMU" && exec env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        SDL_AUDIO_DRIVER=dummy ./fab-agon-emulator -u --sdcard "$sd" \
        < "$fifo" > /dev/null 2>&1) & emu=$!
    for ((i = 0; i < 120; i++)); do
        [ -s "$sd/shot.txt" ] && break
        sleep 0.5
    done
    sleep 0.5                   # let the file be closed
    kill "$emu" "$hold" 2>/dev/null
    wait "$emu" "$hold" 2>/dev/null
    rm -f "$fifo"
    tr -d '\r' < "$sd/shot.txt" 2>/dev/null || echo "no /shot.txt"
    rm -rf "$sd"
}

make -s -C "$ROOT" >/dev/null 2>&1 || { echo "FAIL  build"; exit 1; }
for mode in 0 3 8; do
    check "mode $mode: the user screen is captured, and draws back" \
          "$(shot "$ROOT/build" "$mode")" \
          "user screen $mode, mode $mode, rows $((mode == 0 ? 60 : 30))/$((mode == 0 ? 60 : 30)), cleared 000000, back ff0000"
done

# A program that changes the mode and ends at once: the capture is in the
# program's mode, 8, and hub_user_screen says so; the continuation is back in
# the prompt's, 3.
check "a program that switches mode: the capture is in its mode" \
      "$(shot "$ROOT/build" 3 8)" \
      "user screen 8, mode 3, rows 30/30, cleared 000000, back ff0000"

# The prompt's font: an 8x16 one -- 15 rows in mode 3, where the system
# font has 30 -- selected in autoexec.txt before hub starts, or at hub's
# prompt. The user program starts in it, though hub's reset changes the
# mode, which drops the font; and after the pause hub puts it back for the
# continuation.
check "a font chosen before hub is the user program's and the continuation's" \
      "$(shot "$ROOT/build" 3 "" boot)" \
      "user screen 3, mode 3, rows 15/15, cleared 000000, back ff0000"
check "a font chosen at hub's prompt is too" \
      "$(shot "$ROOT/build" 3 "" prompt)" \
      "user screen 3, mode 3, rows 15/15, cleared 000000, back ff0000"

make -s -C "$ROOT" B=build/nocapture CAPTURE=0 >/dev/null 2>&1 \
    || { echo "FAIL  build"; exit 1; }
check "control: without capture, nothing draws back" \
      "$(shot "$ROOT/build/nocapture" 3)" \
      "user screen -1, mode 3, rows 30/30, cleared 000000, back 000000"

make -s -C "$ROOT" B=build/nofont PROMPTFONT=0 >/dev/null 2>&1 \
    || { echo "FAIL  build"; exit 1; }
check "control: without following the font, the user program gets the system font" \
      "$(shot "$ROOT/build/nofont" 3 "" boot)" \
      "user screen 3, mode 3, rows 30/30, cleared 000000, back ff0000"

# A hub that advertises the 8 entries of 0.3 has no hub_user_screen: the C
# library says -1 rather than call past the table, though this build has the
# entry and captured the screen.
make -s -C "$ROOT" B=build/oldapi API_COUNT=8 >/dev/null 2>&1 \
    || { echo "FAIL  build"; exit 1; }
check "under a hub older than 0.4, hub_user_screen() is -1" \
      "$(shot "$ROOT/build/oldapi" 3)" \
      "user screen -1, mode 3, rows 30/30, cleared 000000, back ff0000"

exit $status
