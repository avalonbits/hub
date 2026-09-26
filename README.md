# hub

A resident shell for the Agon (MOS 3.0.2). It runs every command itself, so
it gets control back after each one: the basis for chaining programs ("run
this, then bring me back"), for state that outlives a program, and for
cleaning up after programs that leave hooks or files behind. The design is in
the "hub: a resident shell for the Agon" document.

Phase 1 adds the scheduler and the client API to the phase 0 shell.

- **The core** (`src/core.s`, ~1.4 KB) runs from on-chip SRAM at
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
  outlives a program.
- **The API** is a header and jump table in the core, found through the
  Number variable `Hub$API`. `src/hub.inc` documents every call for zap
  programs, with `test/progs/client.s` as a worked example. C programs
  built with agondev use `include/hub.h` and link `libhub.a`
  (`lib/hub_glue.s`, assembled by zap); `test/c/src/main.c` is the example.
- **The shell** (`src/hub.s`) is a moslet at `0xB0000`: it installs the
  core, then reads lines for it -- from MOS's line editor with `CLI$Prompt`,
  or from a script with `hub -f <file>`. `exit` leaves hub.

## Build and test

    make          # build/hub.bin, assembled with a host build of zap
    make test     # the emulator checks, and the controls that show each
                  # check fails without the feature it covers

`ZAP_SRC` names zap's source tree (default `~/code/zap`); `AGONDEV` the
agondev install used for the C client and `libhub.a` (default `~/agondev`);
`AGON_EMU` the emulator release (default `~/fab-agon-emulator-1.2.4`).

## Install

Copy `build/hub.bin` to `/mos/` on the card and type `hub`, or put
`hub` at the end of `autoexec.obey`.
