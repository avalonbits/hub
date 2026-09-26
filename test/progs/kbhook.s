; kbhook: install a keyboard hook and return without removing it.
;
; The handler is copied to on-chip SRAM below hub's core, so it would still
; be there to run; what matters to the test is only that MOS still points at
; it after this program has gone.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        ORG     $40000

HANDLER:        equ     $b7e100
COUNT:          equ     $b7e1f0

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      hl, handler
        ld      de, HANDLER
        ld      bc, handler_end - handler
        ldir

        ld      hl, HANDLER
        ld      c, 0
        ld      a, mos_setkbvector
        rst.lil $08

        ld      hl, msg
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

handler:
        push    af
        ld      a, (COUNT)
        inc     a
        ld      (COUNT), a
        pop     af

        ret
handler_end:

msg:    db      "keyboard hook installed and left behind", 13, 10, 0
