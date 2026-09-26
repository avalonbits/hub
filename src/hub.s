; hub's shell: the prompt, and what starts hub.
;
; MOS loads this as a moslet at SHELL_BASE. On start it copies the core into
; the on-chip SRAM and hands over to it; from then on the core calls back in
; through SHELL_READLINE for each line. A moslet run later loads over this
; code, and the core reloads it from the card, so nothing here may hold state
; that has to survive a command: that lives in the control block.
;
;   hub               an interactive prompt, like MOS's own
;   hub -f <script>   run each line of a file, then leave (for tests)
;
; After a warm reset, running hub again (autoexec.obey, or F12) resumes
; where it was: the arguments are ignored then.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"

        ORG     SHELL_BASE

        jp      start
        ALIGN   64
        db      "MOS", 0, 1             ; moslet header: version 0, ADL
        blkb    3, 0

        jp      readline                ; SHELL_READLINE

LINE_BUF:       equ     SHELL_VARS              ; 256
PROMPT_BUF:     equ     SHELL_VARS + 256        ; 128
SCRIPT_FH:      equ     SHELL_VARS + 384        ; 1
SKIP:           equ     SHELL_VARS + 385        ; 3
RESUMING:       equ     SHELL_VARS + 388        ; 1 while resuming after a reset

; start: HL = the arguments MOS passes, without the program name.
;
; Three cases:
;
;   - Hub$API exists: hub is already running and this is a second copy, run
;     from hub's own prompt. MOS has just loaded it over the running shell --
;     harmlessly, since it is the same file -- but it must not touch the
;     core or the control block, so it says so and leaves.
;   - The control block's magic is there but Hub$API isn't: hub was running
;     when the machine was reset. The SRAM kept the control block, MOS
;     forgot its variables. Resume: keep the queue, the script position and
;     the blocks, and settle the job the reset cut short.
;   - Otherwise start afresh.
start:
        push    ix
        push    iy
        push    hl

        ld      hl, v_api
        call    var_exists
        jr      nz, @not_running
        ld      hl, msg_running
        call    print
        pop     hl
        jp      leave

@not_running:
        ld      hl, core_image
        ld      de, CORE_BASE
        ld      bc, core_image_end - core_image
        ldir

        ld      hl, magic
        ld      de, CTL_MAGIC
        ld      b, 4
        xor     a, a

@magic:
        ld      c, a
        ld      a, (de)
        cp      a, (hl)
        ld      a, c
        jr      z, @same
        inc     a                       ; A counts mismatches

@same:
        inc     de
        inc     hl
        djnz    @magic
        or      a, a
        ld      a, 1
        jr      z, @decided             ; all four matched: resume
        xor     a, a

@decided:
        ld      (RESUMING), a
        or      a, a
        jr      nz, @kept

        ld      hl, CTL_BASE
        ld      de, CTL_BASE + 1
        ld      bc, CTL_END - CTL_BASE - 1
        ld      (hl), 0
        ldir

        ld      hl, magic
        ld      de, CTL_MAGIC
        ld      bc, 4
        ldir

@kept:
        ld      hl, shell_code_end - SHELL_BASE
        ld      (CTL_SUMLEN), hl
        call    CORE_SUM
        ld      (CTL_SUM), hl

; Where hub was run from, so the core can reload the shell and save the
; blocks next to it. The length leaves room for the terminator.
        ld      hl, CTL_SELF
        ld      de, CTL_SELF + 1
        ld      bc, 63
        ld      (hl), 0
        ldir
        ld      hl, v_lastbin
        ld      ix, CTL_SELF
        ld      de, 63
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        call    set_blkpath

        ld      a, (RESUMING)
        call    CORE_INIT
        call    publish_api
        call    bind_f12

        pop     hl
        ld      a, (RESUMING)
        or      a, a
        jr      nz, @resumed
        call    parse_args
        ld      hl, msg_banner
        jr      @greet

@resumed:
        ld      hl, msg_resumed

@greet:
        call    print

        call    CORE_MAIN

        call    withdraw_api
        xor     a, a
        ld      (CTL_MAGIC), a

leave:
        pop     iy
        pop     ix
        ld      hl, 0

        ret

; var_exists: Z if the variable named at HL exists.
;
; readvarval with IX = 0 only asks for the length. Its status alone can't be
; trusted: in MOS 3.0.2, readVarVal treats only -1 from getSystemVariable as
; "not found", but that returns a positive number for a name that would sort
; after an existing variable, and readVarVal then answers for that neighbour
; with status 0. So compare the name it actually matched, which it returns
; in IY, with the one asked for (case-insensitively, as MOS matches).
; Clobbers everything a MOS call may.
var_exists:
        push    hl
        ld      ix, 0
        ld      de, 0
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        pop     hl
        or      a, a
        ret     nz

names_match:
        ld      a, (iy+0)
        xor     a, (hl)
        and     a, $df                  ; ignore case (and nothing else matters
        ret     nz                      ; for the letters, digits and $ used)
        ld      a, (hl)
        or      a, a
        ret     z                       ; both ended together
        inc     hl
        inc     iy
        jr      names_match

; publish_api: create the Number variable Hub$API, holding HUB_HEADER.
;
; Through the SetEval command, not mos_setvarval (API $30): in MOS 3.0.2,
; setVarVal creates a variable only when getSystemVariable returns -1, and
; that returns a positive number for "not found" whenever the name would sort
; after an existing variable -- so the API call quietly overwrites that
; neighbour (mos_sysvars.c, setVarVal: `if (result == -1)`). "Hub$API" would
; land on Current$Dir. SetEval goes through createOrUpdateSystemVariable,
; which gets this right, and reads & as hex.
publish_api:
        ld      hl, set_api
        ld      de, LINE_BUF
        ld      bc, set_api_end - set_api
        ldir                            ; "SetEval Hub$API &"
        ld      a, (HUB_HEADER >> 16) & $ff
        call    hex_byte
        ld      a, (HUB_HEADER >> 8) & $ff
        call    hex_byte
        ld      a, HUB_HEADER & $ff
        call    hex_byte
        xor     a, a
        ld      (de), a
        ld      hl, LINE_BUF
        ld      a, mos_oscli
        rst.lil $08

        ret

; withdraw_api: so programs run after hub has gone don't call into a core
; that no longer answers.
withdraw_api:
        ld      hl, unset_api
        ld      a, mos_oscli
        rst.lil $08

        ret

; bind_f12: F12 brings hub back if the user ever ends up at MOS's own prompt
; -- after `exit`, or a boot with Shift held -- with its queue and blocks
; intact. The Hotkey command adds the Return itself. A binding the user made
; is kept.
bind_f12:
        ld      hl, v_hotkey
        call    var_exists
        ret     z
        ld      hl, set_hotkey
        ld      a, mos_oscli
        rst.lil $08

        ret

; hex_byte: write A as two upper-case hex digits at DE, advancing DE.
; Clobbers A, C.
hex_byte:
        ld      c, a
        rra
        rra
        rra
        rra
        call    @digit
        ld      a, c

@digit:
        and     a, $0f
        add     a, '0'
        cp      a, '9' + 1
        jr      c, @put
        add     a, 'A' - '9' - 1

@put:
        ld      (de), a
        inc     de

        ret

; set_blkpath: CTL_BLKPATH = CTL_SELF with its ".bin" made ".blk" (or ".blk"
; added), so the client blocks are saved next to hub.bin.
; Clobbers A, BC, DE, HL.
set_blkpath:
        ld      hl, CTL_SELF
        ld      de, CTL_BLKPATH
        ld      bc, 59                  ; room left for ".blk" and the end
        ldir
        xor     a, a
        ld      (CTL_BLKPATH + 59), a
        ld      hl, CTL_BLKPATH
        ld      bc, 60
        cpir                            ; HL = just past the terminator
        dec     hl
        push    hl
        dec     hl
        dec     hl
        dec     hl
        dec     hl                      ; where ".bin" would start
        ld      a, (hl)
        cp      a, '.'
        pop     de                      ; DE = the terminator: append there
        jr      nz, @append
        ex      de, hl                  ; DE = the '.': write over ".bin"

@append:
        ld      hl, blk_ext
        ld      bc, 5
        ldir

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

; readline: HL = the next line to run, or 0 to leave hub.
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
; runs, so hub holds no file while a command does, and a command that closes
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

; builtin: HL = a line. Handles hub's own commands; otherwise returns the
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

magic:          db      "HUB0"
v_lastbin:      db      "LastBin$Run", 0
v_prompt:       db      "CLI$Prompt", 0
star:           db      "*", 0
s_exit:         db      "exit", 0
script_echo:    db      "hub> ", 0
crlf:           db      13, 10, 0
nlcr:           db      10, 13, 0
msg_banner:     db      "hub 0.2", 13, 10, 0
msg_resumed:    db      "hub 0.2: resumed after a reset", 13, 10, 0
msg_running:    db      "hub is already running", 13, 10, 0
v_api:          db      "Hub$API", 0
v_hotkey:       db      "Hotkey$12", 0
set_api:        db      "SetEval Hub$API &"     ; + the header's address, in hex
set_api_end:
unset_api:      db      "Unset Hub$API", 0
set_hotkey:     db      "Hotkey 12 hub", 0
blk_ext:        db      ".blk", 0
msg_escape:     db      "Escape", 10, 13, 0
msg_noscript:   db      "hub: cannot open the script", 13, 10, 0

core_image:
        INCBIN  "core.bin"
core_image_end:

shell_code_end:
