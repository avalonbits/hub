; core/repair.s -- Noticing a moslet loaded over the shell, and reloading it.
;
; Part of the core; core.s includes it, in order.

; ----------------------------------------------------------------------------
; check_shell: reload the shell if something loaded over it.
;
; In:   CTL_SUMLEN, CTL_SUM and CTL_SELF, set by the shell at start-up.
; Out:  the shell's code matches the checksum again, or the machine stops.
;       Clobbers everything a MOS call may.
;
; The shell's code is summed and compared with the sum taken at start-up.
; A difference means something was loaded into the moslet area: almost always
; a moslet the user ran (nano, say), directly or from a script or from inside
; another program. The shell is then reloaded from the file hub was started
; from -- the path MOS put in LastBin$Run, which the shell copied to CTL_SELF.
;
; mos_load (API 0x01) arguments:
;   HL = file name   DE = load address   BC = the most it may load
; It returns A = 0 on success. The limit keeps a wrong file from running on
; past the shell's area into the client blocks and beyond.
;
; Only the code is summed, not the client blocks or the shell's variables,
; which change as it runs. A plain sum can in principle miss a change that
; happens to add up to the same total; for telling "hub's code" from "some
; other program's code" that is not a practical concern.
;
; A moslet that overwrote the shell may also have overwritten the client
; blocks above it, so they are restored from the card too (restore_blocks).
;
; If the reload fails there is nothing safe to do: every return address above
; us on the stack points into the shell, which isn't there. So the core says
; so and stops, and the user resets the machine.
; ----------------------------------------------------------------------------
check_shell:
        IF REPAIR
        call    shell_sum               ; HL = the sum now
        ld      de, (CTL_SUM)           ; DE = the sum at start-up
        or      a, a
        sbc     hl, de
        ret     z                       ; unchanged

        ld      hl, CTL_SELF
        ld      de, SHELL_BASE
        ld      bc, BLOCKS - SHELL_BASE
        ld      a, mos_load
        rst.lil $08
        or      a, a
        jr      nz, @failed

        ld      hl, CTL_RELOADS
        inc     (hl)                    ; counted, for tests and diagnostics
        ld      hl, msg_reloaded
        call    print

        jp      restore_blocks          ; the moslet may have reached them too

@failed:
        ld      hl, msg_lost
        call    print

@stop:
        jr      @stop
        ENDIF

        ret

; ----------------------------------------------------------------------------
; shell_sum: HL = the checksum of the shell's code.
; sum_range: HL = the checksum of BC bytes from IY.
;
; In:   shell_sum: CTL_SUMLEN, how many bytes from SHELL_BASE.
;       sum_range: IY = start, BC = length, not 0.
; Out:  HL. Clobbers A, BC, DE, IY.
;
; The sum so far is rotated left one bit before each byte is added, so the
; checksum depends on where each byte is, not just which bytes there are: a
; block whose two bytes swap places reads as changed. Rotated, not shifted:
; `add hl, hl` alone would push each byte out of the 24 bits after 24 more,
; and only the last 24 bytes would count -- a moslet loading over the start
; of the shell would go unnoticed. `adc` puts the bit that fell off the top
; back in at the bottom, along with the byte.
;
; The loop's end test: in ADL mode `dec bc` sets no flags, and testing B and C
; alone would miss the upper byte. Adding BC to a zeroed HL with carry clear
; sets Z only when all 24 bits of BC are zero.
; ----------------------------------------------------------------------------
shell_sum:
        ld      iy, SHELL_BASE
        ld      bc, (CTL_SUMLEN)

sum_range:
        ld      hl, 0
        ld      de, 0

@next:
        ld      e, (iy+0)
        add     hl, hl                  ; carry = the bit that fell off
        adc     hl, de                  ; the byte, and that bit, back in
        inc     iy
        dec     bc
        push    hl
        ld      hl, 0
        or      a, a                    ; clear carry for the adc
        adc     hl, bc                  ; Z if BC == 0
        pop     hl
        jr      nz, @next

        ret
