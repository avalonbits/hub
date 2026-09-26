; vecprobe: report whether interrupt vector $5E points into program memory
; (0x40000-0xAFFFF, left behind by a program) or elsewhere (MOS's own).
;
; MOS can only set a vector, returning the old one, so this sets it to its
; own handler and straight back, with interrupts off in between.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        di
        ld      e, $5e
        ld      hl, handler
        ld      a, mos_setintvector
        rst.lil $08                     ; HL = the vector as it was
        push    hl
        ld      e, $5e
        ld      a, mos_setintvector
        rst.lil $08                     ; put it back
        ei
        pop     hl

        ld      de, $40000
        or      a, a
        sbc     hl, de
        jr      c, @mos
        ld      de, $b0000 - $40000
        or      a, a
        sbc     hl, de
        jr      nc, @mos
        ld      hl, msg_user
        jr      @say

@mos:
        ld      hl, msg_mos

@say:
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

handler:
        ei

        ret

msg_user:       db      "vector: user", 13, 10, 0
msg_mos:        db      "vector: mos", 13, 10, 0
