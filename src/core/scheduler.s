; core/scheduler.s -- The job queue and frames: what runs next, and what a failure skips.
;
; Part of the core; core.s includes it, in order.

; ============================================================================
; The scheduler
; ============================================================================
;
; Programs queue jobs through the API while they run; the core runs them once
; the program has returned. The pieces:
;
;   Job           a command, as typed at the prompt, with flags. Jobs wait in
;                 an array (CTL_JOBS) and run from its front. A job leaves
;                 the array as it starts (its header to CTL_RUNNING, its
;                 command to CTL_CMD), so the MAX_JOBS slots are all free for
;                 what it pushes.
;   Frame         one program's group of jobs, opened by hub_enter(tag) and
;                 ended by its continuation. Frames nest: a job that is itself
;                 a hub client opens a frame inside its caller's.
;   Continuation  the frame's last job, set by hub_return_to: usually the
;                 command that restarts the program that opened the frame. It
;                 always runs, even when a job before it failed.
;
; Ordering. A frame's jobs are inserted at CTL_INSERT, which next_job sets to
; the front of the array: just after the running job. So a nested frame's jobs run before whatever the
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
        ld      a, (CTL_NEXT)
        call    drop_jobs               ; the jobs a failure skipped
        ld      a, (CTL_NJOBS)
        or      a, a
        jr      nz, @take

        ld      (CTL_INSERT), a         ; drained: start again from empty
        ld      (CTL_DEPTH), a

        ret                             ; carry clear from the or

; The job leaves the queue as it starts: its header goes to CTL_RUNNING and
; its command to CTL_CMD, so its slot is free for the jobs it pushes. A
; program run as a job -- a continuation, usually -- has the whole queue to
; itself.
@take:
        ld      hl, CTL_JOBS
        ld      de, CTL_RUNNING
        ld      bc, JOB_CMD
        ldir                            ; HL = the job's command
        call    build_cmd               ; can't fail: hub_push checked the length
        ld      a, 1
        call    drop_jobs
        xor     a, a
        ld      (CTL_INSERT), a         ; a frame this job opens goes next
        ld      (CTL_JOB), a            ; running

        ld      ix, CTL_RUNNING
        bit     FLAG_CONT_BIT, (ix+JOB_FLAGS)
        jr      nz, @closing
        call    clear_done              ; an ordinary job sees no results
        jr      @run

@closing:
        ld      a, (ix+JOB_FRAME)
        call    close_frame

; The shell does what HUB_USER_PROGRAM and HUB_PAUSE_AFTER ask, before and
; after the job. Before, it is intact: core_main checked it. After, the job
; may have been a moslet, so it is checked again first.
@run:
        ld      a, (ix+JOB_FLAGS)
        and     a, HUB_USER_PROGRAM | HUB_PAUSE_AFTER
        call    nz, SHELL_JOB_START
        call    run_cmd
        ld      a, (CTL_RUNNING+JOB_FLAGS)
        and     a, HUB_USER_PROGRAM | HUB_PAUSE_AFTER
        jr      z, @ran
        call    check_shell
        ld      a, (CTL_RUNNING+JOB_FLAGS)
        call    SHELL_JOB_END

@ran:
        ld      ix, CTL_RUNNING
        ld      hl, (CTL_RC)
        ld      (ix+JOB_RESULT), hl
        bit     FLAG_CONT_BIT, (ix+JOB_FLAGS)
        jr      nz, @cont

        ld      a, (ix+JOB_FRAME)
        call    frame_addr              ; IY = the job's frame
        ld      (iy+FRAME_RESULT), hl
        call    hl_is_zero
        jr      z, @done                ; it worked
        bit     FLAG_STOP_BIT, (ix+JOB_FLAGS)
        jr      z, @done

        ld      a, (ix+JOB_INDEX)
        ld      (iy+FRAME_FAILED), a
        ld      a, (ix+JOB_FRAME)
        call    skip_frame

@done:
        ld      a, NO_JOB
        ld      (CTL_JOB), a
        scf

        ret

; A continuation has run. Its frame closed as it started, so the result has
; nowhere to go here; the shell passes it to the job that opened the frame,
; and says if that job's frame must now skip to its continuation.
@cont:
        call    check_shell             ; the continuation may be a moslet
        call    SHELL_CONT_DONE         ; A = a frame to skip, or NO_JOB
        cp      a, NO_JOB
        call    nz, skip_frame
        jr      @done

; ----------------------------------------------------------------------------
; drop_jobs: drop the first A jobs, moving the rest to the front of the array.
;
; In:   A = how many, at most CTL_NJOBS.
; Out:  CTL_NEXT = 0. Clobbers A, BC, DE, HL, IX.
; ----------------------------------------------------------------------------
drop_jobs:
        or      a, a
        ret     z
        ld      c, a
        ld      a, (CTL_NJOBS)
        sub     a, c
        ld      (CTL_NJOBS), a          ; the jobs still waiting
        ld      hl, 0
        ld      l, a
        ld      h, JOB_SIZE
        mlt     hl                      ; bytes to move
        ld      a, h
        or      a, l
        jr      z, @moved               ; none: LDIR would move 16 MB
        push    hl
        ld      a, c
        call    job_addr
        lea     hl, ix+0                ; from the first job kept
        ld      de, CTL_JOBS            ; to the start
        pop     bc
        ldir

@moved:
        xor     a, a
        ld      (CTL_NEXT), a

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
        ld      a, NO_JOB
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
        bit     FLAG_CONT_BIT, (ix+JOB_FLAGS)
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
