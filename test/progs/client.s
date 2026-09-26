; client: a hub client for the tests. The first letter of its argument picks
; what it does:
;
;   c   Add one to a counter kept in a hub block and print it. Until it
;       reaches 50, open a frame whose only job is the continuation "client c"
;       -- the program chaining to itself.
;   o   Outer: open a frame with "client i" and "Echo outer-second", and the
;       continuation "client O".
;   i   Inner, run by outer: open a frame with "Echo inner-job" and the
;       continuation "client I". Its work must all come before outer-second.
;   I   Inner's continuation: print "inner back".
;   O   Outer's continuation: print "outer back".
;   f   Open a frame with "fail" (stop on error), "Echo SHOULD-NOT-RUN", and
;       the continuation "client F".
;   F   Print which job stopped the frame and its result.
;
; Without hub it prints "no hub" and returns.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "hub.inc"
        ORG     $40000

        jp      start
        ALIGN   64
        db      "MOS", 0, 1

start:
        push    ix
        push    iy
        push    hl
        call    find_hub
        pop     hl
        jr      c, @found
        ld      hl, msg_nohub
        call    print
        jr      finish

@found:
        call    skip_spaces
        ld      a, (hl)
        cp      a, 'c'
        jr      z, count
        cp      a, 'o'
        jp      z, outer
        cp      a, 'i'
        jp      z, inner
        cp      a, 'I'
        jp      z, inner_back
        cp      a, 'O'
        jp      z, outer_back
        cp      a, 'f'
        jp      z, failing
        cp      a, 'F'
        jp      z, failed

finish:
        pop     iy
        pop     ix
        ld      hl, 0

        ret

count:
        ld      hl, tag_cnt
        ld      bc, 1
        ld      a, HUB_BLOCK
        call    hub
        ld      a, (hl)
        inc     a
        ld      (hl), a
        push    af
        ld      hl, msg_count
        call    print
        pop     af
        push    af
        call    print_u8
        call    newline
        pop     af
        cp      a, 50
        jr      nc, @done

        ld      hl, tag_cnt
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_count
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

@done:
        ld      hl, msg_count_done
        call    print
        jp      finish

outer:
        ld      hl, msg_outer
        call    print
        ld      hl, tag_out
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_inner
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_outer_second
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_outer_back
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

inner:
        ld      hl, msg_inner
        call    print
        ld      hl, tag_in
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_inner_job
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_inner_back
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

inner_back:
        ld      hl, msg_inner_back
        call    print
        jp      finish

outer_back:
        ld      hl, msg_outer_back
        call    print
        jp      finish

failing:
        ld      hl, tag_fail
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_fail
        ld      c, HUB_STOP_ON_ERROR
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_not_run
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_failed
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

failed:
        ld      hl, msg_failed_job
        call    print
        ld      a, HUB_FAILED_JOB
        call    hub
        ld      a, l
        call    print_u8
        ld      hl, msg_result
        call    print
        ld      a, HUB_LAST_RESULT
        call    hub
        ld      a, l
        call    print_u8
        call    newline
        jp      finish

; find_hub: carry set if hub is running and its header is one we know, with
; the header's address in (api).
find_hub:
        ld      hl, v_api
        ld      ix, api
        ld      de, 3
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        or      a, a
        ret     nz                      ; no variable: carry clear from the or

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
        jr      nz, @no
        scf

        ret

@no:
        or      a, a

        ret

; hub: call the API entry at offset A, with the arguments in HL and BC.
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
        or      a, a
        ret     z

; A refused call is a test failure, and must not pass silently: say so.
        push    hl
        push    af
        ld      hl, msg_refused
        call    print
        pop     af
        push    af
        call    print_u8
        call    newline
        pop     af
        pop     hl

        ret

@go:
        jp      (iy)

skip_spaces:
        ld      a, (hl)
        cp      a, ' '
        ret     nz
        inc     hl
        jr      skip_spaces

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

        jp      print

newline:
        ld      hl, crlf

print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

api:            dl      0
digits:         db      0, 0, 0, 0
v_api:          db      "Hub$API", 0
tag_cnt:        db      "CNT "
tag_out:        db      "OUT "
tag_in:         db      "IN  "
tag_fail:       db      "FAIL"
cmd_count:      db      "client c", 0
cmd_inner:      db      "client i", 0
cmd_outer_second: db    "Echo outer-second", 0
cmd_outer_back: db      "client O", 0
cmd_inner_job:  db      "Echo inner-job", 0
cmd_inner_back: db      "client I", 0
cmd_fail:       db      "fail", 0
cmd_not_run:    db      "Echo SHOULD-NOT-RUN", 0
cmd_failed:     db      "client F", 0
msg_nohub:      db      "no hub", 13, 10, 0
msg_refused:    db      "hub refused a call: ", 0
msg_count:      db      "count ", 0
msg_count_done: db      "count done", 13, 10, 0
msg_outer:      db      "outer", 13, 10, 0
msg_inner:      db      "inner", 13, 10, 0
msg_inner_back: db      "inner back", 13, 10, 0
msg_outer_back: db      "outer back", 13, 10, 0
msg_failed_job: db      "failed job ", 0
msg_result:     db      ", result ", 0
crlf:           db      13, 10, 0
