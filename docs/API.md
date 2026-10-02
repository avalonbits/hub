# The hub API

This is for people writing programs that use hub: what a program can ask of
it, how, and how to change an existing program to use it. How hub does it is
in [DESIGN.md](DESIGN.md).

## The idea

The Agon runs one program at a time, so a program can't run another program
and carry on afterwards: the other program loads over it. With hub, a
program instead asks hub for work while it runs:

1. it saves what it needs to remember in a **block**, memory hub keeps;
2. it opens a **frame**, queues **jobs** in it -- commands, as typed at the
   prompt -- and sets the frame's **continuation**, usually the command that
   starts the program again;
3. it returns.

hub then runs the jobs, then the continuation. The program, started again,
takes its state back from the block and asks hub how the jobs went.

Nothing happens until the program returns: the calls only record what to do.

A program must keep working without hub. On a machine without it,
`hub_present()` is false and the program carries on as it would have before
hub existed.

## Getting the library

Each hub release has a zip for each compiler:

- **acc on the Agon.** Unzip `hub-acc-<version>.zip` at the root of the SD
  card, where acc's own release put `/lib/acc`. acc finds `<hub/hub.h>` by
  itself, and a program links with

      acc main.c /lib/acc/libhub.a

- **acc on a PC or Mac.** Unzip the same file anywhere, and

      acc main.c -I<dir>/lib/acc/include <dir>/lib/acc/libhub.a

- **agondev.** Unzip `hub-agondev-<version>.zip` in agondev's own directory
  (`agondev-config --prefix`). Every agondev project searches it, so a
  program's Makefile needs only

      include $(shell agondev-config --makefile)
      LIBS := -lhub

Both zips have `hub.inc` next to `hub.h`, for programs written with zap,
and a `VERSION` file naming hub's version and the commit it was built from.
The library is one small file of glue,
[`lib/hub_glue.s`](../lib/hub_glue.s), assembled for each compiler from the
same source.

## A first program

```c
#include <stdio.h>
#include <hub/hub.h>

int main(int argc, char **argv)
{
    if (!hub_present()) {
        printf("needs hub\r\n");
        return 100;
    }
    if (argc > 1 && argv[1][0] == '-') {        /* "build -r": we're back */
        if (hub_failed_job() < 0)
            printf("built\r\n");
        else
            printf("failed: %d\r\n", hub_last_result());
        return 0;
    }
    hub_enter("BLD ");
    hub_push("acc -c main.c", HUB_STOP_ON_ERROR);
    hub_push("acc main.o -o prog.bin", HUB_STOP_ON_ERROR);
    hub_return_to("build -r");
    return 0;                                   /* now hub runs them */
}
```

Run as `build`, it queues two commands and returns. hub compiles, links, and
runs `build -r`, which says how it went. If the compile fails, the link is
skipped and `build -r` runs anyway.

## The calls

Every call but `hub_present` fails harmlessly until `hub_present` has found
hub: those returning a status return `HUB_ERR_ABSENT`, the others 0, -1 or
`NULL` as described.

### `bool hub_present(void)`

True if hub is running and offers an API this header understands. Call it
first; it is what the other calls rely on.

### `int hub_enter(const char tag[4])`

Open a frame for the jobs pushed next. The tag names the program, four
characters, space-padded (`"BLD "`); hub keeps it with the frame. Frames
nest, six deep: a job that is itself a hub client opens a frame inside its
caller's.

Returns `HUB_OK`, or `HUB_ERR_DEPTH` when frames are nested too deep.

### `int hub_push(const char *cmd, unsigned char flags)`

Queue a command in the open frame, after anything already pushed. The
command runs as if typed at MOS's prompt: built-in commands, moslets from
`/mos`, programs from `/bin`, `.bin` files by path, with variables expanded
once. At most `HUB_CMD_MAX` (93) characters.

Returns `HUB_OK`, `HUB_ERR_NO_FRAME` without a `hub_enter`,
`HUB_ERR_FULL` when eight jobs are already waiting, or `HUB_ERR_TOO_LONG`.

The flags:

- **`HUB_STOP_ON_ERROR`** -- if the command returns non-zero, skip the rest
  of the frame's jobs, and any frames nested in them, up to the
  continuation.
- **`HUB_USER_PROGRAM`** -- the command is a program for the user to see,
  queued by a program that owns the screen. hub runs it on the screen its
  prompt has: the prompt's mode (which clears it), colours, viewports, font,
  the cursor on and its behaviour reset. Afterwards hub captures the screen
  it left (see `hub_user_screen`) and, after any pause, puts the prompt's
  screen back, so the continuation starts as it would from the prompt. hub
  learns the prompt's font from `/autoexec.txt` and from the lines run at its
  prompt (`fontctl <id>`, `VDU 23,0,149,0,<id>`), since the VDP can't be
  asked.
- **`HUB_PAUSE_AFTER`** -- after the command, whether it worked or not,
  "Press a key to return", and wait for a key. With the variable
  `Hub$NoPause` set (`Set Hub$NoPause 1`), hub prints the message and doesn't
  wait: scripted tests set it.

### `int hub_return_to(const char *cmd)`

Set the frame's continuation: a command that runs after the frame's jobs,
even when one of them failed. Usually the command that starts the program
again, with an argument that tells it it is being brought back. Push it
after the frame's jobs. It takes a queue slot like a job.

Returns as `hub_push`.

### `int hub_last_result(void)` and `int hub_failed_job(void)`

In a continuation: the result of the last job its frame ran, and the index,
from 0 in push order, of the job that stopped the frame -- or -1 if none
did. Anywhere else, 0 and -1: a program started afresh can't mistake an
earlier frame's results for its own.

So in a continuation, `hub_failed_job() >= 0` means a stop-on-error job
failed, and the jobs after it didn't run; otherwise every job ran, and
`hub_last_result()` is the last one's result.

Two things about results come from MOS:

- MOS reports a program's 1, 4 or 5 as its own error 20, "Invalid command",
  so that is the result hub sees too. A program that fails should return
  some other number; zap's `-e` and acc's `-errors` return 100.
- A command that MOS itself can't run -- a name that isn't anywhere --
  results in MOS's error number, as at the prompt.

### `void *hub_block(const char tag[4], size_t size)`

Memory that keeps its contents between runs: the same tag gives the same
block. A new block is zeroed. Asking for more than the block holds grows it,
keeping what it held and zeroing the rest -- but it may move, so take the
pointer again rather than keeping it across such a call. `NULL` if there is
no room: blocks share about 24 KB, sixteen of them at most.

Blocks last while hub runs, and through a warm reset. A fresh start of hub
begins with none.

Because a block keeps its bytes whatever the program asks, a program whose
state changes shape between versions should mark its state, so that a
version reading another's block can tell:

```c
struct state {
    unsigned size;          /* sizeof(struct state), written last */
    /* ... */
};

struct state *s = hub_block("MYPG", sizeof *s);
if (s != NULL && s->size != sizeof *s) {
    /* left by another version: start afresh */
}
```

### `int hub_depth(void)`

How many frames are open.

### `int hub_resumed(void)`

In a continuation: 1 if the machine was reset (Ctrl-Alt-Del) while one of
the frame's jobs was running. That job counts as failed, with
`HUB_RESULT_RESET` (255), and hub runs the continuation once it is started
again. Anywhere else: 0.

### `int hub_user_screen(void)`

The screen mode of the screen the last `HUB_USER_PROGRAM` job left, which
hub captured into the VDP buffer `HUB_SCREEN_BUFFER` before any pause; -1 if
there is none, or hub is older than 0.4. To show it again -- Turbo Pascal's
Alt-F5 -- switch to that mode if it differs, then

    VDU 23,27,&20,HUB_SCREEN_BUFFER;    select the buffer as a bitmap
    VDU 23,27,3,0;0;                    draw it at the top left

with logical coordinates (`VDU 23,0,&C0,1`). A mode change drops the font
back to the system one, so change the mode only if you must. Capturing needs
VDP 2.2.0 or later; on an older VDP the buffer is empty and drawing it does
nothing. hub keeps VDP buffers `0x4800`-`0x48FF` for itself.

## Patterns

The [examples](../examples) each show one, and are useful as they are:

| Example | Pattern |
|---|---|
| [`seq`](../examples/src/seq.c) | run commands one after another, stopping at the first that fails, then say which |
| [`rep`](../examples/src/rep.c) | a program that chains to itself, keeping a count in a block |
| [`see`](../examples/src/see.c) | run the user's program on the prompt's screen, pause, and show its screen again |
| [`hubinfo`](../examples/src/hubinfo.s) | find hub and call it from assembly |

**Run commands and come back.** Open a frame, push the commands with
`HUB_STOP_ON_ERROR` if a failure should stop the rest, set the continuation
to start your program with an argument meaning "back", return. In the
continuation, read `hub_failed_job` and `hub_last_result`.

**Keep state.** Before returning, write what the continuation needs into a
block, marked with its size or a version. In the continuation, take it back
-- and treat a block whose mark doesn't match as no state.

**Chain to yourself.** A continuation can open another frame and set itself
as that frame's continuation, for as many rounds as needed: a frame closes
as its continuation starts, so this never nests deeper.

**Nest.** A job may be a hub client itself. Its frame runs inside yours, and
all of it -- its jobs and its continuation -- runs before your next job. An
IDE can run a debugger, which runs the program and comes back to itself,
before the IDE's continuation runs.

**Run the user's program.** Push it with `HUB_USER_PROGRAM`, and
`HUB_PAUSE_AFTER` if its output should stay on screen until a key. Don't
stop on its error: the continuation gets its result either way. Redraw your
own screen in the continuation; hub has put the prompt's back.

## Changing an existing program to use hub

12AM Commander is an example of a program changed this way: it had a
launcher of its own for running programs, and now uses hub. Its diff is in
the [hub branch of agon-utilities](https://github.com/avalonbits/agon-utilities/tree/hub)
(`mc/src/main.c`, `run_external` and `resume_state`). The steps:

1. **Keep the program working without hub.** Wrap every use in
   `hub_present()`, and keep the old behaviour, or say that the feature
   needs hub.
2. **Find where the program wants to run something** it can't run itself --
   anything that loads at `0x40000`, over it. Built-in commands and moslets
   it can still run in place through `mos_oscli`; it is the rest that hub is
   for.
3. **Save what the program needs to carry on** -- open files' names,
   positions, settings -- in a block, with a size or version mark. Not
   pointers into the program's own memory: the program is loaded afresh.
4. **Queue the command and the way back:** `hub_enter`, `hub_push`,
   `hub_return_to("prog -r")`. Check the command's length first
   (`HUB_CMD_MAX`) and the calls' results, and if hub refuses, say so and
   carry on rather than quit.
5. **Quit**, as cleanly as when the user quits: restore the screen, close
   files, unhook what you hooked. hub cleans up after programs that don't,
   but the next one shouldn't depend on it.
6. **Come back.** On `-r`, take the state from the block, check its mark,
   redraw, and read how the command went.
7. **Put the program where MOS finds it** -- `/bin` -- so the continuation's
   bare name works.
8. **Test it under hub with a script**: `hub -f` runs a file's lines, and
   `Set Hub$NoPause 1` in it keeps pauses from waiting.

## From assembly

[`src/hub.inc`](../src/hub.inc) has the offsets and documents every call
for zap programs. hub publishes the Number variable `Hub$API`, holding the
address of its API header:

    +0  "HUB"        HUB_MAGIC
    +3  major        HUB_MAJOR      0
    +4  minor        HUB_MINOR      4
    +5  calls        HUB_COUNT      9
    +6  JP ...       one 4-byte jump per call

To find hub, read the variable with `mos_readvarval` (API `0x31`) and check
the name it returns in IY is `Hub$API` -- MOS 3.0.2 answers for a
neighbouring variable when the one asked for doesn't exist -- then check the
magic and the major version. To call, add the entry's offset to the
header's address and call it. Arguments go in HL and BC (`hub_push`'s flags
in C), the status comes back in A (0 for done) and a value in HL; IX and IY
are kept, BC and DE are not. [`examples/src/hubinfo.s`](../examples/src/hubinfo.s)
does all of it.

## Versions

New calls are only ever added at the end of the table, with the minor
version raised, and a program can check `HUB_COUNT` before calling one; the
C library does that for `hub_user_screen`.

| hub | API | Added |
|---|---|---|
| 0.2 | 0.2 | `hub_resumed` |
| 0.3 | 0.3 | `HUB_USER_PROGRAM` and `HUB_PAUSE_AFTER`; a running job no longer takes a queue slot |
| 0.4.0 | 0.4 | `hub_user_screen` |
| 0.4.1 | 0.4 | `HUB_USER_PROGRAM` gives the prompt's font, and puts the prompt's screen back afterwards |
| 0.4.2 | 0.4 | `hub_block` grows a block |

## Limits

| | |
|---|---|
| jobs waiting | 8, continuations included |
| frames open | 6 |
| a command | 93 characters |
| blocks | 16, in about 24 KB |
