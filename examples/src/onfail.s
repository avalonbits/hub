; onfail: run a command, and if it fails, run another.
;
;       onfail acc -c prog.c ; aed prog.c
;
; Written in assembly with zap, calling the hub library (libhub.a) as C does:
; _main gets argc and argv from the start-up code, each library function is
; called with its arguments pushed right to left and popped afterwards, and
; the library keeps only IX and SP. See retry.s for how to build it with acc
; or agondev; this one builds the same way.
;
; What it does with hub: it queues the first command in a frame, without
; HUB_STOP_ON_ERROR -- the continuation runs either way -- and keeps the
; second command in a hub block. The continuation, "onfail -r", reads the
; first command's result with hub_last_result, and if it failed, opens a
; frame of its own and queues the second command, as a user program: it is
; usually something to look at, like an editor on the file that failed.

        ASSUME  ADL=1

        XDEF    _main
        XREF    _hub_present, _hub_block, _hub_enter, _hub_push
        XREF    _hub_return_to, _hub_last_result

HUB_CMD_MAX:      equ   93      ; from hub.h
HUB_USER_PROGRAM: equ   2       ; from hub.h
FAILED:           equ   100     ; a failure; MOS takes 1, 4 and 5 as its own

; The state kept in the "ONFL" block between runs.
ST_SIZE:        equ     0       ; 3: STATE_LEN, to recognise our own block
ST_FIRST:       equ     3       ; the command to run
ST_THEN:        equ     ST_FIRST + HUB_CMD_MAX + 1  ; and the one if it fails
STATE_LEN:      equ     ST_THEN + HUB_CMD_MAX + 1

        SEGMENT CODE

; int main(int argc, char **argv)
_main:
        push    ix
        ld      ix, 0
        add     ix, sp                  ; (ix+6) = argc, (ix+9) = argv

        call    _hub_present            ; bool, in A
        or      a, a
        jr      nz, @hub
        ld      hl, msg_nohub
        jp      fail

@hub:
        ld      hl, (ix+6)
        ld      a, l
        cp      a, 2
        jp      nz, start
        ld      a, 1
        call    arg                     ; HL = argv[1]
        ld      a, (hl)
        cp      a, '-'
        jp      nz, start               ; "onfail -r": the first has ended

; The continuation: if the first command failed, queue the second.
again:
        call    _hub_last_result        ; int, in HL
        ld      a, h
        or      a, l
        jp      z, ok                   ; it worked: nothing to do

        call    state                   ; IY = the block, carry if none
        jp      c, lost
        ld      hl, (iy+ST_SIZE)
        ld      de, STATE_LEN
        or      a, a
        sbc     hl, de
        jp      nz, lost                ; another program's block

        ld      hl, tag                 ; hub_enter("ONFL")
        push    hl
        call    _hub_enter
        pop     hl

        call    state                   ; IY again: the call may change it
        ld      hl, HUB_USER_PROGRAM    ; hub_push(then, HUB_USER_PROGRAM)
        push    hl
        lea     hl, iy+ST_THEN
        push    hl
        call    _hub_push
        pop     hl
        pop     hl
        jr      ok                      ; it runs once this program ends

; "onfail <command> ; <command>": keep both, then queue the first.
start:
        call    state
        jr      nc, @block
        ld      hl, msg_noroom
        jr      fail

@block:
        call    split                   ; A = 0 done, 1 usage, 2 too long
        or      a, a
        jr      z, @queue
        ld      hl, msg_usage
        dec     a
        jr      z, fail
        ld      hl, msg_long
        jr      fail

@queue:
        ld      hl, STATE_LEN
        ld      (iy+ST_SIZE), hl

        ld      hl, tag                 ; hub_enter("ONFL")
        push    hl
        call    _hub_enter
        pop     hl

        call    state                   ; hub_push(first, 0)
        ld      hl, 0
        push    hl
        lea     hl, iy+ST_FIRST
        push    hl
        call    _hub_push
        pop     hl
        pop     hl

        ld      hl, cmd_again           ; hub_return_to("onfail -r")
        push    hl
        call    _hub_return_to
        pop     hl

ok:
        ld      hl, 0

done:
        pop     ix

        ret

lost:
        ld      hl, msg_nostate

; fail: print the message at HL, and end with FAILED.
fail:
        call    print
        ld      hl, FAILED
        jr      done

; state: IY = the "ONFL" block, carry if hub has no room for it.
state:
        ld      hl, STATE_LEN
        push    hl
        ld      hl, tag
        push    hl
        call    _hub_block              ; void *, in HL; NULL if no room
        pop     de
        pop     de
        ld      a, h                    ; NULL? (blocks are in 0xB1000-
        or      a, l                    ; 0xB6FFF, so H or L is set)
        scf
        ret     z
        push    hl
        pop     iy
        or      a, a                    ; carry clear

        ret

; arg: HL = argv[A]. Each argv entry is a 3-byte pointer.
arg:
        ld      hl, 0
        ld      l, a
        ld      de, 0
        ld      e, a
        add     hl, de
        add     hl, de                  ; HL = 3 * A
        ld      de, (ix+9)
        add     hl, de
        ld      hl, (hl)

        ret

; split: the arguments before the ";" into ST_FIRST, those after into
; ST_THEN, each joined with spaces. A = 0 if both are there, 1 if one is
; missing, 2 if one is longer than HUB_CMD_MAX.
;
; In:   IY = the block.
split:
        ld      (block), iy
        lea     de, iy+ST_FIRST
        ld      b, 1                    ; argv[1] is the first word
        call    join                    ; up to the ";", B past it
        or      a, a
        ret     nz
        ld      iy, (block)
        lea     de, iy+ST_THEN
        call    join                    ; the rest
        or      a, a
        ret     nz

        ld      iy, (block)             ; both have something in them?
        ld      a, (iy+ST_FIRST)
        or      a, a
        jr      z, @missing
        ld      a, (iy+ST_THEN)
        or      a, a
        jr      z, @missing
        xor     a, a

        ret

@missing:
        ld      a, 1

        ret

; join: the arguments from argv[B] up to a ";" or the last, into DE,
; separated by spaces and zero-terminated. B ends past the ";".
; Out:  A = 0, or 2 if longer than HUB_CMD_MAX.
join:
        ld      c, HUB_CMD_MAX + 1      ; room left, the terminator included
        xor     a, a
        ld      (gap), a                ; no space before the first word

@word:
        ld      hl, (ix+6)              ; argc
        ld      a, b
        cp      a, l
        jr      nc, @end                ; no arguments left
        push    bc
        push    de
        call    arg                     ; HL = argv[B]
        pop     de
        pop     bc
        inc     b
        ld      a, (hl)
        cp      a, ';'
        jr      nz, @space
        inc     hl
        ld      a, (hl)
        dec     hl
        or      a, a
        jr      z, @end                 ; a ";" on its own ends this command

@space:
        ld      a, (gap)
        or      a, a
        jr      z, @chars
        ld      a, ' '
        ld      (de), a
        inc     de
        dec     c
        jr      z, @long

@chars:
        ld      a, 1
        ld      (gap), a

@char:
        ld      a, (hl)
        or      a, a
        jr      z, @word
        ld      (de), a
        inc     hl
        inc     de
        dec     c
        jr      z, @long
        jr      @char

@end:
        xor     a, a
        ld      (de), a

        ret

@long:
        ld      a, 2

        ret

; print: the zero-terminated string at HL, through MOS (RST 18h, BC = 0:
; up to the delimiter in A).
print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

        SEGMENT RODATA

tag:            db      "ONFL"
cmd_again:      db      "onfail -r", 0
msg_nohub:      db      "onfail: needs hub", 13, 10, 0
msg_usage:      db      "usage: onfail <command> ; <command if it fails>", 13, 10, 0
msg_noroom:     db      "onfail: hub has no room for its state", 13, 10, 0
msg_nostate:    db      "onfail: nothing to carry on with", 13, 10, 0
msg_long:       db      "onfail: a command is longer than 93 characters", 13, 10, 0

        SEGMENT BSS

block:          ds      3       ; the block's address, while splitting
gap:            ds      1       ; 1 once a word is in: a space comes first
