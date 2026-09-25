# chain

A resident shell for the Agon (MOS 3.0.2). It runs every command itself, so
it gets control back after each one: the basis for chaining programs ("run
this, then bring me back"), for state that outlives a program, and for
cleaning up after programs that leave hooks or files behind. The design is in
the "chain: a resident shell for the Agon" document.

This is the phase 0 spike: the prompt loop, the guards, and the two-part
layout.

- **The core** (`src/core.s`, ~430 bytes) runs from on-chip SRAM at
  `0xB7F300`, above 12AM Commander's launcher, where nothing MOS loads can
  reach it. It runs each line as `Try <line>` through `OSCLI` -- MOS's own
  prompt rules, expanded once -- then clears any keyboard hook, closes any
  files left open, prints MOS's message for a failure, and reloads the shell
  if a moslet loaded over it.
- **The shell** (`src/chain.s`) is a moslet at `0xB0000`: it installs the
  core, then reads lines for it -- from MOS's line editor with `CLI$Prompt`,
  or from a script with `chain -f <file>`. `exit` leaves chain.

## Build and test

    make          # build/chain.bin, assembled with a host build of zap
    make test     # the emulator checks, and the controls that show each
                  # check fails without the feature it covers

`ZAP_SRC` names zap's source tree (default `~/code/zap`); `AGON_EMU` the
emulator release (default `~/fab-agon-emulator-1.2.4`).

## Install

Copy `build/chain.bin` to `/mos/` on the card and type `chain`, or put
`chain` at the end of `autoexec.obey`.
