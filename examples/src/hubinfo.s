; hubinfo: say whether hub is running, which API it offers, and how many
; frames are open -- written with zap, using hub.inc.
;
;       hub API 0.4, 9 calls, 0 frames open
;
; What it shows: finding hub from assembly. Read the Number variable Hub$API
; with MOS's readvarval, check that the variable it answers for is really
; Hub$API (MOS 3.0.2 answers for a neighbouring one when it is missing), check
; the header's magic, then call an entry by its offset from the header.

        ASSUME  ADL=1
        INCLUDE "hub.inc"
        ORG     $40000

mos_readvarval: equ     $31

        jp      start
        ALIGN   64
        db      "MOS", 0, 1             ; MOS header: version 0, ADL

start:
        push    ix
        push    iy
        call    find_hub
        jr      c, @found
        ld      hl, msg_none
        call    print
        jr      @done

@found:
        ld      iy, (api)
        ld      hl, msg_api
        call    print
        ld      a, (iy+HUB_MAJOR)
        call    print_u8
        ld      hl, msg_dot
        call    print
        ld      iy, (api)
        ld      a, (iy+HUB_MINOR)
        call    print_u8
        ld      hl, msg_calls
        call    print
        ld      iy, (api)
        ld      a, (iy+HUB_COUNT)
        call    print_u8
        ld      hl, msg_depth
        call    print
        ld      a, HUB_DEPTH
        call    hub
        ld      a, l
        call    print_u8
        ld      hl, msg_frames
        call    print

@done:
        pop     iy
        pop     ix
        ld      hl, 0

        ret

; find_hub: carry set if hub is running and its header is one this program
; knows, with the header's address in (api).
find_hub:
        ld      hl, v_api
        ld      ix, api
        ld      de, 3
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        or      a, a
        ret     nz                      ; no variable: carry clear

        ld      hl, v_api               ; the name it matched, in IY

@name:
        ld      a, (iy+0)
        xor     a, (hl)
        and     a, $df                  ; case doesn't matter
        jr      nz, @no
        ld      a, (hl)
        inc     hl
        inc     iy
        or      a, a
        jr      nz, @name

        ld      iy, (api)
        ld      a, (iy+HUB_MAGIC)
        cp      a, 'H'
        jr      nz, @no
        ld      a, (iy+HUB_MAGIC+1)
        cp      a, 'U'
        jr      nz, @no
        ld      a, (iy+HUB_MAGIC+2)
        cp      a, 'B'
        jr      nz, @no
        ld      a, (iy+HUB_MAJOR)
        or      a, a
        jr      nz, @no                 ; a major version this doesn't know
        scf

        ret

@no:
        or      a, a

        ret

; hub: call the API entry at offset A, with its arguments in HL and BC. The
; entry's address goes in IY and `call @go` jumps there, so the entry returns
; here; it keeps IX and IY.
hub:
        push    hl
        ld      hl, (api)
        ld      de, 0
        ld      e, a
        add     hl, de
        push    hl
        pop     iy
        pop     hl
        call    @go

        ret

@go:
        jp      (iy)

; print_u8: A in decimal.
print_u8:
        ld      hl, digits + 3
        ld      (hl), 0
        ld      b, 10

@next:
        dec     hl
        ld      c, 0

@div:
        cp      a, b
        jr      c, @digit
        sub     a, b
        inc     c
        jr      @div

@digit:
        add     a, '0'
        ld      (hl), a
        ld      a, c
        or      a, a
        jr      nz, @next

print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

api:            dl      0
digits:         db      0, 0, 0, 0
v_api:          db      "Hub$API", 0
msg_none:       db      "hub is not running", 13, 10, 0
msg_api:        db      "hub API ", 0
msg_dot:        db      ".", 0
msg_calls:      db      ", ", 0
msg_depth:      db      " calls, ", 0
msg_frames:     db      " frames open", 13, 10, 0
