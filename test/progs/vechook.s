; vechook: point interrupt vector $5E at this program and return without
; putting it back. $5E is the last of MOS's 48 vectors, and nothing uses it,
; so the handler is never called; what matters is only where MOS points after
; this program has gone.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      e, $5e
        ld      hl, handler
        ld      a, mos_setintvector
        rst.lil $08

        ld      hl, msg
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

handler:
        ei

        ret

msg:    db      "interrupt vector changed and left behind", 13, 10, 0
