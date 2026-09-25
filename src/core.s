; chain's core: the part that gets control back from every command.
;
; It runs from the on-chip SRAM at CORE_BASE, where nothing MOS loads can
; reach it. Each turn of its loop asks the shell for a line, runs it through
; MOS exactly as MOS's own prompt would, cleans up after it, and repairs the
; shell if a moslet loaded over it.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"
        INCLUDE "config.inc"

        ORG     CORE_BASE

; The core's entry points, at fixed offsets the shell calls.
        jp      core_main               ; CORE_BASE + 0
        jp      shell_sum               ; CORE_BASE + 4

; core_main: run commands until the shell hands back HL = 0.
;
; A line goes to OSCLI as "Try <line>". Try runs it with MOS's full prompt
; rules (Run$Path, run-by-extension, /bin), where OSCLI alone only finds
; moslets, and unlike Do it doesn't GSTrans the line first, so nothing is
; expanded twice. The result lands in Try$ReturnCode.
core_main:
        push    ix
        push    iy

@loop:
        call    check_shell
        call    SHELL_READLINE
        call    hl_is_zero
        jr      z, @done

        call    build_cmd
        jr      c, @loop

        ld      hl, CTL_CMD
        ld      a, mos_oscli
        rst.lil $08

        IF GUARDS
        call    guards
        ENDIF

        call    report
        jr      @loop

@done:
        pop     iy
        pop     ix

        ret

; build_cmd: CTL_CMD = "Try " + the line at HL. Carry set if it was too long.
build_cmd:
        push    hl
        ld      hl, try_prefix
        ld      de, CTL_CMD
        ld      bc, 4
        ldir
        pop     hl
        ld      b, CMD_MAX

@copy:
        ld      a, (hl)
        ld      (de), a
        or      a, a
        ret     z
        inc     hl
        inc     de
        djnz    @copy

        ld      hl, msg_long
        call    print
        scf

        ret

; guards: undo what a command may have left behind.
;
; A keyboard hook left installed would have MOS calling into whatever loads
; next from the UART interrupt. MOS never closes a program's files, and has
; only eight handles; chain holds none while a command runs.
guards:
        ld      hl, 0
        ld      c, 0
        ld      a, mos_setkbvector
        rst.lil $08

        ld      c, 0
        ld      a, mos_fclose
        rst.lil $08

        ret

; report: print MOS's message for a failed command, as MOS's prompt does.
report:
        ld      hl, 0
        ld      (CTL_RC), hl
        ld      hl, v_try_rc
        ld      ix, CTL_RC
        ld      de, 3
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        or      a, a
        ret     nz

        ld      hl, (CTL_RC)
        call    hl_is_zero
        ret     z

        ld      de, MOS_ERRORS
        or      a, a
        sbc     hl, de
        ret     nc                      ; MOS prints nothing past its table

        ld      a, (CTL_RC)
        ld      e, a
        ld      hl, CTL_CMD
        ld      bc, CMD_MAX
        ld      a, mos_getError
        rst.lil $08

        ld      hl, nlcr
        call    print
        ld      hl, CTL_CMD
        call    print
        ld      hl, nlcr

        jp      print

; check_shell: reload the shell if something loaded over it.
check_shell:
        IF REPAIR
        call    shell_sum
        ld      de, (CTL_SUM)
        or      a, a
        sbc     hl, de
        ret     z

        ld      hl, CTL_SELF
        ld      de, SHELL_BASE
        ld      bc, SHELL_VARS - SHELL_BASE
        ld      a, mos_load
        rst.lil $08
        or      a, a
        jr      nz, @failed

        ld      hl, CTL_RELOADS
        inc     (hl)
        ld      hl, msg_reloaded

        jp      print

; Nothing to return to: every return address above us is in the shell.
@failed:
        ld      hl, msg_lost
        call    print

@stop:
        jr      @stop
        ENDIF

        ret

; shell_sum: HL = 24-bit sum of the shell's code bytes.
shell_sum:
        ld      iy, SHELL_BASE
        ld      bc, (CTL_SUMLEN)
        ld      hl, 0
        ld      de, 0

@next:
        ld      e, (iy+0)
        add     hl, de
        inc     iy
        dec     bc
        push    hl
        ld      hl, 0
        or      a, a
        adc     hl, bc
        pop     hl
        jr      nz, @next

        ret

; hl_is_zero: Z set if all 24 bits of HL are zero. HL is unchanged.
hl_is_zero:
        push    de
        ld      de, 0
        or      a, a
        sbc     hl, de
        add     hl, de
        pop     de

        ret

; print: the zero-terminated string at HL.
print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

MOS_ERRORS:     equ     27              ; entries in MOS 3.0.2's mos_errors[]

try_prefix:     db      "Try "
v_try_rc:       db      "Try$ReturnCode", 0
nlcr:           db      10, 13, 0
msg_long:       db      "chain: line too long", 13, 10, 0
msg_reloaded:   db      "chain: shell reloaded", 13, 10, 0
msg_lost:       db      "chain: cannot reload the shell; reset the machine", 13, 10, 0

core_end:
