# hub

A resident shell for the Agon (MOS 3.0.2). It runs every command itself, so
it gets control back after each one: the basis for chaining programs ("run
this, then bring me back"), for state that outlives a program, and for
cleaning up after programs that leave hooks or files behind. The design is in
the "hub: a resident shell for the Agon" document.

Phase 2 adds repair and recovery to the phase 1 scheduler.

- **The core** (`src/core.s`, ~1.7 KB) runs from on-chip SRAM at
  `0xB7F300`, above 12AM Commander's launcher, where nothing MOS loads can
  reach it. It runs each line as `Try <line>` through `OSCLI` -- MOS's own
  prompt rules, expanded once -- and after every command clears any keyboard
  hook, closes files left open, restores interrupt handlers, prints MOS's
  message for a failure, and reloads the shell if a moslet loaded over it.
- **The scheduler.** Programs queue jobs through the API while they run:
  `hub_enter` opens a frame, `hub_push` queues commands in it, and
  `hub_return_to` sets the continuation that brings the program back.
  Frames nest; a failed stop-on-error job skips to its frame's continuation,
  which can ask what happened. `hub_block` hands out named memory that
  outlives a program. A job pushed with `HUB_USER_PROGRAM` starts on the
  screen hub's prompt had -- its mode, colours, font and cursor -- whatever
  the program that queued it did to it; one with `HUB_PAUSE_AFTER` ends
  with "Press a key to return" (set `Hub$NoPause` to print it without
  waiting, as tests do). The queue holds eight jobs waiting to run; the one
  running doesn't take a slot.
- **The user screen.** After a `HUB_USER_PROGRAM` job, and before its
  pause, hub captures the screen the program left into the VDP buffer
  `HUB_SCREEN_BUFFER` (`VDU 23,27,&21`, VDP 2.2.0 and later), so the
  program that queued it can show it again -- Turbo Pascal's Alt-F5.
  `hub_user_screen()` gives the mode it was captured in, or -1. VDP
  buffers `0x4800`-`0x48FF` are hub's.
- **Repair and recovery.** A moslet loads over the shell and, if it is big
  enough (nano is 6.5 KB), over the client blocks. The core saves the blocks
  to `hub.blk` next to `hub.bin` whenever they change, and after a moslet
  reloads the shell and restores the blocks; `hub_block` repairs first too,
  for programs that run moslets themselves. After a warm reset
  (Ctrl-Alt-Del), running `hub` again -- from `autoexec.obey`, or with F12,
  which hub binds -- resumes: the queue and a script's position survive in
  on-chip SRAM and the blocks in RAM, and the job the reset cut short counts as failed,
  so its frame's continuation runs and can ask `hub_resumed`. A second `hub`
  started while one is running refuses.
- **The API** is a header and jump table in the core, found through the
  Number variable `Hub$API`. `src/hub.inc` documents every call for zap
  programs, with `test/progs/client.s` as a worked example. C programs
  include `<hub/hub.h>` and link `libhub.a` (`lib/hub_glue.s`, assembled
  by zap as an ELF archive for agondev and an ACC one for acc);
  `test/c/src/main.c` is the example.
- **The shell** (`src/hub.s`) is a moslet at `0xB0000`: it installs the
  core, then reads lines for it -- from MOS's line editor with `CLI$Prompt`,
  or from a script with `hub -f <file>`. `exit` leaves hub.

## Build and test

    make          # build/hub.bin, assembled with a host build of zap
    make test     # the emulator checks, the controls that show each
                  # check fails without the feature it covers, the user
                  # screen on the full emulator's real VDP (test/screen.sh,
                  # with SDL's dummy video), and the library package
                  # (test/libs.sh)

`ZAP_SRC` names zap's source tree (default `~/code/zap`); `AGONDEV` the
agondev install used for the C client and `libhub.a` (default `~/agondev`);
`AGON_EMU` the emulator release (default `~/fab-agon-emulator-1.2.4`);
`ACC` acc's host build (default `~/code/acc/bin/acc`), and for the tests
`ACC_BIN`, its Agon build, and `ACC_HOME`, its checkout, whose C library
and headers go on the test card.

## Install

Unzip `hub-<version>.zip` at the root of the SD card:

    /mos/hub.bin                  hub itself
    /lib/acc/libhub.a             the client library, for acc on the Agon
    /lib/acc/include/hub/hub.h    its header

Type `hub`, or put `hub` at the end of `autoexec.obey` -- which is also what
lets hub resume after a reset. `exit` leaves it; F12 brings it back.

## Writing programs for hub

A C program includes `<hub/hub.h>` and links `libhub.a`. On the Agon, with
acc installed from its own release, that is all it takes -- acc searches
`/lib/acc/include` for every `#include`:

    acc main.c /lib/acc/libhub.a

On a PC or Mac, `hub-libs-<version>.tar.gz` has the library for both
compilers:

    include/hub/hub.h         the C API
    include/hub/hub.inc       the same for zap programs
    lib/agondev/libhub.a      for agondev
    lib/acc/libhub.a          for acc
    VERSION                   hub's version and the commit it was built from

With agondev, the three lines go after the `include` of agondev's makefile,
which sets `CFLAGS` and `PROJECTLIBDIR` itself:

    include $(shell agondev-config --makefile)

    CFLAGS += -I<dir>/include
    PROJECTLIBDIR := <dir>/lib/agondev
    LIBS := -lhub

With acc: `acc main.c -I<dir>/include <dir>/lib/acc/libhub.a`.

A program must work without hub too: `hub_present()` is false then, and
every other call fails harmlessly.

## Releasing

    ./mkrelease.sh    # hub-<version>.zip and hub-libs-<version>.tar.gz

The version is written once, in `src/version.inc`; hub prints it when it
starts.

## MOS 3.0.2 bugs worked around

- `mos_setvarval` (API `0x30`) overwrites the variable that sorts just before
  a new name instead of creating it. hub creates `Hub$API` with `SetEval`.
- `mos_readvarval` (API `0x31`) answers for that same neighbour when the
  variable asked for doesn't exist, with status 0. hub, `hub.inc`'s example
  and `hub.h` check the name it returns in IY.

Both come from `getSystemVariable` returning a positive number for "not
found" while its callers only test for -1 (`mos_sysvars.c`).
