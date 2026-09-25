; kbprobe: report whether MOS still has a user keyboard hook installed.
;
; MOS has no call that reads the hook back, so this reads _user_kbvector
; directly. 0xBC42B is its address in the MOS 3.0.2 firmware the tests boot
; (fab-agon-emulator 1.2.4, firmware/mos_platform.map). A test tool only:
; nothing else should depend on that address.

        ASSUME  ADL=1
        ORG     $40000

USER_KBVECTOR:  equ     $bc42b

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        ld      hl, (USER_KBVECTOR)
        ld      de, 0
        or      a, a
        sbc     hl, de
        ld      hl, msg_clear
        jr      z, @say
        ld      hl, msg_set

@say:
        ld      bc, 0
        xor     a, a
        rst.lil $18
        ld      hl, 0

        ret

msg_clear:      db      "kbvector: clear", 13, 10, 0
msg_set:        db      "kbvector: SET", 13, 10, 0
