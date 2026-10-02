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
root of the SD card:

    /mos/hub.bin                  hub itself
    /lib/acc/libhub.a             the client library, for programs built with acc
    /lib/acc/include/hub/hub.h    its header

hub needs MOS 3.0.2. Showing a program's screen again after it ends (see
`hub_user_screen` below) needs VDP 2.2.0 or later; everything else works on
any VDP MOS 3.0.2 runs with.

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

A program asks hub for work while it runs; nothing happens until it returns.
A program that wants to run a command and then come back:

```c
#include <hub/hub.h>

int main(void)
{
    if (hub_present()) {
        struct state *s = hub_block("MYPG", sizeof *s);    /* survives the run */

        save_state(s);
        hub_enter("MYPG");                                 /* open a frame */
        hub_push("acc hello.c", HUB_STOP_ON_ERROR);        /* the command */
        hub_return_to("myprog -resume");                   /* then back here */

        return 0;                                          /* hub takes over */
    }
    /* ... and keep working without hub, where hub_present() is false */
}
```

When `myprog -resume` runs, `hub_last_result()` and `hub_failed_job()` say
how the commands went. The calls, in [`include/hub/hub.h`](include/hub/hub.h):

| Call | Does |
|---|---|
| `hub_present()` | true if hub is running; call it first |
| `hub_enter(tag)` | open a frame, named by a 4-character tag |
| `hub_push(cmd, flags)` | queue a command in it, as typed at the prompt |
| `hub_return_to(cmd)` | the frame's continuation: runs last, even after a failure |
| `hub_last_result()` | in the continuation: the result of the frame's last command |
| `hub_failed_job()` | in the continuation: which command stopped the frame, or -1 |
| `hub_block(tag, size)` | named memory that keeps its contents between runs |
| `hub_depth()` | how many frames are open |
| `hub_resumed()` | in the continuation: 1 if a reset cut the frame short |
| `hub_user_screen()` | the mode of the last user program's captured screen, or -1 |

Flags for `hub_push`:

| Flag | Does |
|---|---|
| `HUB_STOP_ON_ERROR` | a non-zero result skips the rest of the frame, up to its continuation |
| `HUB_USER_PROGRAM` | run it on the screen hub's prompt has -- mode, font, colours, cursor -- and put that back afterwards; capture what it leaves for `hub_user_screen` |
| `HUB_PAUSE_AFTER` | afterwards, "Press a key to return" |

A queue holds eight commands waiting to run, continuations included; a
command is at most 93 characters. Programs written with zap use
[`src/hub.inc`](src/hub.inc), which documents the same calls in assembly;
[`test/progs/client.s`](test/progs/client.s) uses all of them.

### Linking

On the Agon, with acc installed from its own release and hub's zip unzipped
over it, a program builds with nothing more than

    acc main.c /lib/acc/libhub.a

On a PC or Mac, `hub-libs-<version>.tar.gz`, also in the releases, has the
library for both compilers:

    include/hub/hub.h         the C API
    include/hub/hub.inc       the same for zap programs
    lib/agondev/libhub.a      for agondev
    lib/acc/libhub.a          for acc
    VERSION                   hub's version and the commit it was built from

With agondev, add three lines after the `include` of agondev's makefile,
which sets `CFLAGS` and `PROJECTLIBDIR` itself:

    include $(shell agondev-config --makefile)

    CFLAGS += -I<dir>/include
    PROJECTLIBDIR := <dir>/lib/agondev
    LIBS := -lhub

With acc on a PC or Mac: `acc main.c -I<dir>/include <dir>/lib/acc/libhub.a`.

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
| [`test/libs.sh`](test/libs.sh) | the library package, built against by agondev and acc |

The tools are found through `ZAP_SRC` (zap's source, default `~/code/zap`),
`AGONDEV` (default `~/agondev`), `AGON_EMU` (the emulator release, default
`~/fab-agon-emulator-1.2.4`), `ACC` (acc's host build, default
`~/code/acc/bin/acc`), and for the tests `ACC_BIN` (acc built for the Agon)
and `ACC_HOME` (acc's checkout, whose C library and headers go on the test
card).

## Releasing

    ./mkrelease.sh    # hub-<version>.zip and hub-libs-<version>.tar.gz

The version is written once, in [`src/version.inc`](src/version.inc).
