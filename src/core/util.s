; core/util.s -- Small helpers: hl_is_zero, print.
;
; Part of the core; core.s includes it, in order.

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
