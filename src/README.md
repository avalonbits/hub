# Reading hub's code

Start here. This page is a map: what each file holds, the order to read them
in, what happens to a line from the moment you type it, and the conventions
the code follows. Why hub is built this way is in
[docs/DESIGN.md](../docs/DESIGN.md).

## Two programs in one file

`hub.bin` holds two programs that work as a pair:

- **The shell** ([`hub.s`](hub.s), [`shell/`](shell)) is what MOS loads when
  you type `hub`: a moslet at `0xB0000`. It starts everything, shows the
  prompt, reads scripts, and handles the screen around user programs.
- **The core** ([`core.s`](core.s), [`core/`](core)) is carried inside the
  shell (`core_image` at the end of `hub.s`) and copied into the eZ80's
  on-chip RAM at `0xB7F300` when hub starts. It runs every command, cleans up
  after it, runs the job queue, and answers programs' API calls.

They split this way for one reason: any moslet you run loads over the shell,
and nothing loads over on-chip RAM. So the core is the part that must survive
a command, and the shell is the part that can be reloaded from the card. The
core has 1,792 bytes; `make` fails if it grows past that. The shell has room.

They talk through fixed addresses, so a reloaded shell answers at the same
place:

| From | To | Through |
|---|---|---|
| shell | core | `CORE_MAIN`, `CORE_SUM`, `CORE_INIT` ([`core/entry.s`](core/entry.s)) |
| core | shell | `SHELL_READLINE`, `SHELL_JOB_START`, `SHELL_JOB_END`, `SHELL_BLOCK_GROW` (the jumps at the top of [`hub.s`](hub.s)) |
| programs | core | the API header that `Hub$API` points at ([`core/entry.s`](core/entry.s)) |

Both are listed in [`layout.inc`](layout.inc), with every address and every
field of the control block, the on-chip RAM where hub keeps its state.

## The files

The core, in the order [`core.s`](core.s) includes them:

| File | Holds |
|---|---|
| [`core/entry.s`](core/entry.s) | the fixed entry points and the API header |
| [`core/start.s`](core/start.s) | starting afresh, or resuming after a reset |
| [`core/run.s`](core/run.s) | the main loop, and running one command through MOS |
| [`core/scheduler.s`](core/scheduler.s) | the job queue and frames: what runs next, what a failure skips |
| [`core/api.s`](core/api.s) | the calls programs make |
| [`core/blocks.s`](core/blocks.s) | client blocks, and their copy on the card |
| [`core/cleanup.s`](core/cleanup.s) | after every command: the guards, and MOS's message for a failure |
| [`core/repair.s`](core/repair.s) | noticing a moslet loaded over the shell, and reloading it |
| [`core/util.s`](core/util.s), [`core/data.s`](core/data.s) | helpers; messages |

The shell, in the order [`hub.s`](hub.s) includes them:

| File | Holds |
|---|---|
| [`shell/start.s`](shell/start.s) | starting hub, `Hub$API`, F12, the arguments, leaving |
| [`shell/lines.s`](shell/lines.s) | the prompt, script lines, and `exit` |
| [`shell/jobs.s`](shell/jobs.s) | around a user program: the screen, the capture, the pause |
| [`shell/grow.s`](shell/grow.s) | growing a client block |
| [`shell/font.s`](shell/font.s) | following the prompt's font |
| [`shell/script.s`](shell/script.s) | reading a script file |
| [`shell/text.s`](shell/text.s), [`shell/data.s`](shell/data.s) | helpers; strings |

Shared by both:

| File | Holds |
|---|---|
| [`layout.inc`](layout.inc) | every address, the control block's fields, job and frame layouts, flag bits |
| [`hub.inc`](hub.inc) | the API as programs see it: offsets, flags, results |
| [`mos_api.inc`](mos_api.inc) | the MOS calls and sysvars hub uses |
| [`version.inc`](version.inc) | hub's version, the one place it is written |

Outside `src/`: [`../include/hub/hub.h`](../include/hub/hub.h) and
[`../lib/hub_glue.s`](../lib/hub_glue.s) are the C library;
[`../test/`](../test) the tests.

## Read in this order

1. [`layout.inc`](layout.inc): the memory map and the control block. Every
   other file uses these names.
2. [`core/run.s`](core/run.s): `core_main`, the loop everything hangs off.
3. [`core/scheduler.s`](core/scheduler.s): `next_job`, and the long comment
   above it on jobs, frames and continuations.
4. [`core/api.s`](core/api.s): how a program fills the queue.
5. [`shell/start.s`](shell/start.s) and [`shell/lines.s`](shell/lines.s): how
   hub gets going and where lines come from.
6. The rest as you need it.

## The life of a typed line

You type `hello` at hub's prompt:

1. `core_main` ([core/run.s](core/run.s)) is looping. It calls
   `check_shell` ([core/repair.s](core/repair.s)) to make sure the shell is
   intact, `snapshot_blocks` ([core/blocks.s](core/blocks.s)) to save the
   blocks if a program changed them, and `next_job`
   ([core/scheduler.s](core/scheduler.s)), which finds the queue empty.
2. It calls the shell's `readline` ([shell/lines.s](shell/lines.s)), which
   notes the screen mode, prints `CLI$Prompt`, reads your line with MOS's
   line editor, and passes it to `builtin`. That checks for `exit` and
   watches for a font change (`scan_font`, [shell/font.s](shell/font.s)),
   then hands the line back to the core.
3. `build_cmd` ([core/run.s](core/run.s)) copies it as `Try hello` into
   `CTL_CMD`.
4. `run_cmd` runs it through MOS's `OSCLI`. MOS loads `hello` at `0x40000`,
   runs it, and returns -- into the core, which nothing loaded over.
5. `guards` ([core/cleanup.s](core/cleanup.s)) clears a keyboard hook, closes
   files and puts the interrupt handlers back; `report` reads
   `Try$ReturnCode` and prints MOS's message if it failed.
6. Back to step 1.

## The life of a queued job

A program calls `hub_enter("BLD ")`, `hub_push("acc x.c", HUB_STOP_ON_ERROR)`
and `hub_return_to("build -r")`, then returns:

1. `api_enter` ([core/api.s](core/api.s)) opens a frame: a slot in
   `CTL_FRAMES` holding the tag. `push_job` puts each command in `CTL_JOBS`,
   at `CTL_INSERT`, with its flags and its frame; the continuation is a job
   with `HUB_CONTINUATION` set.
2. The program returns to MOS, which returns to `run_cmd`, and the loop
   comes round to `next_job` ([core/scheduler.s](core/scheduler.s)).
3. `next_job` takes the first job: copies its header to `CTL_RUNNING` and its
   command to `CTL_CMD`, and drops it from the queue. If the job has
   `HUB_USER_PROGRAM` or `HUB_PAUSE_AFTER`, the shell's `job_start` and
   `job_end` ([shell/jobs.s](shell/jobs.s)) run around it.
4. After the job, `next_job` records its result in its frame. If it failed
   and has `HUB_STOP_ON_ERROR`, `skip_frame` moves past the rest of the
   frame to its continuation.
5. When the continuation is taken, `close_frame` copies the frame's result
   to `CTL_DONE`, where `hub_last_result` and `hub_failed_job` read it, and
   the frame closes.
6. When the queue is empty, the loop goes back to the prompt or the script.

## Words

| Word | Means |
|---|---|
| core | the code in on-chip RAM that runs commands |
| shell | the moslet: the prompt, scripts, start-up |
| control block | hub's state in on-chip RAM, `CTL_*` in [layout.inc](layout.inc) |
| job | a queued command and its flags |
| frame | one program's group of jobs, opened by `hub_enter` |
| continuation | a frame's last job, set by `hub_return_to`; it runs even after a failure |
| block | memory a program keeps between runs, `hub_block` |
| moslet | a program MOS loads at `0xB0000`, where the shell lives |
| guards | the clean-up after every command |

## Conventions

- **Every routine starts with a comment** saying what it does, then `In:`,
  `Out:` and what it clobbers. A comment above a block of code says why the
  code is there; the code says what.
- **Labels starting with `@`** are local: zap scopes them to the nearest
  label without one, so `@loop` and `@done` repeat from routine to routine.
- **Names say where things live:** `CTL_*` in the control block, `JOB_*`,
  `FRAME_*` and `BLK_*` are offsets into a job, a frame and the block area,
  `SHELL_*` and `CORE_*` the fixed entry points, `api_*` the API's routines,
  `FLAG_*_BIT` the bits of a job's flags. In the data: `msg_*` messages,
  `v_*` MOS variable names, `s_*` words hub looks for.
- **MOS calls clobber everything.** Each is `ld a, <function>` then
  `rst.lil $08`, and the code assumes A, BC, DE, HL, IX, IY and the flags are
  gone afterwards.
- **Registers are 24 bits** (ADL mode). `ld hl, 0` then `ld l, a` makes HL
  equal A with the top bytes clear; `mlt` multiplies H by L, which is how an
  index becomes an offset (`job_addr`, `frame_addr`).
- **The core keeps IX and IY** for its callers; the shell's routines that the
  core calls may clobber them.

## Making a change

- `make` builds `build/hub.bin`; `make test` runs all the tests (see the
  README at the top of the repo for what each needs).
- **A change that should not change behaviour** -- renaming, moving code
  between files, comments -- should leave `build/hub.bin` byte for byte the
  same. Keep a copy before you start and `cmp` it after.
- **The core's size** is checked by `make`. If a change needs room there,
  move work into the shell, as `block_grow` and the user-program screen
  handling were.
- **A new API call** goes at the end of the table in
  [core/entry.s](core/entry.s), with `HUB_MINOR` raised and `API_COUNT`'s
  default bumped in the Makefile; its offset in [hub.inc](hub.inc); a C
  wrapper in [../lib/hub_glue.s](../lib/hub_glue.s) that checks `HUB_COUNT`
  first, as `hub_user_screen` does; its declaration in
  [../include/hub/hub.h](../include/hub/hub.h); a row in docs/API.md's
  version table; and a test.
- **A new safeguard** gets a build switch (see `config.inc` in the Makefile)
  and a control in [../test/run.sh](../test/run.sh): a build without it, and
  a check that the test for it then fails.
- **Moving data** -- the strings at the end of [core/data.s](core/data.s)
  and [shell/data.s](shell/data.s) -- moves every address after it, so the
  bytes change even though nothing else does; run the tests.
