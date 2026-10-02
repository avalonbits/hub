# hub's design

The Agon runs one program at a time. MOS loads it, calls it, and when it
returns, control goes back to whoever asked MOS to run it -- usually MOS's
own prompt, which has forgotten everything about the program. hub puts
itself in that place for every command, so that when a command returns, hub
is the one that gets control back: it can clean up after the command, run
the next one, and bring a program back that asked to be brought back.

## Where it came from

The idea comes from Lennart Benschop's **12AM Commander** (`mc`), a
Midnight Commander look-alike in
[agon-utilities](https://github.com/lennart-benschop/agon-utilities/tree/main/mc).
A file manager has to run other programs -- an editor, a viewer, anything
the user picks -- and those load at `0x40000`, over the file manager. mc
solves that with a small launcher, `mc/launcher.asm`, which it copies into
the eZ80's on-chip RAM at `0xB7E000`, the one place nothing MOS loads ever
reaches. The launcher loads the commander and calls it. To run a program,
the commander writes its name and arguments at fixed addresses in that RAM
and quits; the launcher runs the program, then loads the commander again,
handing it its directories on the command line.

hub takes that idea and makes it general:

- Any program can ask to run commands and be brought back, not only one
  file manager, and the programs it runs can do the same: requests nest.
- What a program wants kept while it is away lives in named blocks hub
  keeps, not in a command line.
- The code that gets control back after every command also cleans up after
  it, so a program that misbehaves doesn't take the machine down later.
- If the machine is reset in the middle, hub picks up where it was.

hub's core sits in the same on-chip RAM, above the region mc's launcher
uses, so the two can be on one machine. mc itself has been ported to hub in
a [fork](https://github.com/avalonbits/agon-utilities/tree/hub): its
launcher is gone, and hub runs its programs.

## Two parts

| Part | Source | Lives at | Size |
|---|---|---|---|
| core | [`src/core.s`](../src/core.s) | on-chip RAM, `0xB7F300` | at most 1,792 bytes |
| shell | [`src/hub.s`](../src/hub.s) | the moslet area, `0xB0000` | ~3.7 KB, the core's image included |

The **core** is the code MOS returns into after every command, so it must
survive anything a command loads. Nothing MOS loads goes into on-chip RAM,
so that is where it lives. On-chip RAM is 8 KB and 12AM Commander uses the
lower 4.75 KB, which leaves the core 1,792 bytes; the Makefile fails the
build if it grows past that.

The **shell** is everything else: starting hub, the prompt, scripts, the
screen handling around user programs, font tracking and growing blocks. It
is a moslet, so `hub` works as a command, and any moslet the user runs loads
over it. The core checks for that after each command and reloads the shell
from the card before calling into it again (see [Repair](#repair)).

The shell is called from MOS; the core is called from the shell, and runs
every command itself:

    MOS  --calls-->  shell (0xB0000)  --calls-->  core (0xB7F300)
                                                     |
                                        OSCLI  <-----+   each command
                                          |
                               the command runs, returns to the core

## Memory

All addresses are in [`src/layout.inc`](../src/layout.inc).

| Address | What |
|---|---|
| `0xB0000` | the shell's code |
| `0xB1000` | client blocks: a header, a directory of 16 entries, then the blocks (about 24 KB) |
| `0xB7000` | the shell's scratch: its line buffer and the like |
| `0xB7E000`-`0xB7F2FF` | 12AM Commander's launcher; not hub's |
| `0xB7F300` | the core |
| `0xB7FA00` | the control block, to `0xB7FFFF` |

The **control block** holds everything hub has to remember between commands:
the job queue, the frames, the path `hub.bin` was run from, the script and
its position, the interrupt handlers to put back, the screen mode and font
of the prompt. It is on-chip RAM, not part of the core's image -- so copying
the core in at start-up never overwrites it, and it survives both a reloaded
shell and a warm reset.

## Running a command

Every command, typed, from a script or queued by a program, goes through
`run_cmd` in the core as `Try <command>` through MOS's `OSCLI`:

- `OSCLI` on its own runs a bare name only as a moslet, because it assumes a
  program calling it doesn't want to be overwritten by a program at
  `0x40000`. hub wants exactly that. `Try` runs its argument the way MOS's
  own prompt does, so `/bin` programs and `.bin` paths work too.
- `Do` would also do that, but MOS expands a `Do` line's variables before
  `Do` sees it, and `Do` expands them again: `Echo |<once>` would lose its
  text. A `Try` line is expanded once, as at the prompt.
- `Try` stores the command's result in `Try$ReturnCode`, which `report`
  reads; a failure prints MOS's message for it.

`mos_exec` writes into the command it is given, so the core always runs a
copy (`build_cmd`), never a line that lives in a job or the shell's code.

After each command come the **guards** (`guards`): the keyboard hook is
cleared, every file left open is closed, and MOS's 48 interrupt vectors are
put back as they were when hub started. A program that hooks the keyboard or
an interrupt and forgets to unhook it would otherwise leave MOS calling into
memory the next program has overwritten.

The core's loop, `core_main`: check the shell is intact, save the client
blocks if a program changed them, run the next queued job if there is one,
and otherwise ask the shell for a line -- from the prompt or the script --
and run that.

## The scheduler

Programs queue work through the API while they run; the core runs it once
the program has returned. The pieces, in the scheduler's comment in
`src/core.s` and in `next_job`:

- A **job** is a command with flags. Jobs wait in an array in the control
  block, eight of them, and run from its front.
- A **frame** is one program's group of jobs, opened by `hub_enter`.
- A **continuation**, set by `hub_return_to`, is the frame's last job --
  usually the command that restarts the program that opened the frame. It
  runs even when a job before it failed.

**Order.** A frame's jobs go in just after the job that is running. So when a
job is itself a hub client and opens a frame, its work runs before whatever
the outer frame queued next: an IDE runs a debugger, the debugger runs the
program and comes back to itself, and only then does the IDE's continuation
run. Frames nest six deep.

**Closing.** A frame closes when its continuation starts. Its tag, the result
of its last job and the index of the job that stopped it, if any, are copied
aside for the continuation to read with `hub_last_result` and
`hub_failed_job`; anything else that runs clears them first, so a program
started afresh can't mistake an earlier frame's results for its own. Closing
before the continuation runs, not after, is what lets a program chain to
itself for ever: each run opens one new frame at the same depth.

**Failure.** A job pushed with `HUB_STOP_ON_ERROR` that returns non-zero skips
the rest of its frame, and any frames nested in it, up to its continuation
(`skip_frame`).

**Nested results.** A job that is itself a hub client returns at first
having only queued work, usually with 0; its real result is what its last
continuation returns, after its own frame has run. So `hub_enter` records in
the new frame which job opened it and that job's flags -- unless the caller
is a continuation opening the next round of a chain, which keeps the record
of the chain's first frame. When a continuation ends without opening a next
round, the shell's `cont_done` makes its result the opener's result in the
frame one out, and if the opener was pushed with `HUB_STOP_ON_ERROR` and the
result isn't 0, skips that frame to its continuation, as if the job had
failed directly.

**The running job.** A job leaves the queue as it starts: its header goes to
the control block and its command to the command buffer. All eight slots are
then free for what it pushes -- which matters to a program that is itself
running as a continuation, as an IDE is after its first build.

When the queue runs dry, frames and queue reset; a frame that never set a
continuation is dropped then.

## User programs

A job pushed with `HUB_USER_PROGRAM` is a program the user wants to see,
started by a program that owns the screen -- an IDE, a file manager. The core
calls two entries in the shell around such a job (`job_start`, `job_end`):

- **Before**, the screen as hub's prompt had it (`reset_screen`): cursor
  behaviour to its defaults, the prompt's mode -- which also resets colours
  and viewports and clears the screen -- then the prompt's font, then the
  cursor on. The font comes after the mode because a mode change goes back
  to the system font.
- **After**, the screen the program left is captured into the VDP buffer
  `HUB_SCREEN_BUFFER` (`capture`), so the program that queued it can show it
  again, as Turbo Pascal's Alt-F5 does; `hub_user_screen` gives the mode it
  was in. Then, with `HUB_PAUSE_AFTER`, "Press a key to return". Then the
  prompt's screen again, so the continuation starts as it would from the
  prompt.

The VDP can't be asked which font is in use, so hub follows it, as aed does:
at a fresh start it takes the last font selection in `/autoexec.txt` --
`fontctl <id>`, `fontctl sys`, or `VDU 23,0,149,0,<id>` -- and then the same
forms in the lines run at its prompt, where a `VDU 22` mode change means the
system font again (`boot_font`, `scan_font`). The prompt's mode is read from
MOS each time the shell reads a line.

`Hub$NoPause`, when set, makes the pause print its message without waiting:
tests that drive hub from a script set it.

## Blocks

`hub_block(tag, size)` hands out memory in the moslet area that keeps its
contents between a program's runs (`api_block`). A directory lists up to 16
tags with their address and size; blocks are handed out upward and never
freed. A new block is zeroed. Asking again for a tag returns the same block.
Asking for more than it holds grows it (`block_grow`, in the shell): the
last block grows where it is, any other is copied to the end, and the old
bytes are kept and the rest zeroed. So a block can move, and a program whose
state changes shape between versions should mark its version in it.

The blocks share the moslet area with the shell, and a big enough moslet --
nano is 6.5 KB -- loads over them too. So the core keeps a copy on the card,
`hub.blk` next to `hub.bin`: before each command, if the blocks' checksum has
changed since the last save, it saves them again (`snapshot_blocks`), and it
restores them from there after a moslet (`restore_blocks`). `hub_block`
repairs first too, for programs that run moslets themselves, as mc runs
nano.

A fresh start of hub begins with no blocks and overwrites `hub.blk`.

## Repair

The shell's code is checksummed when hub starts (`shell_sum`). After every
command, and when a program asks for a block, the core sums it again; if the sum differs, a moslet loaded over it, and the core reloads
`hub.bin` from the path it was started from (`check_shell`), then restores
the blocks. If the reload fails there is nothing safe left to return to, and
the core says so and stops.

The checksum rotates its running sum left before adding each byte, so it
depends on where each byte is; a plain shift would push early bytes out of
its 24 bits and miss a moslet that loaded over only the start of the shell.

## Resuming after a reset

A warm reset (Ctrl-Alt-Del) keeps RAM, but MOS starts again: its variables,
hooks and handlers are gone, and nothing is running. The control block
survives in on-chip RAM, with the queue and the script position. When hub
starts and finds its control block's magic in place but no `Hub$API`
variable, it resumes instead of starting afresh: it keeps the queue and the
blocks, and treats the job the reset interrupted as failed, with result 255,
marking its frame so that the continuation can ask `hub_resumed`
(`settle_reset`). Starting hub from `/autoexec.txt` makes that automatic;
F12 does it by hand.

## The API

hub publishes the Number variable `Hub$API`, holding the address of a header
in the core:

    +0  "HUB"         magic
    +3  0             major version
    +4  5             minor version
    +5  9             number of entries
    +6  JP hub_enter  one 4-byte jump per call, in a fixed order

A client reads the variable, checks the magic and version, and calls an
entry by adding its offset to the header's address. New calls only ever go
at the end, with the minor version raised, so a client checks the number of
entries before calling a newer one -- the C library does that for
`hub_user_screen`. The calls follow MOS's convention: arguments in HL and BC,
status in A, value in HL. [`src/hub.inc`](../src/hub.inc) documents each.

The C library is a thin glue file, [`lib/hub_glue.s`](../lib/hub_glue.s),
that moves C's stack arguments into registers. agondev and acc call C
functions the same way, so the one source serves both: zap assembles it as an
ELF archive for agondev and an ACC one for acc.

The shell's entries, which only the core calls, are at fixed places after
the moslet header so a reloaded shell answers at the same addresses:
`SHELL_READLINE`, `SHELL_JOB_START`, `SHELL_JOB_END` and `SHELL_BLOCK_GROW`.

## MOS 3.0.2 quirks hub works around

- `mos_setvarval` (API `0x30`) overwrites the variable that sorts just before
  a new name instead of creating it. hub creates `Hub$API` with `SetEval`
  through `OSCLI` (`publish_api`).
- `mos_readvarval` (API `0x31`) answers for that same neighbour, with status
  0, when the variable asked for doesn't exist. hub, `hub.inc`'s example and
  the C library compare the name it returns in IY with the one asked for.
- MOS rewrites a program's result 1, 4 or 5 to 20, "Invalid command". Tools
  that report failure through hub (zap's `-e`, acc's `-errors`) exit with 100.
- `mos_exec` writes into the command it runs, so hub runs copies.
- There is no `MODE` command: a mode change at the prompt is `VDU 22 <n>`.

Both variable bugs come from `getSystemVariable` in MOS's `mos_sysvars.c`
returning a positive number for "not found" while its callers only test for
-1.

## Testing

The tests run hub on fab-agon-emulator, driven the way zap's and acc's tests
drive it: a script in `autoexec.txt` on a fresh card, the emulator's input
held open, both output streams captured -- never commands typed into its
input, which silently stops working past a few tens of KB.

Each safeguard has a control: [`test/run.sh`](../test/run.sh) builds hub
without it (`GUARDS=0`, `REPAIR=0`, `SNAPSHOT=0`, `CAPTURE=0`,
`PROMPTFONT=0`) and checks that the test for it fails, so a check that
passes for the wrong reason shows up.

The CLI emulator's VDP is a stand-in that draws nothing, but logs the VDU
commands it doesn't handle, so the screen reset can be read off the console.
What a user program actually gets on screen -- its font, its captured screen
drawn back -- is checked on the full emulator, which runs the real VDP
firmware, with SDL's dummy video driver ([`test/screen.sh`](../test/screen.sh)).

## Limits

| | |
|---|---|
| jobs waiting | 8, continuations included |
| frames open | 6 |
| a command | 93 characters |
| blocks | 16, in about 24 KB |
| the core | 1,792 bytes |
