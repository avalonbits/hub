; bigmos: an 8 KB moslet. MOS loads it at 0xB0000, so it covers hub's shell
; and the start of the client blocks at 0xB1000 -- the way nano (6.5 KB)
; does. The padding is real bytes, so the load writes all of it.

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

msg:    db      "bigmos: 8 KB over the shell and the blocks", 13, 10, 0

        blkb    8192, $aa
