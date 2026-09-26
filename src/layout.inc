; Where hub's two parts live, shared by the shell and the core.
;
; The core sits in the upper on-chip SRAM, above 12AM Commander's launcher and
; mailboxes (0xB7E000-0xB7F2FF). Nothing MOS loads ever lands there, so it is
; the part that gets control back from every command. The shell lives in the
; moslet area, where any moslet overwrites it; the core repairs it afterwards.

CORE_BASE:      equ     $b7f300         ; core code, copied here by the shell
CTL_BASE:       equ     $b7fe00         ; control block; the core's code ends below
SRAM_END:       equ     $b80000

SHELL_BASE:     equ     $b0000          ; moslet load address
SHELL_VARS:     equ     $b7000          ; shell scratch, outside the checksummed code
SHELL_END:      equ     $b8000          ; MOS reserves 0xB8000 up

; The shell's entry points the core calls, at fixed places after the MOS
; header so a reloaded shell answers at the same addresses.
SHELL_READLINE: equ     SHELL_BASE + $48 ; returns HL = line, or 0 to leave hub

; Control block. It is not part of the core's image, so copying the core in
; never overwrites it.
CTL_MAGIC:      equ     CTL_BASE + 0    ; "HUB0" while hub is running
CTL_SUMLEN:     equ     CTL_BASE + 4    ; bytes of shell code to checksum
CTL_SUM:        equ     CTL_BASE + 7    ; their checksum (24-bit sum)
CTL_MODE:       equ     CTL_BASE + 10   ; 0 = prompt, 1 = script
CTL_LINE:       equ     CTL_BASE + 11   ; script: index of the next line
CTL_RELOADS:    equ     CTL_BASE + 14   ; times the shell has been reloaded
CTL_SELF:       equ     CTL_BASE + 16   ; path hub.bin was run from (64)
CTL_SCRIPT:     equ     CTL_BASE + 80   ; script path (64)
CTL_RC:         equ     CTL_BASE + 144  ; Try$ReturnCode of the last command (3)
CTL_CMD:        equ     CTL_BASE + 148  ; "Try " + the line, for OSCLI (260)
CTL_END:        equ     CTL_BASE + 408

CMD_MAX:        equ     255             ; longest line accepted, without "Try "
