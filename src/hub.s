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
; After a warm reset, running hub again (autoexec.txt, or F12) resumes
; where it was: the arguments are ignored then.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"
        INCLUDE "hub.inc"
        INCLUDE "config.inc"

        ORG     SHELL_BASE

        jp      start
        ALIGN   64
        db      "MOS", 0, 1             ; moslet header: version 0, ADL
        blkb    3, 0

        jp      readline                ; SHELL_READLINE
        jp      job_start               ; SHELL_JOB_START
        jp      job_end                 ; SHELL_JOB_END
        jp      block_grow              ; SHELL_BLOCK_GROW

LINE_BUF:       equ     SHELL_VARS              ; 256
PROMPT_BUF:     equ     SHELL_VARS + 256        ; 128
SCRIPT_FH:      equ     SHELL_VARS + 384        ; 1
SKIP:           equ     SHELL_VARS + 385        ; 3
RESUMING:       equ     SHELL_VARS + 388        ; 1 while resuming after a reset
NUM_VAL:        equ     SHELL_VARS + 389        ; 3: number's value so far
NUM_NEG:        equ     SHELL_VARS + 392        ; 1: it had a '-'
NUM_DIG:        equ     SHELL_VARS + 393        ; 1: the digit being added

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
        call    boot_font

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
        xor     a, a
        ld      (CTL_CAPMODE), a        ; a reset may have cleared the VDP's
        call    publish_api             ; buffers; there is no capture now
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
        jr      oscli_copy

; bind_f12: F12 brings hub back if the user ever ends up at MOS's own prompt
; -- after `exit`, or a boot with Shift held -- with its queue and blocks
; intact. The Hotkey command adds the Return itself. A binding the user made
; is kept.
bind_f12:
        ld      hl, v_hotkey
        call    var_exists
        ret     z
        ld      hl, set_hotkey

; oscli_copy: run the command at HL through OSCLI, from a copy in LINE_BUF.
;
; Never from the string itself: mos_exec writes into the command it is given
; (mos_trim puts NULs in it), and these strings are part of the shell's code,
; which the core checksums. Run in place, a command quietly changes the code,
; and the core then "repairs" a shell nothing overwrote.
oscli_copy:
        ld      de, LINE_BUF

@copy:
        ld      a, (hl)
        ld      (de), a
        inc     hl
        inc     de
        or      a, a
        jr      nz, @copy
        ld      hl, LINE_BUF
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
        IF PROMPTFONT
        call    scan_font               ; a line that picks a font
        ENDIF

        push    hl
        ld      de, s_exit
        call    word_is
        pop     hl
        ret     nz
        ld      hl, 0

        ret

; job_start: A = the flags of the job about to run; the core calls this only
; when one of HUB_USER_PROGRAM and HUB_PAUSE_AFTER is set.
;
; HUB_USER_PROGRAM: hand the screen over as hub's prompt had it, whatever
; the program that queued the job did to it -- an IDE's colours, layout,
; font, cursor and mode. In order: VDU 23,16,0,0 puts the cursor behaviour
; back to its defaults (scroll protection off among them); VDU 23,0,&95
; selects the system font (65535); VDU 22 sets the prompt's mode, which
; also resets the viewports, colours and palette and clears the screen; and
; VDU 23,1,1 shows the cursor.
job_start:
        bit     1, a                    ; HUB_USER_PROGRAM
        ret     z

; reset_screen: the screen as hub's prompt has it. The font comes after the
; mode, since a mode change goes back to the system font.
reset_screen:
        ld      hl, vdu_reset
        ld      bc, vdu_reset_mode - vdu_reset
        xor     a, a
        rst.lil $18
        ld      a, (CTL_SCRMODE)
        rst.lil $10
        ld      hl, vdu_reset_mode
        ld      bc, vdu_reset_font - vdu_reset_mode
        xor     a, a
        rst.lil $18
        ld      a, (CTL_FONT)
        rst.lil $10
        ld      a, (CTL_FONT + 1)
        rst.lil $10
        ld      hl, vdu_reset_font
        ld      bc, vdu_reset_end - vdu_reset_font
        xor     a, a
        rst.lil $18

        ret

; job_end: A = the flags of the job that has just run; called, like
; job_start, only when one of the two is set, and after the core has
; repaired the shell if the job was a moslet.
;
; HUB_PAUSE_AFTER: "Press a key to return", then wait for one, so the
; program's output can be read before whatever runs next draws over it --
; whether the job worked or not. With the variable Hub$NoPause set, as a
; test sets it, the message is printed and nothing waits.
job_end:
        push    af
        IF CAPTURE
        bit     1, a                    ; HUB_USER_PROGRAM
        call    nz, capture
        pop     af
        push    af
        ENDIF

        bit     2, a                    ; HUB_PAUSE_AFTER
        jr      z, @paused

        ld      hl, msg_pause
        call    print
        ld      hl, v_nopause
        call    var_exists
        jr      z, @go
        ld      a, mos_getkey
        rst.lil $08

@go:
        ld      hl, crlf
        call    print

; And the screen back as the prompt had it, so what runs next -- usually
; the program that queued the job -- starts as it would from the prompt,
; in the prompt's mode and font.
@paused:
        pop     af
        bit     1, a                    ; HUB_USER_PROGRAM
        ret     z
        jp      reset_screen

; capture: keep the screen a HUB_USER_PROGRAM job left, for its client to
; show again (hub_user_screen) -- before the pause draws over it.
;
; VDU 23,27,&21 copies the rectangle between the last two graphics cursor
; positions into a buffer, as a bitmap (RGBA2222 from VDP 2.6.0, whatever
; the mode). The buffer is cleared first, and the coordinates the program
; may have changed are put back -- logical coordinates (VDU 23,0,&C0,1),
; origin at 0,0 -- so the corners are the screen's own: 0,0 and
; 1279,1023. A VDP without the command ignores it, and the buffer stays
; empty. Then the mode, as MOS last heard it from the VDP.
capture:
        ld      hl, vdu_capture
        ld      bc, vdu_capture_end - vdu_capture
        xor     a, a
        rst.lil $18
        call    vdp_mode
        inc     a
        ld      (CTL_CAPMODE), a

        ret

; vdp_mode: A = the screen mode, as MOS last heard it from the VDP.
vdp_mode:
        ld      a, mos_sysvars
        rst.lil $08
        ld      a, (ix+sysvar_scrMode)

        ret

; block_grow: grow a client block to the size asked for -- for api_block,
; when a program asks for more than its block holds, as a new version of the
; program with a bigger state does.
;
; In:   IX = the block's directory entry, IY = the size asked for, bigger
;       than its size.
; Out:  A = 0, HL = the block: its old contents kept, the rest zeroed, as a
;       new block is. A = 1, HL = 0 if there is no room; the block is then
;       as it was.
;
; The last block grows where it is. Any other is copied to BLK_NEXT, and the
; space it leaves is lost until hub next starts afresh: blocks are never
; freed. So a block can move, and a program must take its address again
; after asking for a bigger one.
block_grow:
        ld      hl, (ix+4)
        ld      de, (ix+7)
        add     hl, de                  ; its end
        ld      de, (BLK_NEXT)
        or      a, a
        sbc     hl, de
        jr      z, @in_place            ; the last block

        ld      hl, (BLK_NEXT)
        call    @fits
        jr      nc, @fail
        ld      hl, (ix+4)
        ld      de, (BLK_NEXT)
        ld      bc, (ix+7)
        ldir                            ; the old contents, to BLK_NEXT
        ld      hl, (BLK_NEXT)
        ld      (ix+4), hl
        jr      @grow

@in_place:
        ld      hl, (ix+4)
        call    @fits
        jr      nc, @fail

@grow:
        ld      hl, (ix+4)
        lea     de, iy+0
        add     hl, de
        ld      (BLK_NEXT), hl          ; it ends the blocks now

        lea     hl, iy+0
        ld      de, (ix+7)
        or      a, a
        sbc     hl, de
        push    hl
        pop     bc                      ; BC = the bytes added, at least 1
        ld      hl, (ix+4)
        add     hl, de                  ; HL = the first of them
        ld      (hl), 0                 ; zero it, then copy it forward
        dec     bc
        ld      a, b
        or      a, c
        jr      z, @zeroed              ; BCU is 0: blocks are under 64 KB
        push    hl
        pop     de
        inc     de
        ldir

@zeroed:
        lea     de, iy+0
        ld      (ix+7), de              ; its size
        ld      hl, (ix+4)
        xor     a, a

        ret

@fail:
        ld      hl, 0
        ld      a, 1

        ret

; @fits: carry set if a block of IY bytes starting at HL ends by BLK_END.
@fits:
        lea     de, iy+0
        add     hl, de
        ld      de, BLK_END + 1
        or      a, a
        sbc     hl, de

        ret

; boot_font: CTL_FONT = the font the machine's boot script selected, if it
; selected one, else the system font.
;
; The VDP can't be asked which font is in use, and a mode change drops it --
; so to put the prompt's font back after a user program, hub has to know it.
; Like aed (src/ui/bootfont.c), it reads /autoexec.txt, where a machine set
; up for a font of its own selects it, and keeps the last selection there;
; scan_font then follows selections made at hub's own prompt.
boot_font:
        ld      hl, $ffff
        ld      (CTL_FONT), hl

        IF PROMPTFONT
        ld      hl, autoexec
        ld      c, fa_read
        ld      a, mos_fopen
        rst.lil $08
        or      a, a
        ret     z
        ld      (SCRIPT_FH), a

@line:
        call    read_line
        jp      c, close_script
        ld      hl, LINE_BUF
        call    scan_font
        jr      @line
        ELSE

        ret
        ENDIF

; scan_font: if the line at HL selects a font, note it in CTL_FONT.
; HL kept; everything else clobbered.
;
; Two ways of selecting one, as aed reads them (case doesn't matter, and a
; leading '*' is MOS's and ignored):
;
;   fontctl <id>        fontctl sys -- or anything that isn't a number -- is
;                       the system font
;   VDU 23,0,149,0,<id> the selection written out (VDU 23,0,&95,0,id;flags)
;   VDU 22,<mode>       a mode change, which goes back to the system font
;
; Numbers as number reads them. A line that is neither leaves CTL_FONT be.
scan_font:
        push    hl
        call    @scan
        pop     hl

        ret

@scan:
        ld      a, (hl)
        cp      a, ' '
        jr      z, @lead
        cp      a, '*'
        jr      nz, @word

@lead:
        inc     hl
        jr      @scan

@word:
        push    hl
        ld      de, s_fontctl
        call    word_is
        jr      z, @fontctl
        pop     hl
        ld      de, s_vdu
        call    word_is
        ret     nz

        call    number
        ret     c
        ld      a, b
        or      a, a
        ret     nz
        ld      a, c
        cp      a, 22
        jr      z, @system
        cp      a, 23
        ret     nz
        ld      de, vdu_font_args + 1

@arg:
        ld      a, (de)
        cp      a, $ff
        jr      z, @id
        push    de
        call    number
        pop     de
        ret     c
        ld      a, (de)
        cp      a, c
        ret     nz
        ld      a, b
        or      a, a
        ret     nz
        inc     de
        jr      @arg

@id:
        call    number
        ret     c
        jr      @set

@fontctl:
        pop     de                      ; the line's start: not needed now
        call    skip_spaces
        call    number
        jr      nc, @set

@system:
        ld      bc, $ffff               ; sys, or something else

@set:
        ld      (CTL_FONT), bc

        ret

; number: a number as MOS reads one in a VDU line, after any spaces and
; commas: an optional '-', then decimal, &hex or 0xhex digits, and an
; optional ';' (sixteen bits, which changes nothing). It must end there.
; (MOS's base_digits and trailing-H forms aren't taken.)
;
; Out:  carry clear: BC = the value, masked to 16 bits as it goes to the
;       VDP (so -1 is 65535), HL past it. Carry set: not a number, or more
;       than 16 bits. Clobbers A, DE.
number:
        ld      a, (hl)
        cp      a, ' '
        jr      z, @sep
        cp      a, ','
        jr      nz, @sign

@sep:
        inc     hl
        jr      number

@sign:
        ld      de, 0
        ld      (NUM_VAL), de
        xor     a, a
        ld      (NUM_NEG), a
        ld      a, (hl)
        cp      a, '-'
        jr      nz, @base
        ld      a, 1
        ld      (NUM_NEG), a
        inc     hl

@base:
        ld      bc, 10                  ; B counts digits, C is the base
        ld      a, (hl)
        cp      a, '&'
        jr      z, @hex
        cp      a, '0'
        jr      nz, @digit
        inc     hl
        ld      a, (hl)
        dec     hl
        or      a, $20
        cp      a, 'x'
        jr      nz, @digit
        inc     hl

@hex:
        inc     hl
        ld      c, 16

@digit:
        ld      a, (hl)
        call    digit_val
        jr      c, @end
        cp      a, c
        jr      nc, @end
        ld      (NUM_DIG), a
        push    hl
        push    bc
        ld      de, (NUM_VAL)
        ld      hl, 0
        ld      b, c

@times:
        add     hl, de                  ; HL = value * base
        djnz    @times
        ld      de, 0
        ld      a, (NUM_DIG)
        ld      e, a
        add     hl, de
        ld      (NUM_VAL), hl
        ld      de, $10000
        or      a, a
        sbc     hl, de
        pop     bc
        pop     hl
        jr      nc, @fail               ; past 16 bits
        inc     hl
        inc     b
        jr      @digit

@end:
        ld      a, b
        or      a, a
        jr      z, @fail                ; no digits
        ld      a, (hl)
        cp      a, ';'
        jr      nz, @after
        inc     hl

@after:
        ld      a, (hl)
        or      a, a
        jr      z, @ok
        cp      a, ' '
        jr      z, @ok
        cp      a, ','
        jr      nz, @fail

@ok:
        ld      a, (NUM_NEG)
        or      a, a
        jr      z, @mask
        push    hl
        ld      hl, 0
        ld      de, (NUM_VAL)
        sbc     hl, de                  ; carry clear from the or
        ld      (NUM_VAL), hl
        pop     hl

@mask:
        xor     a, a
        ld      (NUM_VAL + 2), a
        ld      bc, (NUM_VAL)

        ret                             ; carry clear from the xor

@fail:
        scf

        ret

; digit_val: A = the value of the digit in A (0-9, a-f in any case); carry
; set if it isn't one.
digit_val:
        cp      a, '0'
        jr      c, @no
        cp      a, '9' + 1
        jr      c, @decimal
        or      a, $20
        cp      a, 'a'
        jr      c, @no
        cp      a, 'f' + 1
        jr      nc, @no
        sub     a, 'a' - 10

        ret                             ; carry clear: A is at least 10

@decimal:
        sub     a, '0'

        ret                             ; carry clear

@no:
        scf

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
msg_banner:     db      "hub "
                INCLUDE "version.inc"
                db      13, 10, 0
msg_resumed:    db      "hub "
                INCLUDE "version.inc"
                db      ": resumed after a reset", 13, 10, 0
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
msg_pause:      db      13, 10, "Press a key to return", 0
v_nopause:      db      "Hub$NoPause", 0
vdu_reset:      db      23, 16, 0, 0            ; cursor behaviour: defaults
                db      22                      ; + the mode
vdu_reset_mode: db      23, 0, $95, 0           ; select + the prompt's font;
vdu_reset_font: db      0                       ;   flags
                db      23, 1, 1                ; the cursor on
vdu_reset_end:
autoexec:       db      "/autoexec.txt", 0
s_fontctl:      db      "fontctl", 0
s_vdu:          db      "vdu", 0
vdu_font_args:  db      23, 0, 149, 0, $ff      ; VDU 23,0,&95,0: select font
vdu_capture:    db      23, 0, $a0              ; clear the buffer
                dw      HUB_SCREEN_BUFFER
                db      2
                db      23, 0, $c0, 1           ; logical coordinates
                db      29, 0, 0, 0, 0          ; graphics origin 0,0
                db      25, 4, 0, 0, 0, 0       ; one corner,
                db      25, 4                   ; and the other
                dw      1279, 1023
                db      23, 27, $21             ; capture into the buffer
                dw      HUB_SCREEN_BUFFER
                dw      0
vdu_capture_end:

core_image:
        INCBIN  "core.bin"
core_image_end:

shell_code_end:
