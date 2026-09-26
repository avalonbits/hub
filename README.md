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
  outlives a program.
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
`hub` at the end of `autoexec.obey` -- which is also what lets hub resume
after a reset.

## MOS 3.0.2 bugs worked around

- `mos_setvarval` (API `0x30`) overwrites the variable that sorts just before
  a new name instead of creating it. hub creates `Hub$API` with `SetEval`.
- `mos_readvarval` (API `0x31`) answers for that same neighbour when the
  variable asked for doesn't exist, with status 0. hub, `hub.inc`'s example
  and `hub.h` check the name it returns in IY.

Both come from `getSystemVariable` returning a positive number for "not
found" while its callers only test for -1 (`mos_sysvars.c`).
