# hub

hub is a resident shell for the Agon Light and Console8, running MOS 3.0.2.
You use it like MOS's own prompt, but hub stays in memory under every program
you run. That lets programs ask it to run other programs and bring them back
afterwards -- an IDE that runs the compiler and then returns to the editor, a
file manager that opens an editor and comes back -- and it cleans up after
every program, whether that program used hub or not.

## Install

Download `hub-<version>.zip` from the
[releases](https://github.com/avalonbits/hub/releases) and unzip it at the
root of the SD card. That puts hub in `/mos/hub.bin`.

hub needs MOS 3.0.2. Showing a program's screen again after it ends (see
`hub_user_screen` in the API) needs VDP 2.2.0 or later; everything else works
on any VDP MOS 3.0.2 runs with.

## Using hub

Type `hub` at the MOS prompt. hub prints its version and gives you a prompt
that behaves like MOS's: the same `CLI$Prompt`, line editing and tab
completion, and every line runs as it would at MOS's prompt -- built-in
commands, moslets from `/mos`, programs from `/bin`, `.bin` files by path.

To start hub every time the machine boots, make `hub` the last line of
`/autoexec.txt`.

    exit            leave hub, back to MOS's prompt
    F12             start hub again from MOS's prompt (hub binds it, unless
                    you have bound F12 yourself)
    hub -f <file>   run the lines of a file, then leave hub; blank lines and
                    lines starting with # are skipped

What hub does for you, after every command:

- **Cleans up.** A program that leaves a keyboard hook, files open or its own
  interrupt handlers behind would otherwise crash the machine later. hub
  clears the hook, closes the files and puts the handlers back.
- **Reports failures** with MOS's own message, as MOS's prompt does.
- **Survives moslets.** A moslet loads where hub's prompt lives; hub notices
  and reloads it.
- **Survives a reset.** After Ctrl-Alt-Del, starting hub again -- from
  `autoexec.txt` or with F12 -- picks up the work programs had queued. The
  program the reset interrupted counts as failed, and the program that
  queued it is told so.

A second `hub` started while hub is running says so and does nothing.

### Programs that use hub

- **ade**, the Agon development environment built on aed: builds with acc
  and zap, runs the program, and comes back to the editor with the errors.
- **12AM Commander** (`mc`), Lennart Benschop's file manager, in a fork that
  runs programs through hub:
  [avalonbits/agon-utilities](https://github.com/avalonbits/agon-utilities/tree/hub),
  branch `hub`.

## Writing programs for hub

A program asks hub for work while it runs -- run these commands, then start
me again -- and keeps what it needs in memory hub holds for it. Nothing
happens until the program returns. A program that runs two commands and
comes back:

```c
#include <hub/hub.h>

    if (hub_present()) {
        hub_enter("BLD ");                                 /* open a frame */
        hub_push("acc -c main.c", HUB_STOP_ON_ERROR);      /* the commands */
        hub_push("acc main.o -o prog.bin", HUB_STOP_ON_ERROR);
        hub_return_to("build -r");                         /* then back here */
        return 0;                                          /* hub takes over */
    }
```

[`docs/API.md`](docs/API.md) describes every call, the patterns they make,
and how to change an existing program to use hub.

Each release has the library for both of the Agon's C compilers:

| Zip | For | Unzip |
|---|---|---|
| `hub-acc-<version>.zip` | acc, on the Agon or a PC or Mac | at the SD card's root, over acc's `/lib/acc`; a program builds with `acc main.c /lib/acc/libhub.a` |
| `hub-agondev-<version>.zip` | agondev | in agondev's directory (`agondev-config --prefix`); a program's Makefile adds `LIBS := -lhub` |

Both have `hub.h`, and `hub.inc` for programs written with zap.

### Examples

[`examples/`](examples) has small programs that use hub, each useful as it
is, with their source in `examples/src` and built in `examples/bin` -- copy
those to `/bin` on the card:

| Program | Does |
|---|---|
| `seq <cmd> ; <cmd> ...` | runs commands one after another, stopping at the first that fails, and says which |
| `rep <n> <cmd>` | runs a command n times and counts the failures |
| `see <cmd>` | runs a program, pauses, and lets you see its screen again |
| `hubinfo` | says whether hub is running, its API version and how many frames are open (assembly) |

## How it works

[`docs/DESIGN.md`](docs/DESIGN.md) explains hub's parts, where each lives in
memory, how it runs a command and a queue of them, and why.

## Building and testing

hub is assembled with [zap](https://github.com/avalonbits/zap), built for the
host from its source. The tests run on
[fab-agon-emulator](https://github.com/tomm/fab-agon-emulator).

    make            # build/hub.bin and the test programs
    make test       # everything below

| Test | Checks |
|---|---|
| [`test/run.sh`](test/run.sh) | hub in the CLI emulator, through scripts on the card; and, for each safeguard, a build without it that shows the check fails |
| [`test/screen.sh`](test/screen.sh) | the screen and font a user program gets, and its captured screen, on the full emulator's real VDP (SDL's dummy video driver) |
| [`test/examples.sh`](test/examples.sh) | the examples, under hub and without it, and built by acc too |
| [`test/libs.sh`](test/libs.sh) | the release's zips, as a developer uses each with agondev or acc |

The tools are found through `ZAP_SRC` (zap's source, default `~/code/zap`),
`AGONDEV` (default `~/agondev`), `AGON_EMU` (the emulator release, default
`~/fab-agon-emulator-1.2.4`), `ACC` (acc's host build, default
`~/code/acc/bin/acc`), and for the tests `ACC_BIN` (acc built for the Agon)
and `ACC_HOME` (acc's checkout, whose C library and headers go on the test
card).

## Releasing

    ./mkrelease.sh    # hub-<version>.zip, hub-acc-<version>.zip
                      # and hub-agondev-<version>.zip

The version is written once, in [`src/version.inc`](src/version.inc).

## License

hub is free software under the MIT License; see [LICENSE](LICENSE).
