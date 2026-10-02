; shell/font.s -- Following the prompt's font: autoexec.txt, then the lines run at the
; prompt; and reading numbers as MOS does.
;
; Part of the shell; hub.s includes it, in order.

; boot_font: CTL_FONT = the font the machine's boot script selected, if it
; selected one, else the system font.
;
; The VDP can't be asked which font is in use, and a mode change drops it --
; so to put the prompt's font back after a user program, hub has to know it.
; Like aed (src/ui/bootfont.c), it reads /autoexec.txt, where a machine set
; up for a font of its own selects it, and keeps the last selection there;
; scan_font then follows selections made at hub's own prompt.
boot_font:
        ld      hl, $ffff
        ld      (CTL_FONT), hl

        IF PROMPTFONT
        ld      hl, autoexec
        ld      c, fa_read
        ld      a, mos_fopen
        rst.lil $08
        or      a, a
        ret     z
        ld      (SCRIPT_FH), a

@line:
        call    read_line
        jp      c, close_script
        ld      hl, LINE_BUF
        call    scan_font
        jr      @line
        ELSE

        ret
        ENDIF

; scan_font: if the line at HL selects a font, note it in CTL_FONT.
; HL kept; everything else clobbered.
;
; Two ways of selecting one, as aed reads them (case doesn't matter, and a
; leading '*' is MOS's and ignored):
;
;   fontctl <id>        fontctl sys -- or anything that isn't a number -- is
;                       the system font
;   VDU 23,0,149,0,<id> the selection written out (VDU 23,0,&95,0,id;flags)
;   VDU 22,<mode>       a mode change, which goes back to the system font
;
; Numbers as number reads them. A line that is neither leaves CTL_FONT be.
scan_font:
        push    hl
        call    @scan
        pop     hl

        ret

@scan:
        ld      a, (hl)
        cp      a, ' '
        jr      z, @lead
        cp      a, '*'
        jr      nz, @word

@lead:
        inc     hl
        jr      @scan

@word:
        push    hl
        ld      de, s_fontctl
        call    word_is
        jr      z, @fontctl
        pop     hl
        ld      de, s_vdu
        call    word_is
        ret     nz

        call    number
        ret     c
        ld      a, b
        or      a, a
        ret     nz
        ld      a, c
        cp      a, 22
        jr      z, @system
        cp      a, 23
        ret     nz
        ld      de, vdu_font_args + 1

@arg:
        ld      a, (de)
        cp      a, $ff                  ; the end of vdu_font_args
        jr      z, @id
        push    de
        call    number
        pop     de
        ret     c
        ld      a, (de)
        cp      a, c
        ret     nz
        ld      a, b
        or      a, a
        ret     nz
        inc     de
        jr      @arg

@id:
        call    number
        ret     c
        jr      @set

@fontctl:
        pop     de                      ; the line's start: not needed now
        call    skip_spaces
        call    number
        jr      nc, @set

@system:
        ld      bc, $ffff               ; sys, or something else

@set:
        ld      (CTL_FONT), bc

        ret

; number: a number as MOS reads one in a VDU line, after any spaces and
; commas: an optional '-', then decimal, &hex or 0xhex digits, and an
; optional ';' (sixteen bits, which changes nothing). It must end there.
; (MOS's base_digits and trailing-H forms aren't taken.)
;
; Out:  carry clear: BC = the value, masked to 16 bits as it goes to the
;       VDP (so -1 is 65535), HL past it. Carry set: not a number, or more
;       than 16 bits. Clobbers A, DE.
number:
        ld      a, (hl)
        cp      a, ' '
        jr      z, @sep
        cp      a, ','
        jr      nz, @sign

@sep:
        inc     hl
        jr      number

@sign:
        ld      de, 0
        ld      (NUM_VAL), de
        xor     a, a
        ld      (NUM_NEG), a
        ld      a, (hl)
        cp      a, '-'
        jr      nz, @base
        ld      a, 1
        ld      (NUM_NEG), a
        inc     hl

@base:
        ld      bc, 10                  ; B counts digits, C is the base
        ld      a, (hl)
        cp      a, '&'
        jr      z, @hex
        cp      a, '0'
        jr      nz, @digit
        inc     hl
        ld      a, (hl)
        dec     hl
        or      a, $20
        cp      a, 'x'
        jr      nz, @digit
        inc     hl

@hex:
        inc     hl
        ld      c, 16

@digit:
        ld      a, (hl)
        call    digit_val
        jr      c, @end
        cp      a, c
        jr      nc, @end
        ld      (NUM_DIG), a
        push    hl
        push    bc
        ld      de, (NUM_VAL)
        ld      hl, 0
        ld      b, c

@times:
        add     hl, de                  ; HL = value * base
        djnz    @times
        ld      de, 0
        ld      a, (NUM_DIG)
        ld      e, a
        add     hl, de
        ld      (NUM_VAL), hl
        ld      de, $10000
        or      a, a
        sbc     hl, de
        pop     bc
        pop     hl
        jr      nc, @fail               ; past 16 bits
        inc     hl
        inc     b
        jr      @digit

@end:
        ld      a, b
        or      a, a
        jr      z, @fail                ; no digits
        ld      a, (hl)
        cp      a, ';'
        jr      nz, @after
        inc     hl

@after:
        ld      a, (hl)
        or      a, a
        jr      z, @ok
        cp      a, ' '
        jr      z, @ok
        cp      a, ','
        jr      nz, @fail

@ok:
        ld      a, (NUM_NEG)
        or      a, a
        jr      z, @mask
        push    hl
        ld      hl, 0
        ld      de, (NUM_VAL)
        sbc     hl, de                  ; carry clear from the or
        ld      (NUM_VAL), hl
        pop     hl

@mask:
        xor     a, a
        ld      (NUM_VAL + 2), a
        ld      bc, (NUM_VAL)

        ret                             ; carry clear from the xor

@fail:
        scf

        ret

; digit_val: A = the value of the digit in A (0-9, a-f in any case); carry
; set if it isn't one.
digit_val:
        cp      a, '0'
        jr      c, @no
        cp      a, '9' + 1
        jr      c, @decimal
        or      a, $20
        cp      a, 'a'
        jr      c, @no
        cp      a, 'f' + 1
        jr      nc, @no
        sub     a, 'a' - 10

        ret                             ; carry clear: A is at least 10

@decimal:
        sub     a, '0'

        ret                             ; carry clear

@no:
        scf

        ret
