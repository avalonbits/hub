; shell/shells.s -- Nested shells: a HUB_SHELL job opens hub's prompt for the
; user, and `exit` there closes it.
;
; Part of the shell; hub.s includes it, in order.
;
; A program that wants to drop the user at the prompt and come back -- an
; IDE's "shell" key -- pushes a job with HUB_SHELL and sets its continuation
; as usual. When that job starts, it runs nothing: every job then waiting in
; the queue -- the continuation, and anything the frames below queued -- is
; held, and the core goes back to reading lines, from the prompt or a script.
; next_job runs only the jobs in front of the held ones, so whatever the user
; does there -- a program, a hub client opening frames of its own, a failure
; skipping to a continuation -- runs and finishes before them; skip_frame
; never reaches them either. `exit` closes the shell: the held jobs are let
; go, in their order, and the frame carries on to its continuation.
;
; The frames open below a shell are out of reach while it is open: CTL_FLOOR
; is their depth, and hub_push and hub_return_to find no open frame at or
; below it. Otherwise a program run in the shell that pushes without its own
; hub_enter -- or whose hub_enter was refused -- would add to the frame that
; opened the shell, and could give it a second continuation.
;
; Shells nest: a program run in one can open another. CTL_SHELL_STACK keeps
; each shell's outer CTL_HELD and CTL_FLOOR, so an `exit` gives back exactly
; the jobs and frames of its own shell. MAX_SHELLS of them, the room the
; control block has; shell_enter refuses past that.
;
; All of it lives in the control block, so a reset inside a shell keeps it:
; hub resumes still in the shell, with its jobs held, and `exit` still lets
; them go.

SHELL_FAILED:   equ     100             ; a shell refused: too deep

; shell_enter: open a nested shell, for the HUB_SHELL job that is starting.
;
; Out:  carry set: there is nothing for the core to run. CTL_RC = 0, or
;       SHELL_FAILED if shells are nested too deep (then nothing is held).
;       Clobbers everything a MOS call may.
shell_enter:
        ld      a, (CTL_SHELLS)
        cp      a, MAX_SHELLS
        jr      c, @room
        ld      hl, msg_too_deep
        call    print
        ld      hl, SHELL_FAILED
        jr      @result

@room:
        call    stack_slot              ; HL = this shell's slot
        ld      a, (CTL_HELD)
        ld      (hl), a                 ; the outer shell's held jobs,
        inc     hl
        ld      a, (CTL_FLOOR)
        ld      (hl), a                 ; and its floor
        ld      hl, CTL_SHELLS
        inc     (hl)
        ld      a, (CTL_NJOBS)
        ld      (CTL_HELD), a           ; everything waiting waits for exit,
        ld      a, (CTL_DEPTH)
        ld      (CTL_FLOOR), a          ; and every open frame is out of reach

        ld      hl, msg_shell_in        ; "hub: exit goes back to ADE"
        call    print
        call    print_tag
        ld      hl, crlf
        call    print
        ld      hl, 0

@result:
        ld      (CTL_RC), hl
        scf

        ret

; shell_exit: close the innermost shell, letting go of the jobs it held.
;
; Out:  carry set and HL = 0: there is no line to run; the core goes round,
;       and next_job finds the released jobs. Clobbers everything a MOS call
;       may.
shell_exit:
        ld      hl, msg_shell_out       ; "hub: back to ADE"
        call    print
        call    print_tag               ; while its jobs are still held
        ld      hl, crlf
        call    print

        ld      hl, CTL_SHELLS
        dec     (hl)
        call    stack_slot
        ld      a, (hl)
        ld      (CTL_HELD), a           ; the outer shell's, or 0,
        inc     hl
        ld      a, (hl)
        ld      (CTL_FLOOR), a          ; and its floor
        ld      hl, 0
        scf

        ret

; stack_slot: HL = CTL_SHELL_STACK + 2 * CTL_SHELLS. Clobbers A, DE.
stack_slot:
        ld      a, (CTL_SHELLS)
        add     a, a
        ld      hl, 0
        ld      l, a
        ld      de, CTL_SHELL_STACK
        add     hl, de

        ret

; print_tag: the tag of the frame the innermost shell goes back to -- the
; frame of the first job it holds, usually that frame's continuation --
; up to its first space; "hub" if it holds nothing.
; Clobbers A, BC, DE, HL, IY, and what print may.
print_tag:
        ld      a, (CTL_HELD)
        or      a, a
        jr      nz, @held
        ld      hl, s_hub
        jp      print

@held:
        ld      c, a
        ld      a, (CTL_NJOBS)
        sub     a, c                    ; the first held job's index
        ld      hl, 0
        ld      l, a
        ld      h, JOB_SIZE
        mlt     hl
        ld      de, CTL_JOBS + JOB_FRAME
        add     hl, de
        ld      a, (hl)                 ; its frame
        call    frame_iy
        ld      b, 4                    ; FRAME_TAG: four characters

@char:
        ld      a, (iy+FRAME_TAG)
        cp      a, ' '
        ret     z                       ; the tag's padding: done
        or      a, a
        ret     z
        push    bc
        push    iy
        rst.lil $10
        pop     iy
        pop     bc
        inc     iy
        djnz    @char

        ret
