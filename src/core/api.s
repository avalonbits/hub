; core/api.s -- The calls programs make: hub_enter, hub_push, hub_block and the rest.
;
; Part of the core; core.s includes it, in order.

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
        ld      (iy+FRAME_FAILED), NO_JOB
        ld      (iy+FRAME_RESET), 0
        ld      (iy+FRAME_COUNT), 0

; Who opened it, so that what its last continuation returns can count as
; that job's result (see cont_done in the shell). A typed line is no job.
; A continuation opening the next round of a chain leaves the record as it
; is: the slot is the one its own frame used, and the chain belongs to the
; job that started it.
        ld      a, (CTL_JOB)
        cp      a, NO_JOB
        jr      z, @opener              ; A = NO_JOB: opened by a line
        ld      hl, CTL_RUNNING + JOB_FLAGS
        bit     FLAG_CONT_BIT, (hl)
        jr      nz, @counted            ; a chain's next round: keep it
        ld      a, (hl)
        ld      (iy+FRAME_OPFLAGS), a
        ld      a, (CTL_RUNNING + JOB_INDEX)

@opener:
        ld      (iy+FRAME_OPENER), a

@counted:
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
        cp      a, NO_JOB
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

; api_user_screen: HL = the mode of the captured user screen, or -1. The
; shell stores it plus 1, so the 0 a fresh control block holds reads as -1.
api_user_screen:
        ld      hl, 0
        ld      a, (CTL_CAPMODE)
        ld      l, a
        dec     hl
        xor     a, a

        ret

; ----------------------------------------------------------------------------
; api_block: a named block of memory that outlives the program.
;
; In:   HL = 4-byte tag, BC = size (at least 1).
; Out:  A = 0, HL = the block; or A = 1, HL = 0 if the size is 0 or there
;       is no room.
;
; The directory (BLK_DIR) lists up to MAX_BLOCKS tags with their address and
; size; blocks are handed out from BLK_NEXT upward and never freed. A new
; block is zeroed. Asking again for an existing tag returns the same block,
; contents intact -- that is the point of it. Asking for more than it holds
; grows it, which the shell does (SHELL_BLOCK_GROW): intact as far as it went,
; zeroed beyond, and perhaps moved.
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

; Found: fine if it is at least as big as asked; the shell grows it if not.
; check_shell above made sure the shell is there to call.
        ld      hl, (ix+7)              ; its size
        lea     de, iy+0
        or      a, a
        sbc     hl, de
        jr      c, @grow
        ld      hl, (ix+4)
        xor     a, a
        jp      api_out

@grow:
        call    SHELL_BLOCK_GROW
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
