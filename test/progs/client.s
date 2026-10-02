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
;   b   Set the byte in block "KEEP" to 42.
;   B   Print the byte in block "KEEP".
;   m   Run the moslet bigmos itself, through OSCLI -- as mc runs nano -- then
;       print the byte in "KEEP" again. hub_block repairs first.
;   r   Open a frame with "reset" (which resets the machine), then
;       "Echo NOT-AFTER-RESET", and the continuation "client R".
;   R   Print whether the frame was cut short by a reset, and how.
;   t   Run the rest of the argument as a command, stop-on-error, then
;       "Echo NOT-AFTER-TOOL", with the continuation "client T" -- a tool
;       run as an editor would run it.
;   T   Print the result the tool's frame ended with, and the failed job.
;   p   Open a frame whose only job is the continuation "client q", so that
;       q runs as a job, as an IDE resumed by its continuation does.
;   q   Open a frame with seven jobs, "Echo q1" to "Echo q7", and the
;       continuation "client Q": all MAX_JOBS slots, while q itself runs as a
;       job.
;   Q   Print "queue back".
;   u   Note screen mode 1 in MOS's sysvars, as an IDE that changed the mode
;       would leave it, then open a frame with "fail" as a user program that
;       pauses after (HUB_USER_PROGRAM | HUB_PAUSE_AFTER, not stop on error),
;       and the continuation "client U".
;   U   Print the frame's last result and failed job, and what
;       hub_user_screen says.
;   S   Print what hub_user_screen says.
;   g   Ask for block "KEEP" (1 byte, holding 42 from b) with 200 bytes:
;       other blocks follow it, so it moves. Print its first and last
;       bytes and whether it moved.
;   h   Make block "GROW" of 1 byte holding 7 -- the last block -- then ask
;       for 100: it grows in place. Print the same.
;   n   Start a chain of two rounds: a frame with "Echo n-round" and the
;       continuation "client N".
;   N   The continuation. The first time, queue the next round the same way
;       and return 19 -- a middle round's result, which must not count; the
;       second time, print "n-chain done" and return 0, the chain's result.
;   X   Ask for "GROW" with 30000 bytes, more than the area holds: print
;       whether it was refused, and "GROW"'s first byte after.
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
        jp      finish

@found:
        call    skip_spaces
        ld      a, (hl)
        cp      a, 'c'
        jp      z, count
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
        cp      a, 'b'
        jp      z, keep_set
        cp      a, 'B'
        jp      z, keep_show
        cp      a, 'm'
        jp      z, moslet
        cp      a, 'r'
        jp      z, resetting
        cp      a, 'R'
        jp      z, reset_back
        cp      a, 't'
        jp      z, tool
        cp      a, 'T'
        jp      z, tool_back
        cp      a, 'p'
        jp      z, queue_pre
        cp      a, 'q'
        jp      z, queue_full
        cp      a, 'Q'
        jp      z, queue_back
        cp      a, 'u'
        jp      z, user_prog
        cp      a, 'U'
        jp      z, user_back
        cp      a, 'S'
        jp      z, user_screen
        cp      a, 'g'
        jp      z, grow_moved
        cp      a, 'h'
        jp      z, grow_last
        cp      a, 'n'
        jp      z, chain_start
        cp      a, 'N'
        jp      z, chain_next
        cp      a, 'X'
        jp      z, grow_too_big

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

keep_set:
        call    keep
        ld      (hl), 42
        ld      hl, msg_keep_set
        call    print
        jp      finish

keep_show:
        ld      hl, msg_keep
        call    print
        call    keep
        ld      a, (hl)
        call    print_u8
        call    newline
        jp      finish

moslet:
        ld      hl, cmd_bigmos
        ld      a, mos_oscli
        rst.lil $08
        ld      hl, msg_after
        call    print
        call    keep
        ld      a, (hl)
        call    print_u8
        call    newline
        jp      finish

; keep: HL = block "KEEP", one byte.
keep:
        ld      hl, tag_keep
        ld      bc, 1
        ld      a, HUB_BLOCK
        jp      hub

grow_moved:
        call    keep
        ld      (old_addr), hl
        ld      hl, tag_keep
        ld      bc, 200
        ld      a, HUB_BLOCK
        call    hub
        ld      de, 199
        call    grown
        jp      finish

grow_last:
        ld      hl, tag_grow
        ld      bc, 1
        ld      a, HUB_BLOCK
        call    hub
        ld      (hl), 7
        ld      (old_addr), hl
        ld      hl, tag_grow
        ld      bc, 100
        ld      a, HUB_BLOCK
        call    hub
        ld      de, 99
        call    grown
        jp      finish

chain_start:
        ld      hl, tag_ncnt
        ld      bc, 1
        ld      a, HUB_BLOCK
        call    hub
        ld      (hl), 0
        call    chain_round
        jp      finish

chain_next:
        ld      hl, tag_ncnt
        ld      bc, 1
        ld      a, HUB_BLOCK
        call    hub
        inc     (hl)
        ld      a, (hl)
        cp      a, 2
        jr      nc, @last
        call    chain_round
        pop     iy                      ; as finish, but returning 19
        pop     ix
        ld      hl, 19

        ret

@last:
        ld      hl, msg_chain_done
        call    print
        jp      finish

; chain_round: a frame with "Echo n-round" and the continuation "client N".
chain_round:
        ld      hl, tag_ncnt
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_n_round
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_n_next
        ld      a, HUB_RETURN_TO
        jp      hub

grow_too_big:
        ld      hl, tag_grow
        ld      bc, 30000
        ld      a, HUB_BLOCK
        call    hub_quiet               ; a refusal is what is wanted here
        ld      de, msg_too_big_given
        or      a, a
        jr      z, @said
        ld      de, msg_too_big_refused

@said:
        ex      de, hl
        call    print
        ld      hl, tag_grow
        ld      bc, 100
        ld      a, HUB_BLOCK
        call    hub
        ld      a, (hl)
        call    print_u8
        call    newline
        jp      finish

; grown: HL = a block just grown, DE = its last byte's offset. Print
; "grown: first F, last L, moved" (or "in place", against old_addr).
grown:
        push    hl
        add     hl, de
        ld      a, (hl)
        ld      (grow_last_byte), a
        pop     hl
        push    hl
        ld      hl, msg_grown
        call    print
        pop     hl
        push    hl
        ld      a, (hl)
        call    print_u8
        ld      hl, msg_grown_last
        call    print
        ld      a, (grow_last_byte)
        call    print_u8
        pop     hl
        ld      de, (old_addr)
        or      a, a
        sbc     hl, de
        ld      hl, msg_in_place
        jr      z, @where
        ld      hl, msg_moved

@where:
        call    print
        jp      newline

resetting:
        ld      hl, tag_rst
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_reset
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_not_after
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_reset_back
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

reset_back:
        ld      hl, msg_resumed
        call    print
        ld      a, HUB_RESUMED
        call    hub
        ld      a, l
        call    print_u8
        ld      hl, msg_failed_job2
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

tool:
        inc     hl
        call    skip_spaces
        push    hl
        ld      hl, tag_tool
        ld      a, HUB_ENTER
        call    hub
        pop     hl
        ld      c, HUB_STOP_ON_ERROR
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_not_after_tool
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_tool_back
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

tool_back:
        ld      hl, msg_tool
        call    print
        ld      a, HUB_LAST_RESULT
        call    hub
        ld      a, l
        call    print_u8
        ld      hl, msg_failed_job2
        call    print
        ld      a, HUB_FAILED_JOB
        call    hub
        ld      a, l
        call    print_u8
        call    newline
        jp      finish

queue_pre:
        ld      hl, tag_queue
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_queue_full
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

queue_full:
        ld      hl, tag_queue
        ld      a, HUB_ENTER
        call    hub
        ld      b, '1'

@push:
        push    bc
        ld      a, b
        ld      (cmd_q_digit), a
        ld      hl, cmd_q
        ld      c, 0
        ld      a, HUB_PUSH
        call    hub
        pop     bc
        inc     b
        ld      a, b
        cp      a, '8'
        jr      nz, @push
        ld      hl, cmd_queue_back
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

queue_back:
        ld      hl, msg_queue_back
        call    print
        jp      finish

user_prog:
        ld      a, mos_sysvars
        rst.lil $08
        ld      (ix+sysvar_scrMode), 1
        ld      hl, tag_user
        ld      a, HUB_ENTER
        call    hub
        ld      hl, cmd_fail
        ld      c, HUB_USER_PROGRAM | HUB_PAUSE_AFTER
        ld      a, HUB_PUSH
        call    hub
        ld      hl, cmd_user_back
        ld      a, HUB_RETURN_TO
        call    hub
        jp      finish

user_back:
        ld      hl, msg_user_back
        call    print
        ld      a, HUB_LAST_RESULT
        call    hub
        ld      a, l
        call    print_u8
        ld      hl, msg_failed_job2
        call    print
        ld      a, HUB_FAILED_JOB
        call    hub
        ld      a, l
        call    print_u8
        call    newline

user_screen:
        ld      hl, msg_user_screen
        call    print
        ld      a, HUB_USER_SCREEN
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

; readvarval answers for a neighbouring variable when the one asked for
; doesn't exist (MOS 3.0.2's readVarVal), so check the name it matched --
; returned in IY -- before trusting the value.
        ld      hl, v_api

@name:
        ld      a, (iy+0)
        xor     a, (hl)
        and     a, $df
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

; hub_quiet: as hub, for a call that is meant to be refused.
hub_quiet:
        push    hl
        ld      hl, (api)
        ld      de, 0
        ld      e, a
        add     hl, de
        push    hl
        pop     iy
        pop     hl
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
tag_keep:       db      "KEEP"
tag_grow:       db      "GROW"
tag_ncnt:       db      "NCNT"
cmd_n_round:    db      "Echo n-round", 0
cmd_n_next:     db      "client N", 0
msg_chain_done: db      "n-chain done", 13, 10, 0
old_addr:       dl      0
grow_last_byte: db      0
msg_grown:      db      "grown: first ", 0
msg_grown_last: db      ", last ", 0
msg_in_place:   db      ", in place", 0
msg_moved:      db      ", moved", 0
msg_too_big_given: db   "too big: given; first ", 0
msg_too_big_refused: db "too big: refused; first ", 0
tag_tool:       db      "TOOL"
cmd_not_after_tool: db  "Echo NOT-AFTER-TOOL", 0
cmd_tool_back:  db      "client T", 0
msg_tool:       db      "tool result ", 0
tag_rst:        db      "RST "
cmd_bigmos:     db      "bigmos", 0
cmd_reset:      db      "reset", 0
cmd_not_after:  db      "Echo NOT-AFTER-RESET", 0
cmd_reset_back: db      "client R", 0
msg_keep_set:   db      "keep set 42", 13, 10, 0
msg_keep:       db      "keep ", 0
msg_after:      db      "after moslet: ", 0
msg_resumed:    db      "resumed ", 0
msg_failed_job2: db     ", failed job ", 0
msg_refused:    db      "hub refused a call: ", 0
msg_count:      db      "count ", 0
tag_queue:      db      "QUE "
cmd_queue_full: db      "client q", 0
cmd_queue_back: db      "client Q", 0
cmd_q:          db      "Echo q"
cmd_q_digit:    db      "0", 0
msg_queue_back: db      "queue back", 13, 10, 0
tag_user:       db      "USER"
cmd_user_back:  db      "client U", 0
msg_user_back:  db      "user back: last ", 0
msg_user_screen: db     "user screen ", 0
msg_count_done: db      "count done", 13, 10, 0
msg_outer:      db      "outer", 13, 10, 0
msg_inner:      db      "inner", 13, 10, 0
msg_inner_back: db      "inner back", 13, 10, 0
msg_outer_back: db      "outer back", 13, 10, 0
msg_failed_job: db      "failed job ", 0
msg_result:     db      ", result ", 0
crlf:           db      13, 10, 0
