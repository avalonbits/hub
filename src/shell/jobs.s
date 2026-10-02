; shell/jobs.s -- Around a user program: the prompt's screen before, the capture and the
; pause after.
;
; Part of the shell; hub.s includes it, in order.

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
        bit     FLAG_USER_BIT, a
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
        bit     FLAG_USER_BIT, a
        call    nz, capture
        pop     af
        push    af
        ENDIF

        bit     FLAG_PAUSE_BIT, a
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
        bit     FLAG_USER_BIT, a
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
