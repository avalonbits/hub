; leak: open three files and return without closing them.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      b, 3

@open:
        push    bc
        ld      hl, name
        ld      c, fa_read
        ld      a, mos_fopen
        rst.lil $08
        pop     bc
        djnz    @open

        ld      hl, msg
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

name:   db      "/bin/hello.bin", 0
msg:    db      "leaked three open files", 13, 10, 0
