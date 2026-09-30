; scrmode: set MOS's note of the screen mode (sysvar_scrMode) to the digit
; given, without changing the mode. The CLI emulator's stand-in VDP never
; reports a mode, so this is how a test gives hub's prompt a mode to note.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        push    ix
        ld      a, (hl)
        sub     a, '0'
        ld      c, a
        ld      a, mos_sysvars
        rst.lil $08
        ld      (ix+sysvar_scrMode), c
        pop     ix
        ld      hl, 0

        ret
