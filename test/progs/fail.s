; fail: return 19, which MOS reports as "Invalid parameter".
;
; Not 1, 4 or 5: mos_exec turns those into "Invalid command" when a program
; returns them, at its own prompt as under chain.

        ASSUME  ADL=1
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      hl, msg
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 19

        ret

msg:    db      "failing on purpose", 13, 10, 0
