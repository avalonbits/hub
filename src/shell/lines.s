; shell/lines.s -- Where lines come from: the prompt or a script; and hub's own command, exit.
;
; Part of the shell; hub.s includes it, in order.

; readline: HL = the next line to run, carry clear; HL = 0, carry clear, to
; leave hub; or carry set when there is nothing to run but hub goes on (an
; exit that closed a nested shell, see shell/shells.s).
;
; The screen mode is noted first: it is the one the user has at hub's
; prompt, which a HUB_USER_PROGRAM job starts in whatever the program that
; queued it did to the screen.
readline:
        call    vdp_mode
        ld      (CTL_SCRMODE), a

        ld      a, (CTL_MODE)
        or      a, a
        jr      nz, script_line

; The prompt, printed and read as MOS's own does (mos_input): CLI$Prompt
; expanded, then the line editor with a cleared buffer and tab completion.
prompt_line:
        ld      hl, PROMPT_BUF
        ld      de, PROMPT_BUF + 1
        ld      bc, 127
        ld      (hl), 0
        ldir

        ld      hl, v_prompt
        ld      ix, PROMPT_BUF
        ld      de, 127
        ld      iy, 0
        ld      c, var_expand
        ld      a, mos_readvarval
        rst.lil $08
        ld      a, (CTL_SHELLS)         ; in a nested shell, its tag
        or      a, a                    ; first: "ADE * "
        jr      z, @plain
        call    print_tag
        ld      hl, space
        call    print

@plain:
        ld      hl, PROMPT_BUF
        ld      a, (PROMPT_BUF)
        or      a, a
        jr      nz, @show
        ld      hl, star

@show:
        call    print

        ld      hl, LINE_BUF
        ld      bc, 256
        ld      e, 3
        ld      a, mos_editline
        rst.lil $08
        push    af
        ld      hl, nlcr
        call    print
        pop     af
        cp      a, 13
        jr      z, @entered

        ld      hl, msg_escape
        call    print
        jr      prompt_line

@entered:
        ld      hl, LINE_BUF
        jp      builtin

; A script line. The file is opened for each line and closed before the line
; runs, so hub holds no file while a command does, and a command that closes
; every file can't take the script with it.
script_line:
        ld      hl, CTL_SCRIPT
        ld      c, fa_read
        ld      a, mos_fopen
        rst.lil $08
        or      a, a
        jp      z, @missing
        ld      (SCRIPT_FH), a

        ld      hl, (CTL_LINE)
        ld      (SKIP), hl

@skip:
        ld      hl, (SKIP)
        call    hl_is_zero
        jr      z, @read
        call    read_line
        jp      c, @eof
        ld      hl, (SKIP)
        dec     hl
        ld      (SKIP), hl
        jr      @skip

@read:
        call    read_line
        jp      c, @eof
        ld      hl, (CTL_LINE)
        inc     hl
        ld      (CTL_LINE), hl
        call    close_script

        ld      hl, LINE_BUF
        call    skip_spaces
        ld      a, (hl)
        or      a, a
        jr      z, script_line
        cp      a, '#'
        jr      z, script_line

        push    hl
        ld      a, (CTL_SHELLS)         ; in a nested shell, its tag first,
        or      a, a                    ; as at the prompt: "ADE hub> ..."
        jr      z, @echo
        call    print_tag
        ld      hl, space
        call    print

@echo:
        ld      hl, script_echo
        call    print
        pop     hl
        push    hl
        call    print
        ld      hl, crlf
        call    print
        pop     hl
        jp      builtin

@eof:
        call    close_script
        ld      hl, 0
        or      a, a                    ; carry clear: leave hub

        ret

@missing:
        ld      hl, msg_noscript
        call    print
        ld      hl, 0
        or      a, a

        ret

; builtin: HL = a line. Handles hub's own commands; otherwise returns the
; line for the core to run.
builtin:
        call    skip_spaces
        ld      a, (hl)
        or      a, a
        jp      z, readline
        IF PROMPTFONT
        call    scan_font               ; a line that picks a font
        ENDIF

        push    hl
        ld      de, s_exit
        call    word_is
        pop     hl
        jr      z, @exit
        or      a, a                    ; carry clear: a line to run

        ret

; exit closes a nested shell if one is open, and leaves hub if not.
@exit:
        ld      a, (CTL_SHELLS)
        or      a, a
        jp      nz, shell_exit          ; carry set: nothing to run
        ld      hl, 0                   ; carry clear from the or: leave

        ret
