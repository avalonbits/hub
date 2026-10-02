; shell/data.s -- Strings and VDU sequences. Kept in this order: moving them moves every
; address after them.
;
; Part of the shell; hub.s includes it, in order.

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
