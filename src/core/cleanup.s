; core/cleanup.s -- After every command: the guards, and reading its result.
;
; Part of the core; core.s includes it, in order.

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
; report: read the command's result, and have MOS's message for a failure
; printed, as MOS's prompt does.
;
; In:   nothing; reads the variable Try$ReturnCode that Try just set.
; Out:  CTL_RC holds the result (0 if the variable couldn't be read).
;       Clobbers everything a MOS call may.
;
; The message is the shell's to print (report_error, in shell/jobs.s): the
; core keeps only what it must. The command may have been a moslet that
; loaded over the shell, so the shell is checked first.
;
; readvarval (API 0x31) arguments:
;   HL = variable name        IX = where to put the value
;   DE = size of that buffer  IY = 0 (not iterating over several variables)
;   C  = 0 (the raw value: a Number comes back as its 3 bytes)
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

        call    check_shell
        jp      SHELL_REPORT
