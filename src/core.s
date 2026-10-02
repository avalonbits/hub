; ============================================================================
; hub's core
; ============================================================================
;
; The core is the part of hub that gets control back from every command.
; src/README.md is the guide to the code; this file explains the core, then
; includes its parts in order.
;
; WHY THERE IS A CORE AT ALL
;
; The Agon runs one program at a time. MOS loads a normal program at 0x40000
; and a moslet at 0xB0000, calls it, and when it returns, control goes back to
; whoever asked MOS to run it. hub wants to be that "whoever" for every
; command, so that it can run the next one, clean up after the last one, and
; bring programs back when they ask. That means the code that calls MOS -- and
; so the code MOS returns into -- must still be intact after any command,
; whatever that command loaded.
;
; Nothing MOS loads is ever placed in the on-chip SRAM (0xB7E000-0xB7FFFF): not
; normal programs, not moslets, not MOS itself. So the core lives there, and
; is the only code on the path back from a command:
;
;       MOS  --calls-->  shell (0xB0000)  --calls-->  core (0xB7F300)
;                                                        |
;                                           OSCLI  <-----+   each command
;                                             |
;                                  the command runs, returns to the core
;
; The shell -- the prompt and the rest of hub -- is a moslet at 0xB0000, and
; any moslet the user runs loads over it. The core notices that after the
; command and reloads the shell from the card before calling into it again.
;
; WHAT THE CORE DOES
;
;   1. Runs commands: each typed or script line, and each job programs queue.
;   2. Cleans up after every one (the guards).
;   3. Schedules: programs queue jobs through the API below, grouped in
;      frames, each ending with a continuation that brings its program back.
;   4. Keeps named blocks of memory for programs, which outlive the programs.
;
; WHERE THINGS ARE (see layout.inc)
;
;   0xB7E000-0xB7F2FF   12AM Commander's launcher and mailboxes. Not ours;
;                       hub starts above them so both can be present.
;   0xB7F300            CORE_BASE: this file's code, copied here by the shell
;                       at start-up. It must end before CTL_BASE; the Makefile
;                       fails the build if it doesn't.
;   0xB7FA00            CTL_BASE: the control block -- hub's state, the job
;                       queue and the frames. It is not part of this image, so
;                       copying the core in never overwrites it, and it
;                       survives a reloaded shell and a warm reset.
;   0xB80000            SRAM_END.
;
; ENTRY POINTS
;
; A jump table at the very start of the image, so the addresses never move
; when the code does:
;
;   CORE_BASE + 0   core_main   (shell) run commands until the shell says stop
;   CORE_BASE + 4   shell_sum   (shell) checksum the shell's code
;   CORE_BASE + 8   core_init   (shell) A = 0 to start afresh, 1 to resume
;                               after a reset
;   CORE_BASE + 12  the client API header and its jump table (see hub.inc)
;
; The core calls back into the shell at fixed addresses: SHELL_READLINE,
; and SHELL_JOB_START and SHELL_JOB_END around a job with HUB_USER_PROGRAM
; or HUB_PAUSE_AFTER set. SHELL_READLINE returns the next line to run (or
; HL = 0 to leave hub).
;
; CALLING MOS
;
; Every MOS call here is `ld a, <function>` then `rst.lil $08`, with the
; arguments in the registers MOS documents for that function (src/mos_api.asm
; in MOS 3.0.2). MOS returns its status in A. It does not promise to keep any
; other register, so this code assumes every MOS call clobbers A, BC, DE, HL,
; IX, IY and the flags, and reloads whatever it needs afterwards.
;
; STACK
;
; The core's own loop runs on MOS's 2 KB SPL stack (0xBF800-0xBFFFF), which it
; shares with MOS, with every command MOS runs for it until that command
; switches to its own stack, and with FatFS, which puts a ~512-byte
; long-filename buffer on it during every file open and load. Nothing in the
; core keeps data on the stack beyond a few saved registers; buffers live in
; the control block. API calls run on the calling program's stack.
;
; ASSEMBLY-TIME SWITCHES (config.inc, written by the Makefile)
;
;   GUARDS  1 = clean up after every command. 0 exists only so the tests can
;             show their checks fail without it.
;   REPAIR  1 = reload the shell when a moslet has overwritten it. 0 likewise.
;   SNAPSHOT 1 = save the client blocks to the card when they change, and
;             restore them after a moslet. 0 likewise.
;   CAPTURE, PROMPTFONT and API_COUNT are the shell's and the API header's:
;             see the Makefile.
; ============================================================================

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"
        INCLUDE "hub.inc"
        INCLUDE "config.inc"

        ORG     CORE_BASE

        INCLUDE "core/entry.s"
        INCLUDE "core/start.s"
        INCLUDE "core/run.s"
        INCLUDE "core/scheduler.s"
        INCLUDE "core/api.s"
        INCLUDE "core/blocks.s"
        INCLUDE "core/cleanup.s"
        INCLUDE "core/repair.s"
        INCLUDE "core/util.s"
        INCLUDE "core/data.s"
