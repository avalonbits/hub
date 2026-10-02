; shell/start.s -- Starting hub: the three cases (running, resuming, fresh), Hub$API, F12,
; the paths hub keeps, and the arguments.
;
; Part of the shell; hub.s includes it, in order.

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

; leave: back to MOS, with result 0 -- the end of start, and where a second
; copy of hub goes straight away. Expects IX and IY pushed, as start does.
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
;
; In:   HL = the name, zero-terminated.
; Out:  Z if it exists. Clobbers everything a MOS call may.
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

; names_match: Z if the names at HL and IY are the same, ignoring case.
; Clobbers A; HL and IY end past where they were compared.
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
;
; Builds "SetEval Hub$API &B7F30C" in LINE_BUF and runs it. Clobbers
; everything a MOS call may.
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

; withdraw_api: remove Hub$API as hub leaves, so programs run after hub has
; gone don't call into a core that no longer answers. Clobbers as OSCLI.
withdraw_api:
        ld      hl, unset_api
        jr      oscli_copy

; bind_f12: F12 brings hub back if the user ever ends up at MOS's own prompt
; -- after `exit`, or a boot with Shift held -- with its queue and blocks
; intact. The Hotkey command adds the Return itself. A binding the user made
; is kept. Clobbers as OSCLI. (Falls through into oscli_copy.)
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
;
; In:   HL = the command, zero-terminated. Out: A = OSCLI's status.
;       Clobbers everything a MOS call may.
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

; parse_args: "-f <script>" selects script mode: the path goes in
; CTL_SCRIPT, at most 63 characters, and CTL_MODE becomes 1. Anything else
; leaves the prompt as it is.
;
; In:   HL = the arguments. Clobbers A, B, DE, HL.
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
