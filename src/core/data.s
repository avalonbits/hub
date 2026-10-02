; core/data.s -- Constants and messages. Kept last, in this order: moving them moves
; every address after them.
;
; Part of the core; core.s includes it, in order.

; ----------------------------------------------------------------------------
; Constants and messages.
; ----------------------------------------------------------------------------

try_prefix:     db      "Try "                  ; no terminator: build_cmd copies 4
v_try_rc:       db      "Try$ReturnCode", 0
blk_magic:      db      "BLK0"
msg_blocks_lost: db     "hub: client blocks lost", 13, 10, 0
msg_long:       db      "hub: line too long", 13, 10, 0
msg_reloaded:   db      "hub: shell reloaded", 13, 10, 0
msg_lost:       db      "hub: cannot reload the shell; reset the machine", 13, 10, 0

core_end:
