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
;   0xB7F980            CTL_BASE: the control block -- hub's state, the job
;                       queue and the frames. It is not part of this image, so
;                       copying the core in never overwrites it, and it
;                       survives a reloaded shell.
;   0xB80000            SRAM_END.
;
; ENTRY POINTS
;
; A jump table at the very start of the image, so the addresses never move
; when the code does:
;
;   CORE_BASE + 0   core_main   (shell) run commands until the shell says stop
;   CORE_BASE + 4   shell_sum   (shell) checksum the shell's code
;   CORE_BASE + 8   core_init   (shell) record vectors, set up blocks, publish
;                               the API
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
        db      1                       ; HUB_MINOR
        db      7                       ; HUB_COUNT
        jp      api_enter               ; HUB_ENTER
        jp      api_push                ; HUB_PUSH
        jp      api_return_to           ; HUB_RETURN_TO
        jp      api_last_result         ; HUB_LAST_RESULT
        jp      api_failed_job          ; HUB_FAILED_JOB
        jp      api_block               ; HUB_BLOCK
        jp      api_depth               ; HUB_DEPTH

; ----------------------------------------------------------------------------
; core_init: everything the core sets up once, when hub starts.
;
; In:   the shell has copied the core in and zeroed the control block.
; Out:  interrupt vectors recorded, block area empty, Hub$API published.
;       CTL_CMD is used as scratch.
;       IX and IY preserved; everything else clobbered.
; ----------------------------------------------------------------------------
core_init:
        push    ix
        push    iy

        ld      a, $ff
        ld      (CTL_JOB), a            ; no job running
        ld      (CTL_DONE + 7), a       ; no frame has finished, so none failed

        call    snapshot_vectors

        ld      hl, BLK_DATA
        ld      (BLK_NEXT), hl
        xor     a, a
        ld      (BLK_COUNT), a

; Publish the API as a Number variable, through the SetEval command rather
; than mos_setvarval (API $30). In MOS 3.0.2, setVarVal only creates a
; variable when getSystemVariable returns -1, but that returns a positive
; number for "not found" whenever the name would sort after an existing
; variable -- so the API call quietly overwrites that neighbour instead
; (mos_sysvars.c, setVarVal: `if (result == -1)`). With the names MOS has at
; boot, "Hub$API" lands on Current$Dir. SetEval goes through
; createOrUpdateSystemVariable, which gets this right, and reads & as hex.
        ld      hl, set_api
        ld      de, CTL_CMD
        ld      bc, set_api_end - set_api
        ldir                            ; "SetEval Hub$API &"
        ld      a, (HUB_HEADER >> 16) & $ff
        call    hex_byte
        ld      a, (HUB_HEADER >> 8) & $ff
        call    hex_byte
        ld      a, HUB_HEADER & $ff
        call    hex_byte
        xor     a, a
        ld      (de), a
        ld      hl, CTL_CMD
        ld      a, mos_oscli
        rst.lil $08

        pop     iy
        pop     ix

        ret

; ----------------------------------------------------------------------------
; core_main: run commands until the shell hands back HL = 0.
;
; In:   core_init has run, and the control block holds CTL_SUMLEN, CTL_SUM
;       and CTL_SELF, since the first thing the loop does is check the shell
;       against them.
; Out:  returns to the shell when the shell's readline returns HL = 0, having
;       withdrawn Hub$API. IX and IY are preserved; everything else clobbered.
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

; Withdraw the API, so programs run after hub has gone don't call into a
; core that no longer answers.
@done:
        ld      hl, unset_api
        ld      a, mos_oscli
        rst.lil $08

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
        ld      bc, 8                   ; tag, result, failed: the frame's
        ldir                            ; first eight bytes, as CTL_DONE's
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
        ld      a, $ff
        ld      (CTL_DONE + 7), a       ; ... no failed job

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
; Each returns A = 0 and touches only A, HL and the flags.
; ----------------------------------------------------------------------------
api_last_result:
        ld      hl, (CTL_DONE + 4)
        xor     a, a

        ret

api_failed_job:
        ld      hl, 0
        ld      a, (CTL_DONE + 7)
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
; blocks above it; saving them to the card and restoring them is phase 2.
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

        jp      print

@failed:
        ld      hl, msg_lost
        call    print

@stop:
        jr      @stop
        ENDIF

        ret

; ----------------------------------------------------------------------------
; shell_sum: HL = the 24-bit sum of the shell's code bytes.
;
; In:   CTL_SUMLEN = how many bytes, from SHELL_BASE. Must not be 0.
; Out:  HL = the sum. Clobbers A, BC, DE, IY.
;
; DE is zeroed once and only E is ever loaded, so `add hl, de` adds one
; unsigned byte each time. The largest possible sum, 4 KB of 0xFF, easily
; fits in 24 bits.
;
; The loop's end test: in ADL mode `dec bc` sets no flags, and testing B and C
; alone would miss the upper byte. Adding BC to a zeroed HL with carry clear
; sets Z only when all 24 bits of BC are zero.
; ----------------------------------------------------------------------------
shell_sum:
        ld      iy, SHELL_BASE
        ld      bc, (CTL_SUMLEN)
        ld      hl, 0
        ld      de, 0

@next:
        ld      e, (iy+0)
        add     hl, de
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
; hex_byte: write A as two upper-case hex digits at DE, advancing DE.
; Clobbers A, C.
; ----------------------------------------------------------------------------
hex_byte:
        ld      c, a
        rra
        rra
        rra
        rra
        call    @digit
        ld      a, c

@digit:
        and     a, $0f
        add     a, '0'
        cp      a, '9' + 1
        jr      c, @put
        add     a, 'A' - '9' - 1

@put:
        ld      (de), a
        inc     de

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
set_api:        db      "SetEval Hub$API &"     ; + the header's address, in hex
set_api_end:
unset_api:      db      "Unset Hub$API", 0
nlcr:           db      10, 13, 0               ; MOS's own order, "\n\r"
msg_long:       db      "hub: line too long", 13, 10, 0
msg_reloaded:   db      "hub: shell reloaded", 13, 10, 0
msg_lost:       db      "hub: cannot reload the shell; reset the machine", 13, 10, 0

core_end:
