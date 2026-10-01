; hub_glue.s -- the C side of the hub client API (include/hub.h).
;
; Assemble with `zap hub_glue.s hub_glue.o -f elf` and link into an agondev
; program (as libhub.a).
;
; hub's API takes its arguments in registers and returns a status in A and a
; value in HL (src/hub.inc). C passes arguments on the stack -- the first at
; (sp+3), three bytes each -- and expects an int back in HL. Each function
; here moves its arguments into place and enters the API through `api`, which
; jumps to the entry so that the API returns straight to the C caller; those
; that return a status convert A to an int on the way back.
;
; C may keep its frame pointer in IX, and hub's API preserves IX and IY, so
; nothing here needs saving except around the MOS call in hub_present.

        ASSUME  ADL=1
        INCLUDE "hub.inc"

        XDEF    _hub_present, _hub_enter, _hub_push, _hub_return_to
        XDEF    _hub_last_result, _hub_failed_job, _hub_block, _hub_depth
        XDEF    _hub_resumed, _hub_user_screen

mos_readvarval: equ     $31
HUB_ERR_ABSENT: equ     255

        SEGMENT CODE

; bool hub_present(void)
;
; Read Hub$API into hub_api, then check the header it points at. Anything
; wrong leaves hub_api at 0, which every other call checks.
_hub_present:
        push    ix
        ld      hl, 0
        ld      (hub_api), hl
        ld      hl, v_api
        ld      ix, hub_api
        ld      de, 3
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        pop     ix
        or      a, a
        jr      nz, @absent

; readvarval answers for a neighbouring variable when the one asked for
; doesn't exist (MOS 3.0.2's readVarVal), so check the name it matched --
; returned in IY -- before trusting the value.
        ld      hl, v_api

@name:
        ld      a, (iy+0)
        xor     a, (hl)
        and     a, $df
        jr      nz, @absent
        ld      a, (hl)
        inc     hl
        inc     iy
        or      a, a
        jr      nz, @name

        ld      iy, (hub_api)
        ld      a, (iy+HUB_MAGIC)
        cp      a, 'H'
        jr      nz, @absent
        ld      a, (iy+HUB_MAGIC+1)
        cp      a, 'U'
        jr      nz, @absent
        ld      a, (iy+HUB_MAGIC+2)
        cp      a, 'B'
        jr      nz, @absent
        ld      a, (iy+HUB_MAJOR)
        or      a, a
        jr      nz, @absent
        ld      a, 1

        ret

@absent:
        ld      hl, 0
        ld      (hub_api), hl
        xor     a, a

        ret

; int hub_enter(const char tag[4])
_hub_enter:
        ld      iy, 0
        add     iy, sp
        ld      hl, (iy+3)
        ld      a, HUB_ENTER
        call    api
        jr      status

; int hub_push(const char *cmd, unsigned char flags)
_hub_push:
        ld      iy, 0
        add     iy, sp
        ld      hl, (iy+3)
        ld      c, (iy+6)
        ld      a, HUB_PUSH
        call    api
        jr      status

; int hub_return_to(const char *cmd)
_hub_return_to:
        ld      iy, 0
        add     iy, sp
        ld      hl, (iy+3)
        ld      a, HUB_RETURN_TO
        call    api
        jr      status

; int hub_last_result(void), int hub_failed_job(void), int hub_depth(void),
; int hub_resumed(void):
; the API's HL is already the int C wants.
_hub_last_result:
        ld      a, HUB_LAST_RESULT
        jr      value

_hub_failed_job:
        ld      a, HUB_FAILED_JOB
        jr      value

_hub_depth:
        ld      a, HUB_DEPTH
        jr      value

_hub_resumed:
        ld      a, HUB_RESUMED
        jr      value

; int hub_user_screen(void)
;
; -1 without hub, and with a hub older than 0.4, whose table has no entry
; this far down: calling past HUB_COUNT entries would jump into whatever
; follows the table.
_hub_user_screen:
        ld      hl, (hub_api)
        ld      de, 0
        or      a, a
        sbc     hl, de
        jr      z, @none
        push    hl
        pop     iy
        ld      a, (iy+HUB_COUNT)
        cp      a, (HUB_USER_SCREEN - HUB_ENTER) / 4 + 1
        jr      c, @none
        ld      a, HUB_USER_SCREEN
        jr      api

@none:
        ld      hl, -1

        ret

; void *hub_block(const char tag[4], size_t size)
_hub_block:
        ld      iy, 0
        add     iy, sp
        ld      hl, (iy+3)
        ld      bc, (iy+6)
        ld      a, HUB_BLOCK

; value: call entry A, returning its HL; 0 when hub is absent.
value:
        call    api
        or      a, a
        ret     z
        cp      a, HUB_ERR_ABSENT
        ret     nz
        ld      hl, 0

        ret

; status: turn the API's status in A into the int C expects in HL.
status:
        ld      hl, 0
        ld      l, a

        ret

; api: jump to the API entry at offset A, with the arguments in HL and BC.
; The entry's address goes on the stack and `ret` jumps to it, so the entry
; returns to api's caller. Without hub, return A = HUB_ERR_ABSENT.
api:
        push    hl
        ld      hl, (hub_api)
        ld      de, 0
        or      a, a
        sbc     hl, de
        jr      z, @absent
        ld      e, a
        add     hl, de
        ex      (sp), hl                ; the stack holds the entry, HL the argument

        ret

@absent:
        pop     hl
        ld      a, HUB_ERR_ABSENT

        ret

        SEGMENT RODATA

v_api:  db      "Hub$API", 0

        SEGMENT BSS

hub_api: ds     3
