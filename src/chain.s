; chain's shell: the prompt, and what starts chain.
;
; MOS loads this as a moslet at SHELL_BASE. On start it copies the core into
; the on-chip SRAM and hands over to it; from then on the core calls back in
; through SHELL_READLINE for each line. A moslet run later loads over this
; code, and the core reloads it from the card, so nothing here may hold state
; that has to survive a command: that lives in the control block.
;
;   chain               an interactive prompt, like MOS's own
;   chain -f <script>   run each line of a file, then leave (for tests)

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"

        ORG     SHELL_BASE

        jp      start
        ALIGN   64
        db      "MOS", 0, 1             ; moslet header: version 0, ADL
        blkb    3, 0

        jp      readline                ; SHELL_READLINE

CORE_MAIN:      equ     CORE_BASE
CORE_SUM:       equ     CORE_BASE + 4

LINE_BUF:       equ     SHELL_VARS              ; 256
PROMPT_BUF:     equ     SHELL_VARS + 256        ; 128
SCRIPT_FH:      equ     SHELL_VARS + 384        ; 1
SKIP:           equ     SHELL_VARS + 385        ; 3

; start: HL = the arguments MOS passes, without the program name.
start:
        push    ix
        push    iy
        push    hl

        ld      hl, core_image
        ld      de, CORE_BASE
        ld      bc, core_image_end - core_image
        ldir

        ld      hl, CTL_BASE
        ld      de, CTL_BASE + 1
        ld      bc, CTL_END - CTL_BASE - 1
        ld      (hl), 0
        ldir

        ld      hl, magic
        ld      de, CTL_MAGIC
        ld      bc, 4
        ldir

        ld      hl, shell_code_end - SHELL_BASE
        ld      (CTL_SUMLEN), hl
        call    CORE_SUM
        ld      (CTL_SUM), hl

; Where chain was run from, so the core can reload the shell. The control
; block was zeroed and the length leaves room, so the copy stays terminated.
        ld      hl, v_lastbin
        ld      ix, CTL_SELF
        ld      de, 63
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08

        pop     hl
        call    parse_args

        ld      hl, msg_banner
        call    print

        call    CORE_MAIN

        xor     a, a
        ld      (CTL_MAGIC), a
        pop     iy
        pop     ix
        ld      hl, 0

        ret

; parse_args: "-f <script>" selects script mode.
parse_args:
        call    skip_spaces
        ld      a, (hl)
        cp      a, '-'
        ret     nz
        inc     hl
        ld      a, (hl)
        cp      a, 'f'
        ret     nz
        inc     hl
        call    skip_spaces
        ld      de, CTL_SCRIPT
        ld      b, 63

@copy:
        ld      a, (hl)
        cp      a, '!'
        jr      c, @end
        ld      (de), a
        inc     hl
        inc     de
        djnz    @copy

@end:
        xor     a, a
        ld      (de), a
        ld      a, 1
        ld      (CTL_MODE), a

        ret

; readline: HL = the next line to run, or 0 to leave chain.
readline:
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
        ld      hl, PROMPT_BUF
        or      a, a
        jr      z, @show
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
; runs, so chain holds no file while a command does, and a command that closes
; every file can't take the script with it.
script_line:
        ld      hl, CTL_SCRIPT
        ld      c, fa_read
        ld      a, mos_fopen
        rst.lil $08
        or      a, a
        jr      z, @missing
        ld      (SCRIPT_FH), a

        ld      hl, (CTL_LINE)
        ld      (SKIP), hl

@skip:
        ld      hl, (SKIP)
        call    hl_is_zero
        jr      z, @read
        call    read_line
        jr      c, @eof
        ld      hl, (SKIP)
        dec     hl
        ld      (SKIP), hl
        jr      @skip

@read:
        call    read_line
        jr      c, @eof
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

        ret

@missing:
        ld      hl, msg_noscript
        call    print
        ld      hl, 0

        ret

; builtin: HL = a line. Handles chain's own commands; otherwise returns the
; line for the core to run.
builtin:
        call    skip_spaces
        ld      a, (hl)
        or      a, a
        jp      z, readline

        push    hl
        ld      de, s_exit
        call    word_is
        pop     hl
        ret     nz
        ld      hl, 0

        ret

; read_line: the next line of the script into LINE_BUF, without its CR/LF.
; Carry set if the file had nothing left.
read_line:
        call    at_eof
        jr      nz, @empty
        ld      hl, LINE_BUF

@next:
        push    hl
        ld      a, (SCRIPT_FH)
        ld      c, a
        ld      a, mos_fgetc
        rst.lil $08
        pop     hl
        push    af
        cp      a, 10
        jr      z, @newline
        cp      a, 13
        jr      z, @more
        ld      (hl), a
        push    hl
        ld      de, LINE_BUF + 250
        or      a, a
        sbc     hl, de
        pop     hl
        jr      nc, @more               ; over-long: the rest is dropped
        inc     hl

@more:
        pop     af
        jr      c, @done                ; that was the file's last byte
        jr      @next

@newline:
        pop     af

@done:
        ld      (hl), 0
        or      a, a

        ret

@empty:
        scf

        ret

; at_eof: NZ if the script is at its end.
at_eof:
        ld      a, (SCRIPT_FH)
        ld      c, a
        ld      a, mos_feof
        rst.lil $08
        or      a, a

        ret

close_script:
        ld      a, (SCRIPT_FH)
        ld      c, a
        ld      a, mos_fclose
        rst.lil $08

        ret

; word_is: Z if the word at HL is the lower-case word at DE, in any case.
word_is:
        ld      a, (de)
        or      a, a
        jr      z, @end
        ld      c, a
        ld      a, (hl)
        or      a, $20
        cp      a, c
        ret     nz
        inc     hl
        inc     de
        jr      word_is

@end:
        ld      a, (hl)
        or      a, a
        ret     z
        cp      a, ' '

        ret

skip_spaces:
        ld      a, (hl)
        cp      a, ' '
        ret     nz
        inc     hl
        jr      skip_spaces

hl_is_zero:
        push    de
        ld      de, 0
        or      a, a
        sbc     hl, de
        add     hl, de
        pop     de

        ret

print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

magic:          db      "CHN0"
v_lastbin:      db      "LastBin$Run", 0
v_prompt:       db      "CLI$Prompt", 0
star:           db      "*", 0
s_exit:         db      "exit", 0
script_echo:    db      "chain> ", 0
crlf:           db      13, 10, 0
nlcr:           db      10, 13, 0
msg_banner:     db      "chain 0.0 (phase 0 spike)", 13, 10, 0
msg_escape:     db      "Escape", 10, 13, 0
msg_noscript:   db      "chain: cannot open the script", 13, 10, 0

core_image:
        INCBIN  "core.bin"
core_image_end:

shell_code_end:
