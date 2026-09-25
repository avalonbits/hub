; hello: print a line and return 0 -- the ordinary program chain runs.

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
        ld      hl, 0

        ret

msg:    db      "hello from a child", 13, 10, 0
