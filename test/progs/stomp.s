; stomp: a moslet. MOS loads it at 0xB0000, over chain's shell.

        ASSUME  ADL=1
        ORG     $b0000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      hl, msg
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

msg:    db      "stomp: a moslet ran over the shell", 13, 10, 0
