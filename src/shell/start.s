; shell/start.s -- Starting hub: the three cases (running, resuming, fresh), Hub$API, F12,
; the paths hub keeps, and the arguments.
;
; Part of the shell; hub.s includes it, in order.

; start: where MOS enters hub. HL = the arguments, without the program name.
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
;
; Then the core runs everything until the shell says stop (exit, or the end
; of a script), and hub leaves.
start:
        push    ix
        push    iy
        push    hl                      ; the arguments, for greet

        call    already_running
        jr      nz, @first
        pop     hl
        jp      leave

@first:
        call    install_core
        call    was_running             ; A = 1 to resume, 0 to start afresh
        ld      (RESUMING), a
        or      a, a
        call    z, fresh_control_block
        call    note_shell

        ld      a, (RESUMING)
        call    CORE_INIT
        xor     a, a
        ld      (CTL_CAPMODE), a        ; a reset may have cleared the VDP's
        call    publish_api             ; buffers; there is no capture now
        call    bind_f12

        pop     hl
        call    greet

        call    CORE_MAIN               ; until exit or the script's end

        call    withdraw_api
        xor     a, a
        ld      (CTL_MAGIC), a          ; a later hub starts afresh

; leave: back to MOS, with result 0 -- the end of start, and where a second
; copy of hub goes straight away. Expects IX and IY pushed, as start does.
leave:
        pop     iy
        pop     ix
        ld      hl, 0

        ret

; already_running: Z, having said so, if hub is running already.
; Clobbers everything a MOS call may.
already_running:
        ld      hl, v_api
        call    var_exists
        ret     nz
        ld      hl, msg_running
        call    print
        xor     a, a                    ; Z: print leaves the flags undefined

        ret

; install_core: copy the core, carried at the end of this file, to on-chip
; RAM. Clobbers BC, DE, HL.
install_core:
        ld      hl, core_image
        ld      de, CORE_BASE
        ld      bc, core_image_end - core_image
        ldir

        ret

; was_running: A = 1 if the control block still holds hub's magic -- hub was
; running when the machine was reset -- else 0. Clobbers B, DE, HL.
was_running:
        ld      hl, magic
        ld      de, CTL_MAGIC
        ld      b, 4

@compare:
        ld      a, (de)
        cp      a, (hl)
        jr      nz, @no
        inc     de
        inc     hl
        djnz    @compare
        ld      a, 1

        ret

@no:
        xor     a, a

        ret

; fresh_control_block: a zeroed control block with hub's magic in it, and
; the font the machine booted into. Clobbers everything a MOS call may.
fresh_control_block:
        ld      hl, CTL_BASE
        ld      de, CTL_BASE + 1
        ld      bc, CTL_END - CTL_BASE - 1
        ld      (hl), 0
        ldir

        ld      hl, magic
        ld      de, CTL_MAGIC
        ld      bc, 4
        ldir

        jp      boot_font

; note_shell: what the core needs to repair the shell and keep the blocks:
; the checksum of the shell's code, the path hub.bin was run from (MOS's
; LastBin$Run), and from it the path of hub.blk. Clobbers everything a MOS
; call may.
note_shell:
        ld      hl, shell_code_end - SHELL_BASE
        ld      (CTL_SUMLEN), hl
        call    CORE_SUM
        ld      (CTL_SUM), hl

        ld      hl, CTL_SELF            ; zeroed, so the path ends within it
        ld      de, CTL_SELF + 1
        ld      bc, 63
        ld      (hl), 0
        ldir
        ld      hl, v_lastbin
        ld      ix, CTL_SELF
        ld      de, 63                  ; leaves room for the terminator
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08

        jp      set_blkpath

; greet: the banner, or the resume message. Starting afresh, the arguments
; are read first: after a reset they were the ones from before it, and the
; script position kept in the control block goes with them.
;
; In:   HL = the arguments. Clobbers everything a MOS call may.
greet:
        ld      a, (RESUMING)
        or      a, a
        jr      nz, @resumed
        call    parse_args
        ld      hl, msg_banner
        jp      print

@resumed:
        ld      hl, msg_resumed
        jp      print

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
