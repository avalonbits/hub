; shell/results.s -- What commands return: MOS's message for a failure, and
; a continuation's result passed back to the job that started its chain.
;
; Part of the shell; hub.s includes it, in order. The core calls both, after
; making sure the shell is intact.

; Entries in mos_errors[] in MOS 3.0.2 (src/mos.c): 0-19 are FatFS's, 20-26
; MOS's own. MOS's prompt prints a message only for codes below this.
MOS_ERRORS:     equ     27

; report_error: print MOS's message for the failed command's result, as MOS's
; prompt does: "\n\r<message>\n\r", for a code that has an entry in MOS's
; table, and nothing for a code past it. The table is MOS's own, through
; mos_getError.
;
; The code is not always what the program returned: when a program found on
; the run path returns 1, 4 or 5, mos_exec replaces it with 20, "Invalid
; command", since it can't tell a failing program from a missing one. MOS's
; prompt shows the same thing, so hub does too.
;
; In:   CTL_RC = the result, not 0. Clobbers everything a MOS call may.
report_error:
        ld      hl, (CTL_RC)
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

        jp      print

; cont_done: a continuation has run; pass its result on.
;
; A program that is a job in someone else's frame -- seq runs rep, say --
; returns 0 at first, having only queued its work; what it really returns is
; what its last continuation returns, after its own frame has run. That is
; the result the outer frame should see for the job. So when a continuation
; ends a chain -- it opened no next round -- its result becomes the result
; of the job that opened the chain's first frame (api_enter recorded it in
; the frame, as FRAME_OPENER and FRAME_OPFLAGS); and if that job was pushed
; with HUB_STOP_ON_ERROR and the result isn't 0, its frame now fails there,
; as if the job had.
;
; In:   CTL_RUNNING = the continuation that has just run, CTL_RC its result.
; Out:  A = the frame to skip to its continuation (for skip_frame, in the
;       core), or NO_JOB. Clobbers BC, DE, HL, IY.
cont_done:
        ld      a, (CTL_RUNNING + JOB_FRAME)
        ld      c, a                    ; C = the continuation's frame, closed
        ld      a, (CTL_DEPTH)
        cp      a, c
        jr      nz, @none               ; it opened the chain's next round

        ld      a, c
        call    frame_iy
        ld      a, (iy+FRAME_OPENER)
        cp      a, NO_JOB
        jr      z, @none                ; opened by a typed line: no job
        ld      b, a                    ; B = the opener's index in its frame
        ld      e, (iy+FRAME_OPFLAGS)   ; E = its flags

        dec     c                       ; C = the opener's frame, one out
        ld      a, c
        call    frame_iy
        ld      hl, (CTL_RC)
        ld      (iy+FRAME_RESULT), hl   ; the job's result, at last
        call    hl_is_zero
        jr      z, @none
        bit     FLAG_STOP_BIT, e
        jr      z, @none
        ld      (iy+FRAME_FAILED), b    ; it failed, and stops its frame
        ld      a, c

        ret

@none:
        ld      a, NO_JOB

        ret

; frame_iy: IY = frame A in CTL_FRAMES. Keeps BC, DE, HL.
frame_iy:
        push    hl
        push    de
        ld      hl, 0
        ld      l, a
        ld      h, FRAME_SIZE
        mlt     hl
        ld      de, CTL_FRAMES
        add     hl, de
        push    hl
        pop     iy
        pop     de
        pop     hl

        ret
