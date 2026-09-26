; Where hub's two parts live, shared by the shell and the core.
;
; The core sits in the upper on-chip SRAM, above 12AM Commander's launcher and
; mailboxes (0xB7E000-0xB7F2FF). Nothing MOS loads ever lands there, so it is
; the part that gets control back from every command. The shell lives in the
; moslet area, where any moslet overwrites it; the core repairs it afterwards.

CORE_BASE:      equ     $b7f300         ; core code, copied here by the shell
CTL_BASE:       equ     $b7f980         ; control block; the core's code ends below
SRAM_END:       equ     $b80000

SHELL_BASE:     equ     $b0000          ; moslet load address
BLOCKS:         equ     $b1000          ; client blocks: directory, then data
SHELL_VARS:     equ     $b7000          ; shell scratch, outside the checksummed code
SHELL_END:      equ     $b8000          ; MOS reserves 0xB8000 up

; The core's own entry points, called by the shell.
CORE_MAIN:      equ     CORE_BASE + 0   ; run commands until the shell says stop
CORE_SUM:       equ     CORE_BASE + 4   ; checksum the shell's code
CORE_INIT:      equ     CORE_BASE + 8   ; record vectors, set up blocks, publish the API
HUB_HEADER:     equ     CORE_BASE + 12  ; the client API: see hub.inc

; The shell's entry point the core calls, at a fixed place after the MOS
; header so a reloaded shell answers at the same address.
SHELL_READLINE: equ     SHELL_BASE + $48 ; returns HL = line, or 0 to leave hub

; ---------------------------------------------------------------------------
; Control block. It is not part of the core's image, so copying the core in
; never overwrites it.
; ---------------------------------------------------------------------------
CTL_MAGIC:      equ     CTL_BASE + 0    ; "HUB0" while hub is running
CTL_SUMLEN:     equ     CTL_BASE + 4    ; bytes of shell code to checksum
CTL_SUM:        equ     CTL_BASE + 7    ; their checksum (24-bit sum)
CTL_MODE:       equ     CTL_BASE + 10   ; 0 = prompt, 1 = script
CTL_LINE:       equ     CTL_BASE + 11   ; script: index of the next line
CTL_RELOADS:    equ     CTL_BASE + 14   ; times the shell has been reloaded
CTL_VEC_I:      equ     CTL_BASE + 15   ; vector loop counter
CTL_SELF:       equ     CTL_BASE + 16   ; path hub.bin was run from (64)
CTL_SCRIPT:     equ     CTL_BASE + 80   ; script path (64)
CTL_RC:         equ     CTL_BASE + 144  ; Try$ReturnCode of the last command (3)
CTL_CMD:        equ     CTL_BASE + 148  ; "Try " + the line, for OSCLI (260)

; The queue. Jobs run in array order from CTL_NEXT; a frame's jobs are
; inserted at CTL_INSERT, straight after the job that is running, so a nested
; frame's work comes before the rest of the frame that ran it.
CTL_NJOBS:      equ     CTL_BASE + 408  ; jobs in the array
CTL_NEXT:       equ     CTL_BASE + 409  ; index of the next job to run
CTL_INSERT:     equ     CTL_BASE + 410  ; where hub_push puts the next job
CTL_DEPTH:      equ     CTL_BASE + 411  ; open frames
CTL_JOB:        equ     CTL_BASE + 412  ; index of the running job, or $FF
CTL_VEC_P:      equ     CTL_BASE + 413  ; vector loop pointer (3)

; The last frame to finish, copied out when its continuation starts, so the
; continuation can read its results after the frame itself has closed.
CTL_DONE:       equ     CTL_BASE + 416  ; tag (4), result (3), failed (1)

CTL_VECTORS:    equ     CTL_BASE + 424  ; 48 interrupt handlers (144)

CTL_FRAMES:     equ     CTL_BASE + 568  ; MAX_FRAMES frames
FRAME_SIZE:     equ     10
FRAME_TAG:      equ     0               ; 4 bytes, the client's name
FRAME_RESULT:   equ     4               ; result of its last job (3)
FRAME_FAILED:   equ     7               ; index of the job that stopped it, or $FF
FRAME_COUNT:    equ     8               ; jobs pushed so far
MAX_FRAMES:     equ     6

CTL_JOBS:       equ     CTL_BASE + 628  ; MAX_JOBS jobs
JOB_SIZE:       equ     100
JOB_FLAGS:      equ     0
JOB_FRAME:      equ     1               ; frame that pushed it
JOB_INDEX:      equ     2               ; its position in that frame
JOB_RESULT:     equ     3               ; (3)
JOB_CMD:        equ     6               ; the command, zero-terminated
JOB_CMD_MAX:    equ     JOB_SIZE - JOB_CMD - 1
MAX_JOBS:       equ     8

; Scratch for the API calls, which may not keep anything on the caller's
; stack between the MOS-free steps of a call.
CTL_PUSH_CMD:   equ     CTL_JOBS + MAX_JOBS * JOB_SIZE  ; command or tag (3)
CTL_PUSH_FLAGS: equ     CTL_PUSH_CMD + 3                ; flags for the job

CTL_END:        equ     CTL_PUSH_FLAGS + 1

CMD_MAX:        equ     255             ; longest line accepted, without "Try "
NVECTORS:       equ     48              ; MOS's interrupt vectors, numbered 0, 2, ... $5E

; ---------------------------------------------------------------------------
; Client blocks, in the moslet area. A directory of named blocks, then the
; blocks themselves, handed out by a bump allocator.
; ---------------------------------------------------------------------------
BLK_NEXT:       equ     BLOCKS + 0      ; next free byte (3)
BLK_COUNT:      equ     BLOCKS + 3      ; entries in use
BLK_DIR:        equ     BLOCKS + 4      ; MAX_BLOCKS entries
BLK_ENTRY:      equ     10              ; tag (4), address (3), size (3)
MAX_BLOCKS:     equ     16
BLK_DATA:       equ     BLK_DIR + MAX_BLOCKS * BLK_ENTRY
BLK_END:        equ     SHELL_VARS
