; retry: run a command until it works, at most a given number of times.
;
;       retry 3 acc -c prog.c
;
; Written in assembly with zap, calling the hub library (libhub.a) the way C
; does -- so it shows how an assembly program uses the library:
;
;   - The program is _main, called by the C start-up code of acc or agondev
;     with argc and argv on the stack, like any C program's main.
;   - A library function is called as from C: XREF it, push its arguments
;     right to left, three bytes each, call it, and pop them afterwards. The
;     result comes back in A (a bool) or HL (an int or a pointer).
;   - The library keeps IX and SP and may change every other register -- IY
;     included, which its glue uses -- so IX holds this program's stack
;     frame, and the block's address in IY is fetched again after each call.
;
; What it does with hub: each try queues the command in a frame of its own,
; with "retry -r" as the continuation, and keeps its count in a hub block
; between runs. The continuation reads the command's result with
; hub_last_result and decides whether to go again.
;
; Build it for acc (on the Agon, or with acc on a PC):
;       zap retry.s retry.o -f acc
;       acc retry.o /lib/acc/libhub.a -o retry.bin
; or for agondev: assemble an ELF object, and name it in the Makefile's LIBS,
; which agondev links ahead of its own start-up code, so the object is taken
; whole and its _main is there for the start-up code to call:
;       zap retry.s retry.o -f elf
;       make            (with an empty src/, and a Makefile of
;                        NAME=retry, the include of agondev's makefile,
;                        then LIBS := retry.o -lhub)

        ASSUME  ADL=1

        XDEF    _main
        XREF    _hub_present, _hub_block, _hub_enter, _hub_push
        XREF    _hub_return_to, _hub_last_result

HUB_CMD_MAX:    equ     93      ; from hub.h
FAILED:         equ     100     ; a failure; MOS takes 1, 4 and 5 as its own

; The state kept in the "RTRY" block between runs.
ST_SIZE:        equ     0       ; 3: STATE_LEN, to recognise our own block
ST_LEFT:        equ     3       ; 1: tries left
ST_DONE:        equ     4       ; 1: tries made
ST_CMD:         equ     5       ; the command, zero-terminated
STATE_LEN:      equ     ST_CMD + HUB_CMD_MAX + 1

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
        jr      nz, @first
        ld      a, 1
        call    arg                     ; HL = argv[1]
        ld      a, (hl)
        cp      a, '-'
        jr      z, again                ; "retry -r": a try has ended

@first:
        jp      start

; done: back to the start-up code with result HL.
done:
        pop     ix

        ret

; fail: print the message at HL, and end with FAILED.
fail:
        call    print
        ld      hl, FAILED
        jp      done

; again: the continuation. Count the try that has just ended, then go again
; or say how it went.
again:
        call    _hub_last_result        ; int, in HL
        ld      a, l
        ld      (result), a             ; results MOS reports fit in a byte
        call    state                   ; IY = the block, or carry
        jr      c, @lost
        ld      hl, (iy+ST_SIZE)
        ld      de, STATE_LEN
        or      a, a
        sbc     hl, de
        jr      z, @ours

@lost:
        ld      hl, msg_nostate         ; no block, or another program's
        jp      fail

@ours:
        inc     (iy+ST_DONE)
        dec     (iy+ST_LEFT)
        ld      a, (iy+ST_DONE)
        ld      (tries), a
        ld      a, (result)
        or      a, a
        jr      z, @worked
        ld      a, (iy+ST_LEFT)
        or      a, a
        jp      nz, round               ; tries left: once more

        ld      hl, msg_gave_up         ; "failed N times, last with R"
        call    print
        ld      a, (tries)
        call    print_u8
        ld      hl, msg_last
        call    print
        ld      a, (result)
        call    print_u8
        ld      hl, crlf
        jp      fail

@worked:
        ld      hl, msg_worked          ; "worked after N tries"
        call    print
        ld      a, (tries)
        call    print_u8
        ld      hl, msg_tries
        call    print
        ld      hl, 0
        jp      done

; start: "retry <times> <command ...>": keep the command and the count in the
; block, then the first try.
start:
        ld      hl, (ix+6)
        ld      a, l
        cp      a, 3
        jr      nc, @args
        ld      hl, msg_usage
        jp      fail

@args:
        call    state                   ; IY = the block
        jr      nc, @block
        ld      hl, msg_noroom
        jp      fail

@block:
        ld      a, 1
        call    arg
        call    parse_u8                ; A = the count, carry if bad
        jr      c, @usage
        or      a, a
        jr      z, @usage
        ld      (iy+ST_LEFT), a
        ld      (iy+ST_DONE), 0

        call    join                    ; ST_CMD = argv[2..] with spaces
        jr      nc, @mark
        ld      hl, msg_long
        jp      fail

@mark:
        ld      hl, STATE_LEN
        ld      (iy+ST_SIZE), hl
        jr      round

@usage:
        ld      hl, msg_usage
        jp      fail

; round: one try -- hub_enter("RTRY"), hub_push(command, 0),
; hub_return_to("retry -r") -- then end, and hub runs it.
round:
        ld      hl, tag
        push    hl
        call    _hub_enter
        pop     hl                      ; the caller takes its arguments off

        call    state                   ; IY again: the call may change it
        ld      hl, 0                   ; flags: none
        push    hl
        lea     hl, iy+ST_CMD
        push    hl
        call    _hub_push
        pop     hl
        pop     hl

        ld      hl, cmd_again
        push    hl
        call    _hub_return_to
        pop     hl

        ld      hl, 0
        jp      done

; state: IY = the "RTRY" block, carry if hub has no room for it. Asking for
; it again is cheap, and the address is the same each time.
state:
        ld      hl, STATE_LEN
        push    hl
        ld      hl, tag
        push    hl
        call    _hub_block              ; void *, in HL; NULL if no room
        pop     de
        pop     de
        ld      a, h                ; NULL? (blocks are in 0xB1000-0xB6FFF,
        or      a, l                ; so a block's H or L is never both 0)
        scf
        ret     z
        push    hl
        pop     iy
        or      a, a                ; carry clear

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

; join: ST_CMD = argv[2] ... argv[argc-1], separated by spaces; carry if it
; would be longer than HUB_CMD_MAX.
join:
        lea     de, iy+ST_CMD
        ld      c, HUB_CMD_MAX + 1      ; room left, the terminator included
        ld      b, 2                    ; the argument

@word:
        ld      a, b
        push    bc
        push    de
        call    arg
        pop     de
        pop     bc

@char:
        ld      a, (hl)
        or      a, a
        jr      z, @next
        ld      (de), a
        inc     hl
        inc     de
        dec     c
        jr      z, @long
        jr      @char

@next:
        inc     b
        ld      hl, (ix+6)
        ld      a, b
        cp      a, l
        jr      nc, @end                ; that was the last
        ld      a, ' '
        ld      (de), a
        inc     de
        dec     c
        jr      z, @long
        jr      @word

@end:
        xor     a, a
        ld      (de), a                 ; carry clear from the XOR

        ret

@long:
        scf

        ret

; parse_u8: A = the decimal number at HL, 0 to 255; carry if it isn't one.
parse_u8:
        ld      c, 0                    ; the value so far
        ld      a, (hl)
        or      a, a
        scf
        ret     z

@digit:
        ld      a, (hl)
        or      a, a
        jr      z, @done
        sub     a, '0'
        cp      a, 10
        ccf
        ret     c                       ; not a digit
        ld      b, a
        ld      a, c
        cp      a, 26
        ccf
        ret     c                       ; past 255 in a moment
        add     a, a                    ; A = value * 10 + digit
        ld      e, a
        add     a, a
        add     a, a
        add     a, e
        add     a, b
        ret     c
        ld      c, a
        inc     hl
        jr      @digit

@done:
        ld      a, c
        or      a, a                    ; carry clear

        ret

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

; print: the zero-terminated string at HL, through MOS (RST 18h, BC = 0:
; up to the delimiter in A).
print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

        SEGMENT RODATA

tag:            db      "RTRY"
cmd_again:      db      "retry -r", 0
crlf:           db      13, 10, 0
msg_nohub:      db      "retry: needs hub", 13, 10, 0
msg_usage:      db      "usage: retry <times> <command>", 13, 10, 0
msg_noroom:     db      "retry: hub has no room for its state", 13, 10, 0
msg_nostate:    db      "retry: nothing to carry on with", 13, 10, 0
msg_long:       db      "retry: the command is longer than 93 characters", 13, 10, 0
msg_worked:     db      "retry: worked after ", 0
msg_tries:      db      " tries", 13, 10, 0
msg_gave_up:    db      "retry: failed ", 0
msg_last:       db      " times, last with ", 0

        SEGMENT BSS

digits:         ds      4
result:         ds      1           ; the try's result
tries:          ds      1           ; tries made
