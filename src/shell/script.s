; shell/script.s -- Reading a script file a line at a time.
;
; Part of the shell; hub.s includes it, in order.

; read_line: the next line of the script into LINE_BUF, without its CR/LF.
;
; In:   SCRIPT_FH = the open script.
; Out:  carry clear: LINE_BUF holds the line, zero-terminated; past 250
;       characters the rest of the line is dropped. Carry set: the file had
;       nothing left. Clobbers everything a MOS call may.
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

; close_script: close SCRIPT_FH. Clobbers as a MOS call.
close_script:
        ld      a, (SCRIPT_FH)
        ld      c, a
        ld      a, mos_fclose
        rst.lil $08

        ret
