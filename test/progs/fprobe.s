; fprobe: count how many files can be opened, out of MOS's eight handles.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      b, 8
        ld      d, 0

@open:
        push    bc
        push    de
        ld      hl, name
        ld      c, fa_read
        ld      a, mos_fopen
        rst.lil $08
        pop     de
        pop     bc
        or      a, a
        jr      z, @next
        inc     d

@next:
        djnz    @open

        ld      a, d
        add     a, '0'
        ld      (digit), a

        ld      c, 0
        ld      a, mos_fclose
        rst.lil $08

        ld      hl, msg
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

name:   db      "/bin/hello.bin", 0
msg:    db      "free handles: "
digit:  db      "?", 13, 10, 0
