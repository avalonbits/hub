; reset: what Ctrl-Alt-Del does -- jump to address 0, a warm reset. MOS keeps
; RAM across it and runs autoexec again.

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
        jp      0

msg:    db      "resetting the machine", 13, 10, 0
