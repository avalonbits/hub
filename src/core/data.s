; core/data.s -- Constants and messages. Kept last, in this order: moving them moves
; every address after them.
;
; Part of the core; core.s includes it, in order.

; ----------------------------------------------------------------------------
; Constants and messages.
; ----------------------------------------------------------------------------

; Entries in mos_errors[] in MOS 3.0.2 (src/mos.c): 0-19 are FatFS's, 20-26
; MOS's own. MOS's prompt prints a message only for codes below this.
MOS_ERRORS:     equ     27

try_prefix:     db      "Try "                  ; no terminator: build_cmd copies 4
v_try_rc:       db      "Try$ReturnCode", 0
blk_magic:      db      "BLK0"
msg_blocks_lost: db     "hub: client blocks lost", 13, 10, 0
nlcr:           db      10, 13, 0               ; MOS's own order, "\n\r"
msg_long:       db      "hub: line too long", 13, 10, 0
msg_reloaded:   db      "hub: shell reloaded", 13, 10, 0
msg_lost:       db      "hub: cannot reload the shell; reset the machine", 13, 10, 0

core_end:
