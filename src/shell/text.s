; shell/text.s -- Small helpers for text: word_is, skip_spaces, hl_is_zero, print.
;
; Part of the shell; hub.s includes it, in order.

; word_is: Z if the word at HL is the lower-case word at DE, in any case,
; and ends there (with a space or the line's end).
;
; In:   HL = the text, DE = the word, zero-terminated.
; Out:  Z if it is; HL then points just after the word. Clobbers A, C, DE.
word_is:
        ld      a, (de)
        or      a, a
        jr      z, @end
        ld      c, a
        ld      a, (hl)
        or      a, $20
        cp      a, c
        ret     nz
        inc     hl
        inc     de
        jr      word_is

@end:
        ld      a, (hl)
        or      a, a
        ret     z
        cp      a, ' '

        ret

; skip_spaces: move HL past any spaces. Out: A = the first other character.
skip_spaces:
        ld      a, (hl)
        cp      a, ' '
        ret     nz
        inc     hl
        jr      skip_spaces

; hl_is_zero: Z if all 24 bits of HL are zero. HL and DE are kept.
hl_is_zero:
        push    de
        ld      de, 0
        or      a, a
        sbc     hl, de
        add     hl, de
        pop     de

        ret

; print: write the zero-terminated string at HL to the console.
; Clobbers A, BC, and what MOS's output may.
print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret
