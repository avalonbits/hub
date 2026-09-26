; ============================================================================
; hub's core
; ============================================================================
;
; The core is the part of hub that gets control back from every command.
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
; The core calls back into the shell at one fixed address, SHELL_READLINE,
; which returns the next line to run (or HL = 0 to leave hub).
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
; ============================================================================

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"
        INCLUDE "hub.inc"
        INCLUDE "config.inc"

        ORG     CORE_BASE

; ----------------------------------------------------------------------------
; Entry points. Each `jp` is four bytes in ADL mode, so these sit at exactly
; CORE_BASE + 0, 4 and 8. Only ever add entries at the end.
; ----------------------------------------------------------------------------
        jp      core_main               ; CORE_BASE + 0
        jp      shell_sum               ; CORE_BASE + 4
        jp      core_init               ; CORE_BASE + 8

; ----------------------------------------------------------------------------
; The client API: a header at HUB_HEADER (CORE_BASE + 12), which the Number
; variable Hub$API points to, followed by one jump per call. hub.inc gives the
; offsets and what each call takes and returns. A client checks the magic and
; the version before calling anything, so the order here is part of the
; contract: new calls go at the end, with HUB_MINOR raised.
; ----------------------------------------------------------------------------
api_header:
        db      "HUB"                   ; HUB_MAGIC
        db      0                       ; HUB_MAJOR
        db      2                       ; HUB_MINOR
        db      8                       ; HUB_COUNT
        jp      api_enter               ; HUB_ENTER
        jp      api_push                ; HUB_PUSH
        jp      api_return_to           ; HUB_RETURN_TO
        jp      api_last_result         ; HUB_LAST_RESULT
        jp      api_failed_job          ; HUB_FAILED_JOB
        jp      api_block               ; HUB_BLOCK
        jp      api_depth               ; HUB_DEPTH
        jp      api_resumed             ; HUB_RESUMED

; ----------------------------------------------------------------------------
; core_init: everything the core sets up when hub starts.
;
; In:   A = 0 to start afresh: the shell has zeroed the control block.
;       A = 1 to resume after a warm reset: the control block is as the reset
;       left it, since the on-chip SRAM keeps its contents.
; In, both: CTL_BLKPATH set by the shell.
; Out:  the client blocks set up (afresh) or checked (resuming); a job the
;       reset cut short settled; interrupt vectors recorded. The shell then
;       publishes Hub$API and binds F12 -- start-up work that needs no
;       protection from moslets, and so stays out of the core.
;       IX and IY preserved; the rest clobbered.
;
; Resuming. MOS keeps RAM across a warm reset (it checks a magic word at
; 0xBFFFA and skips its memory wipe), but it re-initialises its own state:
; its variables, handlers and hooks are gone, so the vectors are recorded
; again (and the shell publishes Hub$API again). What survives is hub's control block,
; with the queue as it was. A job that was running when the reset came is
; treated as failed, with RESULT_RESET, and its frame marked as cut short:
; the rest of the frame is skipped, and its continuation -- usually the
; program that queued it -- runs next and can see why with hub_resumed.
; ----------------------------------------------------------------------------
core_init:
        push    ix
        push    iy
        or      a, a
        jr      nz, @resume

        ld      a, $ff
        ld      (CTL_JOB), a            ; no job running
        call    clear_done
        call    init_blocks
        call    save_blocks             ; so a restore always has a file
        jr      @common

@resume:
        call    settle_reset
        call    blocks_valid
        call    nz, restore_blocks

@common:
        call    snapshot_vectors

        pop     iy
        pop     ix

        ret

; ----------------------------------------------------------------------------
; settle_reset: settle the job a warm reset cut short, if there was one.
;
; See core_init. A continuation cut short has no frame left to report to --
; it closed when the continuation started -- so only its result is set.
; Clobbers everything.
; ----------------------------------------------------------------------------
settle_reset:
        ld      a, (CTL_JOB)
        cp      a, $ff
        jr      z, @none
        call    job_addr
        ld      hl, RESULT_RESET
        ld      (ix+JOB_RESULT), hl
        bit     7, (ix+JOB_FLAGS)       ; HUB_CONTINUATION
        jr      nz, @none

        ld      a, (ix+JOB_FRAME)
        call    frame_addr
        ld      (iy+FRAME_RESULT), hl
        ld      a, (ix+JOB_INDEX)
        ld      (iy+FRAME_FAILED), a
        ld      (iy+FRAME_RESET), 1
        ld      a, (ix+JOB_FRAME)
        call    skip_frame

@none:
        ld      a, $ff
        ld      (CTL_JOB), a

        jp      clear_done

; ----------------------------------------------------------------------------
; core_main: run commands until the shell hands back HL = 0.
;
; In:   core_init has run, and the control block holds CTL_SUMLEN, CTL_SUM
;       and CTL_SELF, since the first thing the loop does is check the shell
;       against them.
; Out:  returns to the shell when the shell's readline returns HL = 0.
;       IX and IY are preserved; everything else clobbered.
;
; Each turn of the loop:
;
;   1. check_shell   make sure the shell is intact before calling into it --
;                    the previous command may have been a moslet.
;   2. next_job      if programs have queued jobs, run the next one.
;   3. readline      otherwise, ask the shell for a line (prompt or script)
;                    and run it.
;
; Queued jobs always come before the prompt: a program that queues work and
; returns expects that work to run next.
; ----------------------------------------------------------------------------
core_main:
        push    ix
        push    iy

@loop:
        call    check_shell             ; a moslet may have loaded over it
        call    snapshot_blocks         ; save the blocks if a program changed them
        call    next_job                ; carry set: a job ran
        jr      c, @loop

        call    SHELL_READLINE          ; HL = next line, or 0 to stop
        call    hl_is_zero
        jr      z, @done

        call    build_cmd               ; CTL_CMD = "Try " + line
        jr      c, @loop                ; too long: reported, skip it
        call    clear_done              ; not a continuation
        call    run_cmd
        jr      @loop

@done:
        pop     iy
        pop     ix

        ret

; ----------------------------------------------------------------------------
; run_cmd: run CTL_CMD through MOS, clean up, and report a failure.
;
; In:   CTL_CMD = "Try <command>".
; Out:  CTL_RC = the command's result. Clobbers everything.
;
; Why "Try <line>" rather than the line itself or "Do <line>":
;
;   - OSCLI runs its argument with mos_exec(cmd, in_mos = false). With that
;     flag, a bare name like "aed" is only looked up as a moslet, because
;     MOS assumes a program calling OSCLI doesn't want to be overwritten by a
;     program at 0x40000. hub wants exactly that, so it needs the rules
;     MOS's own prompt uses: mos_exec(line, in_mos = true).
;   - Both Do and Try call mos_exec(line, true). But Do is declared with
;     expandArgs, so MOS runs GSTrans over the line before Do sees it, and
;     the command then expands it again: "Echo |<once>" would print nothing
;     instead of "<once>". Try is not, so a line is expanded exactly once,
;     as at MOS's prompt. test/run.sh checks this.
;   - Try always returns 0 itself and stores the command's real result in the
;     variable Try$ReturnCode, which report reads.
; ----------------------------------------------------------------------------
run_cmd:
        ld      hl, CTL_CMD
        ld      a, mos_oscli            ; A comes back as Try's own result,
        rst.lil $08                     ; always 0, so it is ignored

        IF GUARDS
        call    guards
        ENDIF

        jp      report

; ----------------------------------------------------------------------------
; build_cmd: CTL_CMD = "Try " followed by the line at HL.
;
; In:   HL = the line, zero-terminated.
; Out:  carry clear: CTL_CMD holds the command, zero-terminated.
;       carry set:   the line was longer than CMD_MAX; a message has been
;                    printed and CTL_CMD is not usable.
;       Clobbers A, B, BC, DE, HL.
;
; The copy is needed, not just the prefix: mos_exec writes into the string it
; is given (mos_trim puts NULs in it), and the line may sit in the moslet area
; or in a job, where the command about to run may load over it or queue more.
;
; B counts down from CMD_MAX. DJNZ uses only the 8-bit B, which is why the
; limit is 255; CTL_CMD has room for "Try " + 255 + the terminator.
; ----------------------------------------------------------------------------
build_cmd:
        push    hl
        ld      hl, try_prefix
        ld      de, CTL_CMD
        ld      bc, 4
        ldir                            ; DE now points just after "Try "
        pop     hl
        ld      b, CMD_MAX

@copy:
        ld      a, (hl)
        ld      (de), a
        or      a, a                    ; the terminator? (also clears carry)
        ret     z
        inc     hl
        inc     de
        djnz    @copy

        ld      hl, msg_long
        call    print
        scf

        ret

; ============================================================================
; The scheduler
; ============================================================================
;
; Programs queue jobs through the API while they run; the core runs them once
; the program has returned. The pieces:
;
;   Job           a command, as typed at the prompt, with flags. Jobs live in
;                 an array (CTL_JOBS) and run in array order from CTL_NEXT.
;   Frame         one program's group of jobs, opened by hub_enter(tag) and
;                 ended by its continuation. Frames nest: a job that is itself
;                 a hub client opens a frame inside its caller's.
;   Continuation  the frame's last job, set by hub_return_to: usually the
;                 command that restarts the program that opened the frame. It
;                 always runs, even when a job before it failed.
;
; Ordering. A frame's jobs are inserted at CTL_INSERT, which next_job sets to
; just after the running job. So a nested frame's jobs run before whatever the
; outer frame queued after the job that opened it, which is what nesting
; means: the IDE runs a debugger, the debugger runs the program and comes back
; to itself, and only then does the IDE's own continuation run.
;
; Closing. A frame closes when its continuation starts: its tag, the result of
; its last job and the index of the job that stopped it (if any) are copied to
; CTL_DONE, and the depth drops. The continuation reads them there with
; hub_last_result and hub_failed_job. Anything else that runs clears CTL_DONE
; first, so only the continuation ever sees them. Closing before the continuation runs --
; not after -- is what lets a program chain to itself indefinitely: each run
; opens one new frame at the same depth instead of one level deeper.
;
; Failure. A job pushed with HUB_STOP_ON_ERROR that returns non-zero skips
; the rest of its frame's jobs, and any frames nested inside them, up to the
; frame's continuation.
;
; Reset. When the queue runs dry, everything is reset: no jobs, no frames. A
; frame that never set a continuation is simply dropped then.
; ============================================================================

; ----------------------------------------------------------------------------
; next_job: run the next queued job, if there is one.
;
; In:   nothing.
; Out:  carry set if a job ran; carry clear if the queue was empty, in which
;       case the queue and frames have been reset. Clobbers everything.
; ----------------------------------------------------------------------------
next_job:
        ld      a, (CTL_NJOBS)
        ld      c, a
        ld      a, (CTL_NEXT)
        cp      a, c
        jr      c, @have

        xor     a, a                    ; drained: start again from empty
        ld      (CTL_NJOBS), a
        ld      (CTL_NEXT), a
        ld      (CTL_INSERT), a
        ld      (CTL_DEPTH), a

        ret                             ; carry clear from the xor

; Drop the jobs that have finished by moving the rest to the front of the
; array. Without this, a program that chains to itself adds a job per run
; and fills the queue after MAX_JOBS runs, though only one job is ever
; waiting.
@have:
        or      a, a
        jr      z, @take                ; nothing has finished
        ld      c, a
        ld      a, (CTL_NJOBS)
        sub     a, c
        ld      (CTL_NJOBS), a          ; the jobs still waiting
        ld      hl, 0
        ld      l, a
        ld      h, JOB_SIZE
        mlt     hl
        push    hl                      ; bytes to move
        ld      a, c
        call    job_addr
        lea     hl, ix+0                ; from the first waiting job
        ld      de, CTL_JOBS            ; to the start
        pop     bc
        ldir
        xor     a, a
        ld      (CTL_NEXT), a

@take:
        ld      (CTL_JOB), a
        inc     a
        ld      (CTL_NEXT), a
        ld      (CTL_INSERT), a         ; a frame this job opens goes next

        ld      a, (CTL_JOB)
        call    job_addr                ; IX = the job
        bit     7, (ix+JOB_FLAGS)       ; HUB_CONTINUATION
        jr      nz, @closing
        call    clear_done              ; an ordinary job sees no results
        jr      @run

@closing:
        ld      a, (ix+JOB_FRAME)
        call    close_frame

@run:
        lea     hl, ix+JOB_CMD
        call    build_cmd               ; can't fail: hub_push checked the length
        call    run_cmd

; run_cmd clobbered IX along with everything else; find the job again.
        ld      a, (CTL_JOB)
        call    job_addr
        ld      hl, (CTL_RC)
        ld      (ix+JOB_RESULT), hl
        bit     7, (ix+JOB_FLAGS)
        jr      nz, @done               ; a continuation's frame is closed

        ld      a, (ix+JOB_FRAME)
        call    frame_addr              ; IY = the job's frame
        ld      (iy+FRAME_RESULT), hl
        call    hl_is_zero
        jr      z, @done                ; it worked
        bit     0, (ix+JOB_FLAGS)       ; HUB_STOP_ON_ERROR
        jr      z, @done

        ld      a, (ix+JOB_INDEX)
        ld      (iy+FRAME_FAILED), a
        ld      a, (ix+JOB_FRAME)
        call    skip_frame

@done:
        ld      a, $ff
        ld      (CTL_JOB), a
        scf

        ret

; ----------------------------------------------------------------------------
; close_frame: close frame A, and any frames inside it.
;
; In:   A = the frame's index.
; Out:  CTL_DONE = its tag, last result and failed job; CTL_DEPTH = A.
;       Clobbers A, BC, DE, HL, IY.
; ----------------------------------------------------------------------------
close_frame:
        push    af
        call    frame_addr
        lea     hl, iy+FRAME_TAG
        ld      de, CTL_DONE
        ld      bc, FRAME_DONE          ; tag, result, failed, reset: the
        ldir                            ; frame's first bytes, as CTL_DONE's
        pop     af
        ld      (CTL_DEPTH), a

        ret

; ----------------------------------------------------------------------------
; clear_done: forget the last closed frame's results.
;
; CTL_DONE describes the frame whose continuation is running, and nothing
; else: anything that isn't a continuation -- a typed line, a script line, an
; ordinary job -- sees a result of 0 and no failed job, so a program started
; afresh can't mistake an earlier frame's results for its own.
; Clobbers A, HL.
; ----------------------------------------------------------------------------
clear_done:
        ld      hl, 0
        ld      (CTL_DONE), hl          ; tag, first three bytes
        ld      (CTL_DONE + 3), hl      ; its fourth, and the result's first two
        ld      (CTL_DONE + 5), hl      ; the result's last, and ...
        ld      (CTL_DONE + 6), hl      ; ... not cut short by a reset
        ld      a, $ff
        ld      (DONE_FAILED), a        ; no failed job

        ret

; ----------------------------------------------------------------------------
; skip_frame: skip frame A's remaining jobs, up to its continuation.
;
; In:   A = the frame's index.
; Out:  CTL_NEXT points at the frame's continuation (or past the end, if it
;       has none); frames nested inside it are dropped. Clobbers A, B, C, HL,
;       DE, IX.
;
; Jobs belonging to other frames in between -- necessarily frames nested
; inside this one, since those are the only ones inserted after its jobs --
; are skipped too.
; ----------------------------------------------------------------------------
skip_frame:
        ld      c, a

@next:
        ld      a, (CTL_NJOBS)
        ld      b, a
        ld      a, (CTL_NEXT)
        cp      a, b
        jr      nc, @end                ; ran off the end: no continuation
        call    job_addr
        ld      a, (ix+JOB_FRAME)
        cp      a, c
        jr      nz, @skip
        bit     7, (ix+JOB_FLAGS)
        jr      nz, @end                ; its continuation: stop here

@skip:
        ld      hl, CTL_NEXT
        inc     (hl)
        jr      @next

@end:
        ld      a, c
        inc     a
        ld      (CTL_DEPTH), a          ; this frame stays open; deeper ones go

        ret

; ----------------------------------------------------------------------------
; job_addr: IX = the address of job A.       Clobbers HL, DE.
; frame_addr: IY = the address of frame A.   Clobbers DE; keeps HL.
;
; MLT multiplies H by L into HL; HL is zeroed first so its upper byte is 0.
; ----------------------------------------------------------------------------
job_addr:
        ld      hl, 0
        ld      l, a
        ld      h, JOB_SIZE
        mlt     hl
        ld      de, CTL_JOBS
        add     hl, de
        push    hl
        pop     ix

        ret

frame_addr:
        push    hl
        ld      hl, 0
        ld      l, a
        ld      h, FRAME_SIZE
        mlt     hl
        ld      de, CTL_FRAMES
        add     hl, de
        push    hl
        pop     iy
        pop     hl

        ret

; ============================================================================
; The client API
; ============================================================================
;
; Called by programs, on their own stack, while hub is running them -- so
; these only record what to do; nothing runs until the program returns.
; Convention (hub.inc): arguments in HL and BC, status in A (0 = done), value
; in HL; IX and IY preserved, since C compilers keep their frame pointer in IX.
; ============================================================================

; ----------------------------------------------------------------------------
; api_enter: open a frame.         In: HL = 4-byte tag.  A = 1 if too deep.
; ----------------------------------------------------------------------------
api_enter:
        push    ix
        push    iy
        ld      a, (CTL_DEPTH)
        cp      a, MAX_FRAMES
        ld      a, 1
        jr      nc, api_out

        ld      a, (CTL_DEPTH)
        call    frame_addr              ; keeps HL
        lea     de, iy+FRAME_TAG
        ld      bc, 4
        ldir
        ld      hl, 0
        ld      (iy+FRAME_RESULT), hl
        ld      (iy+FRAME_FAILED), $ff
        ld      (iy+FRAME_RESET), 0
        ld      (iy+FRAME_COUNT), 0
        ld      hl, CTL_DEPTH
        inc     (hl)
        xor     a, a

api_out:
        pop     iy
        pop     ix

        ret

; ----------------------------------------------------------------------------
; api_push: queue a job in the open frame.
; api_return_to: queue the frame's continuation.
;
; In:   HL = the command, C = flags (api_push only).
; Out:  A = 0 done, 1 no open frame, 2 queue full, 3 command too long.
;
; The job goes in at CTL_INSERT; jobs already queued after that point (the
; outer frames' remaining work) move down one slot to make room.
; ----------------------------------------------------------------------------
api_push:
        push    ix
        push    iy
        ld      a, c
        and     a, $7f                  ; only hub_return_to may set this
        jr      push_job

api_return_to:
        push    ix
        push    iy
        ld      a, HUB_CONTINUATION

push_job:
        ld      (CTL_PUSH_FLAGS), a
        ld      (CTL_PUSH_CMD), hl

        ld      a, (CTL_DEPTH)
        or      a, a
        ld      a, 1
        jr      z, api_out              ; no frame

        ld      a, (CTL_NJOBS)
        cp      a, MAX_JOBS
        ld      a, 2
        jr      nc, api_out             ; full

        ld      b, JOB_CMD_MAX + 1      ; the length, terminator included

@measure:
        ld      a, (hl)
        or      a, a
        jr      z, @fits
        inc     hl
        djnz    @measure
        ld      a, 3
        jr      api_out                 ; too long

; Make room at CTL_INSERT by moving jobs [insert, njobs) down one slot,
; last byte first, since the areas overlap.
@fits:
        ld      a, (CTL_INSERT)
        ld      c, a
        ld      a, (CTL_NJOBS)
        sub     a, c                    ; jobs to move
        jr      z, @room
        ld      hl, 0
        ld      l, a
        ld      h, JOB_SIZE
        mlt     hl
        push    hl                      ; bytes to move
        ld      a, (CTL_NJOBS)
        call    job_addr                ; IX = just past the last job
        lea     hl, ix-1                ; the last byte to move
        lea     de, ix+JOB_SIZE-1       ; where it goes
        pop     bc
        lddr

@room:
        ld      a, (CTL_INSERT)
        call    job_addr                ; IX = the new job
        ld      a, (CTL_PUSH_FLAGS)
        ld      (ix+JOB_FLAGS), a
        ld      a, (CTL_DEPTH)
        dec     a
        ld      (ix+JOB_FRAME), a
        call    frame_addr              ; IY = the open frame
        ld      a, (iy+FRAME_COUNT)
        ld      (ix+JOB_INDEX), a
        inc     (iy+FRAME_COUNT)
        ld      hl, 0
        ld      (ix+JOB_RESULT), hl

        ld      hl, (CTL_PUSH_CMD)
        lea     de, ix+JOB_CMD

@copy:
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        or      a, a
        jr      nz, @copy

        ld      hl, CTL_INSERT
        inc     (hl)
        ld      hl, CTL_NJOBS
        inc     (hl)
        xor     a, a
        jp      api_out

; ----------------------------------------------------------------------------
; api_last_result: HL = the result of the last job of the frame whose
;                  continuation is running; 0 in anything else.
; api_failed_job:  HL = the index of the job that stopped it, or -1.
; api_depth:       HL = the number of open frames.
; api_resumed:     HL = 1 if a reset cut that frame's job short, else 0.
; Each returns A = 0 and touches only A, HL and the flags.
; ----------------------------------------------------------------------------
api_last_result:
        ld      hl, (DONE_RESULT)
        xor     a, a

        ret

api_failed_job:
        ld      hl, 0
        ld      a, (DONE_FAILED)
        ld      l, a
        cp      a, $ff
        jr      nz, @found
        ld      hl, -1                  ; all 24 bits, as C's int -1

@found:
        xor     a, a

        ret

api_depth:
        ld      hl, 0
        ld      a, (CTL_DEPTH)
        ld      l, a
        xor     a, a

        ret

api_resumed:
        ld      hl, 0
        ld      a, (DONE_RESET)
        ld      l, a
        xor     a, a

        ret

; ----------------------------------------------------------------------------
; api_block: a named block of memory that outlives the program.
;
; In:   HL = 4-byte tag, BC = size (at least 1).
; Out:  A = 0, HL = the block; or A = 1, HL = 0 if the size is 0, there is no
;       room, or the tag exists with a smaller size.
;
; The directory (BLK_DIR) lists up to MAX_BLOCKS tags with their address and
; size; blocks are handed out from BLK_NEXT upward and never freed. A new
; block is zeroed. Asking again for an existing tag returns the same block,
; contents intact -- that is the point of it.
; ----------------------------------------------------------------------------
api_block:
        push    ix
        push    iy

; A program may have run a moslet itself -- mc runs nano -- and the moslet
; may have loaded over the shell and the blocks. Repair both before handing
; out memory there.
        push    hl
        push    bc
        call    check_shell
        call    blocks_valid
        call    nz, init_blocks
        pop     bc
        pop     hl

        ld      (CTL_PUSH_CMD), hl      ; the tag (scratch shared with push)
        push    bc
        pop     iy                      ; IY = the size asked for

        ld      a, (BLK_COUNT)
        ld      c, a
        ld      ix, BLK_DIR

@find:
        ld      a, c
        or      a, a
        jr      z, @new
        ld      hl, (CTL_PUSH_CMD)
        ld      b, 4
        lea     de, ix+0

@cmp:
        ld      a, (de)
        cp      a, (hl)
        jr      nz, @miss
        inc     de
        inc     hl
        djnz    @cmp

; Found: fine if it is at least as big as asked.
        ld      hl, (ix+7)              ; its size
        lea     de, iy+0
        or      a, a
        sbc     hl, de
        jr      c, @fail
        ld      hl, (ix+4)
        xor     a, a
        jp      api_out

@miss:
        lea     ix, ix+BLK_ENTRY
        dec     c
        jr      @find

; New: IX points at the first free directory entry.
@new:
        lea     hl, iy+0
        call    hl_is_zero
        jr      z, @fail                ; a size of 0
        ld      a, (BLK_COUNT)
        cp      a, MAX_BLOCKS
        jr      nc, @fail               ; directory full

        ld      de, (BLK_NEXT)
        add     hl, de                  ; the end of the new block
        ld      de, BLK_END + 1
        or      a, a
        sbc     hl, de
        jr      nc, @fail               ; no room

        ld      hl, (CTL_PUSH_CMD)
        lea     de, ix+0
        ld      bc, 4
        ldir                            ; tag
        ld      hl, (BLK_NEXT)
        ld      (ix+4), hl              ; address
        lea     de, iy+0
        ld      (ix+7), de              ; size
        add     hl, de
        ld      (BLK_NEXT), hl
        ld      hl, BLK_COUNT
        inc     (hl)

        ld      hl, (ix+4)              ; zero it: the first byte, then copy
        ld      (hl), 0                 ; it forward over the rest
        lea     bc, iy-1
        push    hl
        push    hl
        pop     de
        inc     de
        ld      a, b
        or      a, c
        jr      z, @zeroed              ; one byte: nothing to copy (BCU is 0,
        ldir                            ; blocks are smaller than 64 KB)

@zeroed:
        pop     hl
        xor     a, a
        jp      api_out

@fail:
        ld      hl, 0
        ld      a, 1
        jp      api_out

; ============================================================================
; Keeping the client blocks
; ============================================================================
;
; The blocks live in the moslet area, above the shell, where a big enough
; moslet (nano is 6.5 KB) loads over them. So the core keeps a copy on the
; card: before each command, if the blocks' checksum differs from the one
; taken at the last save, they are saved again -- the header, the directory
; and the part of the data in use, as one file next to hub.bin. After a
; moslet, they are restored from it.
;
; What a restore can lose is only what a program wrote to its block during
; the same command in which it then ran a moslet itself: the copy on the card
; is from before that command started.
; ============================================================================

; ----------------------------------------------------------------------------
; init_blocks: an empty block area.            Clobbers A, BC, DE, HL.
; ----------------------------------------------------------------------------
init_blocks:
        ld      hl, blk_magic
        ld      de, BLK_MAGIC
        ld      bc, 4
        ldir
        ld      hl, BLK_DATA
        ld      (BLK_NEXT), hl
        xor     a, a
        ld      (BLK_COUNT), a

        ret

; ----------------------------------------------------------------------------
; blocks_valid: Z if the block area's header makes sense -- the magic is
; there and BLK_NEXT lies within the area. Clobbers A, B, DE, HL.
; ----------------------------------------------------------------------------
blocks_valid:
        ld      hl, blk_magic
        ld      de, BLK_MAGIC
        ld      b, 4

@cmp:
        ld      a, (de)
        cp      a, (hl)
        ret     nz
        inc     de
        inc     hl
        djnz    @cmp

        ld      hl, (BLK_NEXT)
        ld      de, BLK_DATA
        or      a, a
        sbc     hl, de
        jr      c, @bad
        ld      hl, (BLK_NEXT)
        ld      de, BLK_END + 1
        or      a, a
        sbc     hl, de
        jr      nc, @bad
        xor     a, a                    ; Z

        ret

@bad:
        or      a, 1                    ; NZ

        ret

; ----------------------------------------------------------------------------
; blocks_len: BC = the bytes of the block area in use, header included.
; blocks_sum: HL = their checksum.
; Both assume blocks_valid. Clobber A, BC, DE, HL (and IY: blocks_sum).
; ----------------------------------------------------------------------------
blocks_len:
        ld      hl, (BLK_NEXT)
        ld      de, BLOCKS
        or      a, a
        sbc     hl, de
        push    hl
        pop     bc

        ret

blocks_sum:
        call    blocks_len
        ld      iy, BLOCKS

        jp      sum_range

; ----------------------------------------------------------------------------
; snapshot_blocks: save the blocks if they have changed since the last save.
; save_blocks: save them regardless.
;
; mos_save (API 0x02): HL = file name, DE = address, BC = length; A = 0 when
; saved. A failed save leaves CTL_BLKSUM as it was, so the next command tries
; again. Clobbers everything a MOS call may.
; ----------------------------------------------------------------------------
snapshot_blocks:
        IF SNAPSHOT
        call    blocks_valid
        ret     nz                      ; never save a damaged area
        call    blocks_sum
        ld      de, (CTL_BLKSUM)
        or      a, a
        sbc     hl, de
        ret     z                       ; unchanged
        ENDIF

save_blocks:
        IF SNAPSHOT
        call    blocks_sum
        push    hl
        call    blocks_len
        ld      hl, CTL_BLKPATH
        ld      de, BLOCKS
        ld      a, mos_save
        rst.lil $08
        pop     hl
        or      a, a
        ret     nz
        ld      (CTL_BLKSUM), hl
        ENDIF

        ret

; ----------------------------------------------------------------------------
; restore_blocks: after a moslet, put the blocks back from the card.
;
; Falls back to what is in memory if the file can't be read but the area
; still looks valid, and to an empty area (with a message) if not.
; Clobbers everything a MOS call may.
; ----------------------------------------------------------------------------
restore_blocks:
        IF SNAPSHOT
        ld      hl, CTL_BLKPATH
        ld      de, BLOCKS
        ld      bc, BLK_END - BLOCKS
        ld      a, mos_load
        rst.lil $08
        ENDIF

        call    blocks_valid
        jr      z, @done
        call    init_blocks
        ld      hl, msg_blocks_lost
        call    print

@done:
        call    blocks_sum
        ld      (CTL_BLKSUM), hl

        ret

; ============================================================================
; Cleaning up after commands
; ============================================================================

; ----------------------------------------------------------------------------
; guards: undo what a command may have left behind.
;
; In:   nothing.
; Out:  clobbers everything a MOS call may.
;
; Runs after every command, whether or not the program knows about hub.
; Each of these is something MOS 3.0.2 doesn't clean up when a program exits:
;
;   Keyboard hook   A program can register a routine that MOS calls from the
;                   UART interrupt on every key event (API 0x1D). MOS never
;                   removes it. If the program forgets, MOS goes on calling
;                   into memory the next program has loaded over, from inside
;                   an interrupt. Setting HL = 0 removes any hook; with no
;                   hook, it does nothing. (C = 0: HL is a full 24-bit
;                   address, not one relative to MB.)
;
;   Open files      MOS has eight file handles and never closes a program's
;                   files for it. A program that leaks three leaves the next
;                   one with five. mos_fclose with C = 0 closes all of them.
;                   That is safe only because hub itself never holds a file
;                   open while a command runs: the shell opens its script,
;                   reads one line and closes it again before handing the
;                   line over.
;
;   Interrupts      A program can install its own interrupt handlers (API
;                   0x14), and MOS never puts the old ones back. hub records
;                   all 48 at start-up and restores them.
; ----------------------------------------------------------------------------
guards:
        ld      hl, 0                   ; no hook
        ld      c, 0                    ; HL is a 24-bit address
        ld      a, mos_setkbvector
        rst.lil $08

        ld      c, 0                    ; 0 = every open file
        ld      a, mos_fclose
        rst.lil $08

        jp      restore_vectors

; ----------------------------------------------------------------------------
; snapshot_vectors: record MOS's 48 interrupt handlers in CTL_VECTORS.
; restore_vectors:  put them all back.
;
; MOS offers no way to read a vector, only to set one: mos_setintvector (API
; 0x14, E = vector, HL = handler) returns the handler it replaced. So the
; snapshot sets each vector to a stand-in and immediately sets it back,
; keeping what the first call returned. Interrupts are off for the whole
; snapshot, so the stand-in can never be called; the stand-in is still a
; harmless handler in case that assumption is ever wrong.
;
; Vectors are numbered 0, 2, 4 ... $5E: MOS's table has a 2-byte entry per
; vector (vectors16.asm, NVECTORS = 48).
;
; The loop keeps its counter and pointer in the control block, because every
; MOS call may clobber every register.
; ----------------------------------------------------------------------------
snapshot_vectors:
        di
        call    vectors_start

@next:
        ld      a, (CTL_VEC_I)
        ld      e, a
        ld      hl, stand_in
        ld      a, mos_setintvector
        rst.lil $08                     ; HL = the handler it replaced
        push    hl
        ld      a, (CTL_VEC_I)
        ld      e, a
        ld      a, mos_setintvector
        rst.lil $08                     ; and back
        pop     de
        ld      hl, (CTL_VEC_P)
        ld      (hl), de
        call    vectors_step
        jr      c, @next
        ei

        ret

restore_vectors:
        call    vectors_start

@next:
        ld      hl, (CTL_VEC_P)
        ld      hl, (hl)                ; the recorded handler
        ld      a, (CTL_VEC_I)
        ld      e, a
        ld      a, mos_setintvector
        rst.lil $08
        call    vectors_step
        jr      c, @next

        ret

; vectors_start: the loop's counter at vector 0, its pointer at CTL_VECTORS.
; vectors_step: on to the next; carry set while vectors remain.
vectors_start:
        xor     a, a
        ld      (CTL_VEC_I), a
        ld      hl, CTL_VECTORS
        ld      (CTL_VEC_P), hl

        ret

vectors_step:
        ld      hl, (CTL_VEC_P)
        inc     hl
        inc     hl
        inc     hl
        ld      (CTL_VEC_P), hl
        ld      a, (CTL_VEC_I)
        add     a, 2
        ld      (CTL_VEC_I), a
        cp      a, NVECTORS * 2

        ret

stand_in:
        ei

        ret

; ----------------------------------------------------------------------------
; report: print MOS's message for a failed command, as MOS's prompt does.
;
; In:   nothing; reads the variable Try$ReturnCode that Try just set.
; Out:  CTL_RC holds the result (0 if the variable couldn't be read).
;       Clobbers everything a MOS call may.
;
; MOS's own loop (main.c) prints "\n\r<message>\n\r" when a command returns a
; non-zero code that has an entry in its message table, and nothing at all
; for 0 or for codes past the table. This does the same, using MOS's table
; through mos_getError rather than a copy of it.
;
; Note that the code is not always what the program returned: when a program
; found on the run path returns 1, 4 or 5, mos_exec replaces it with 20,
; "Invalid command", since it can't tell a failing program from a missing
; one. MOS's prompt shows the same thing, so hub does too.
;
; readvarval (API 0x31) arguments:
;   HL = variable name        IX = where to put the value
;   DE = size of that buffer  IY = 0 (not iterating over several variables)
;   C  = 0 (the raw value: a Number comes back as its 3 bytes)
; ----------------------------------------------------------------------------
report:
        ld      hl, 0
        ld      (CTL_RC), hl            ; 0 unless the read succeeds
        ld      hl, v_try_rc
        ld      ix, CTL_RC
        ld      de, 3
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        or      a, a
        ret     nz                      ; no Try$ReturnCode: nothing to say

        ld      hl, (CTL_RC)
        call    hl_is_zero
        ret     z                       ; success: MOS prints nothing

        ld      de, MOS_ERRORS
        or      a, a
        sbc     hl, de
        ret     nc                      ; past MOS's table: MOS prints nothing

; The code is below 27, so its low byte is all of it. CTL_CMD has served its
; purpose and doubles as the buffer for the message.
        ld      a, (CTL_RC)
        ld      e, a                    ; E = the error code
        ld      hl, CTL_CMD             ; HL = buffer
        ld      bc, CMD_MAX             ; BC = its size
        ld      a, mos_getError
        rst.lil $08

        ld      hl, nlcr
        call    print
        ld      hl, CTL_CMD
        call    print
        ld      hl, nlcr

        jp      print                   ; tail call: print returns for us

; ----------------------------------------------------------------------------
; check_shell: reload the shell if something loaded over it.
;
; In:   CTL_SUMLEN, CTL_SUM and CTL_SELF, set by the shell at start-up.
; Out:  the shell's code matches the checksum again, or the machine stops.
;       Clobbers everything a MOS call may.
;
; The shell's code is summed and compared with the sum taken at start-up.
; A difference means something was loaded into the moslet area: almost always
; a moslet the user ran (nano, say), directly or from a script or from inside
; another program. The shell is then reloaded from the file hub was started
; from -- the path MOS put in LastBin$Run, which the shell copied to CTL_SELF.
;
; mos_load (API 0x01) arguments:
;   HL = file name   DE = load address   BC = the most it may load
; It returns A = 0 on success. The limit keeps a wrong file from running on
; past the shell's area into the client blocks and beyond.
;
; Only the code is summed, not the client blocks or the shell's variables,
; which change as it runs. A plain sum can in principle miss a change that
; happens to add up to the same total; for telling "hub's code" from "some
; other program's code" that is not a practical concern.
;
; A moslet that overwrote the shell may also have overwritten the client
; blocks above it, so they are restored from the card too (restore_blocks).
;
; If the reload fails there is nothing safe to do: every return address above
; us on the stack points into the shell, which isn't there. So the core says
; so and stops, and the user resets the machine.
; ----------------------------------------------------------------------------
check_shell:
        IF REPAIR
        call    shell_sum               ; HL = the sum now
        ld      de, (CTL_SUM)           ; DE = the sum at start-up
        or      a, a
        sbc     hl, de
        ret     z                       ; unchanged

        ld      hl, CTL_SELF
        ld      de, SHELL_BASE
        ld      bc, BLOCKS - SHELL_BASE
        ld      a, mos_load
        rst.lil $08
        or      a, a
        jr      nz, @failed

        ld      hl, CTL_RELOADS
        inc     (hl)                    ; counted, for tests and diagnostics
        ld      hl, msg_reloaded
        call    print

        jp      restore_blocks          ; the moslet may have reached them too

@failed:
        ld      hl, msg_lost
        call    print

@stop:
        jr      @stop
        ENDIF

        ret

; ----------------------------------------------------------------------------
; shell_sum: HL = the checksum of the shell's code.
; sum_range: HL = the checksum of BC bytes from IY.
;
; In:   shell_sum: CTL_SUMLEN, how many bytes from SHELL_BASE.
;       sum_range: IY = start, BC = length, not 0.
; Out:  HL. Clobbers A, BC, DE, IY.
;
; The sum so far is rotated left one bit before each byte is added, so the
; checksum depends on where each byte is, not just which bytes there are: a
; block whose two bytes swap places reads as changed. Rotated, not shifted:
; `add hl, hl` alone would push each byte out of the 24 bits after 24 more,
; and only the last 24 bytes would count -- a moslet loading over the start
; of the shell would go unnoticed. `adc` puts the bit that fell off the top
; back in at the bottom, along with the byte.
;
; The loop's end test: in ADL mode `dec bc` sets no flags, and testing B and C
; alone would miss the upper byte. Adding BC to a zeroed HL with carry clear
; sets Z only when all 24 bits of BC are zero.
; ----------------------------------------------------------------------------
shell_sum:
        ld      iy, SHELL_BASE
        ld      bc, (CTL_SUMLEN)

sum_range:
        ld      hl, 0
        ld      de, 0

@next:
        ld      e, (iy+0)
        add     hl, hl                  ; carry = the bit that fell off
        adc     hl, de                  ; the byte, and that bit, back in
        inc     iy
        dec     bc
        push    hl
        ld      hl, 0
        or      a, a                    ; clear carry for the adc
        adc     hl, bc                  ; Z if BC == 0
        pop     hl
        jr      nz, @next

        ret

; ----------------------------------------------------------------------------
; hl_is_zero: Z set if all 24 bits of HL are zero.
;
; In:   HL.
; Out:  Z flag. HL and DE unchanged; carry cleared.
;
; `sbc hl, de` with DE = 0 and carry clear sets Z on the full 24-bit result.
; `add hl, de` then puts HL back without touching Z (ADD HL only sets carry).
; ----------------------------------------------------------------------------
hl_is_zero:
        push    de
        ld      de, 0
        or      a, a
        sbc     hl, de
        add     hl, de
        pop     de

        ret

; ----------------------------------------------------------------------------
; print: write the zero-terminated string at HL to the console.
;
; In:   HL = the string.
; Out:  clobbers A, BC, and whatever MOS's output routine does.
;
; RST 18h is MOS's "write a block" call: with BC = 0 it writes up to the
; delimiter in A instead of a count, so A = 0 means "up to the terminator".
; ----------------------------------------------------------------------------
print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

; ----------------------------------------------------------------------------
; Constants and messages.
; ----------------------------------------------------------------------------

; Entries in mos_errors[] in MOS 3.0.2 (src/mos.c): 0-19 are FatFS's, 20-26
; MOS's own. MOS's prompt prints a message only for codes below this.
MOS_ERRORS:     equ     27

try_prefix:     db      "Try "                  ; no terminator: build_cmd copies 4
v_try_rc:       db      "Try$ReturnCode", 0
blk_magic:      db      "BLK0"
msg_blocks_lost: db     "hub: client blocks lost", 13, 10, 0
nlcr:           db      10, 13, 0               ; MOS's own order, "\n\r"
msg_long:       db      "hub: line too long", 13, 10, 0
msg_reloaded:   db      "hub: shell reloaded", 13, 10, 0
msg_lost:       db      "hub: cannot reload the shell; reset the machine", 13, 10, 0

core_end:
