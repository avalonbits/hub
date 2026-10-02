; core/run.s -- The core's loop, and running one command through MOS.
;
; Part of the core; core.s includes it, in order.

; ----------------------------------------------------------------------------
; core_main: run commands until the shell hands back HL = 0.
;
; In:   core_init has run, and the control block holds CTL_SUMLEN, CTL_SUM
;       and CTL_SELF, since the first thing the loop does is check the shell
;       against them.
; Out:  returns to the shell when the shell's readline returns HL = 0.
;       IX and IY are preserved; everything else clobbered.
;
; Each turn of the loop:
;
;   1. check_shell   make sure the shell is intact before calling into it --
;                    the previous command may have been a moslet.
;   2. next_job      if programs have queued jobs, run the next one.
;   3. readline      otherwise, ask the shell for a line (prompt or script)
;                    and run it.
;
; Queued jobs always come before the prompt: a program that queues work and
; returns expects that work to run next.
; ----------------------------------------------------------------------------
core_main:
        push    ix
        push    iy

@loop:
        call    check_shell             ; a moslet may have loaded over it
        call    snapshot_blocks         ; save the blocks if a program changed them
        call    next_job                ; carry set: a job ran
        jr      c, @loop

        call    SHELL_READLINE          ; HL = next line, or 0 to stop
        call    hl_is_zero
        jr      z, @done

        call    build_cmd               ; CTL_CMD = "Try " + line
        jr      c, @loop                ; too long: reported, skip it
        call    clear_done              ; not a continuation
        call    run_cmd
        jr      @loop

@done:
        pop     iy
        pop     ix

        ret

; ----------------------------------------------------------------------------
; run_cmd: run CTL_CMD through MOS, clean up, and report a failure.
;
; In:   CTL_CMD = "Try <command>".
; Out:  CTL_RC = the command's result. Clobbers everything.
;
; Why "Try <line>" rather than the line itself or "Do <line>":
;
;   - OSCLI runs its argument with mos_exec(cmd, in_mos = false). With that
;     flag, a bare name like "aed" is only looked up as a moslet, because
;     MOS assumes a program calling OSCLI doesn't want to be overwritten by a
;     program at 0x40000. hub wants exactly that, so it needs the rules
;     MOS's own prompt uses: mos_exec(line, in_mos = true).
;   - Both Do and Try call mos_exec(line, true). But Do is declared with
;     expandArgs, so MOS runs GSTrans over the line before Do sees it, and
;     the command then expands it again: "Echo |<once>" would print nothing
;     instead of "<once>". Try is not, so a line is expanded exactly once,
;     as at MOS's prompt. test/run.sh checks this.
;   - Try always returns 0 itself and stores the command's real result in the
;     variable Try$ReturnCode, which report reads.
; ----------------------------------------------------------------------------
run_cmd:
        ld      hl, CTL_CMD
        ld      a, mos_oscli            ; A comes back as Try's own result,
        rst.lil $08                     ; always 0, so it is ignored

        IF GUARDS
        call    guards
        ENDIF

        jp      report

; ----------------------------------------------------------------------------
; build_cmd: CTL_CMD = "Try " followed by the line at HL.
;
; In:   HL = the line, zero-terminated.
; Out:  carry clear: CTL_CMD holds the command, zero-terminated.
;       carry set:   the line was longer than CMD_MAX; a message has been
;                    printed and CTL_CMD is not usable.
;       Clobbers A, B, BC, DE, HL.
;
; The copy is needed, not just the prefix: mos_exec writes into the string it
; is given (mos_trim puts NULs in it), and the line may sit in the moslet area
; or in a job, where the command about to run may load over it or queue more.
;
; B counts down from CMD_MAX. DJNZ uses only the 8-bit B, which is why the
; limit is 255; CTL_CMD has room for "Try " + 255 + the terminator.
; ----------------------------------------------------------------------------
build_cmd:
        push    hl
        ld      hl, try_prefix
        ld      de, CTL_CMD
        ld      bc, 4
        ldir                            ; DE now points just after "Try "
        pop     hl
        ld      b, CMD_MAX

@copy:
        ld      a, (hl)
        ld      (de), a
        or      a, a                    ; the terminator? (also clears carry)
        ret     z
        inc     hl
        inc     de
        djnz    @copy

        ld      hl, msg_long
        call    print
        scf

        ret
