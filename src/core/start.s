; core/start.s -- Starting the core: afresh, or resuming after a warm reset.
;
; Part of the core; core.s includes it, in order.

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

        ld      a, NO_JOB
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
        cp      a, NO_JOB
        jr      z, @none
        ld      ix, CTL_RUNNING
        ld      hl, RESULT_RESET
        ld      (ix+JOB_RESULT), hl
        bit     FLAG_CONT_BIT, (ix+JOB_FLAGS)
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
        ld      a, NO_JOB
        ld      (CTL_JOB), a

        jp      clear_done
