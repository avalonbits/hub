; hub.inc -- the hub client API, for programs written with zap.
;
; FINDING HUB
;
; hub publishes a Number variable, Hub$API, holding the address of its API
; header. Read it with MOS's readvarval (API $31, C = 0, 3-byte buffer), then
; check the header's magic and version before calling anything:
;
;       +0      "HUB"                   HUB_MAGIC
;       +3      major version           HUB_MAJOR
;       +4      minor version           HUB_MINOR
;       +5      number of entries       HUB_COUNT
;       +6      JP hub_enter            one 4-byte jump per call, below
;       ...
;
; No variable, or a header that doesn't match, means hub isn't running: carry
; on as a standalone program.
;
; CALLING
;
; Add the entry's offset to the header address and call it -- for example
; with the address in IY and `call jp_iy` where jp_iy is `jp (iy)`. Every call
; follows MOS's own convention: ADL mode, arguments in HL and BC, status in A
; (0 = done), value in HL. IX and IY are preserved; BC and DE are not.
;
; Calls are made while hub is running your program, so they only record what
; to do: nothing runs until your program returns.

HUB_MAGIC:      equ     0
HUB_MAJOR:      equ     3
HUB_MINOR:      equ     4
HUB_COUNT:      equ     5

; hub_enter        HL = 4-byte tag naming the client, e.g. "CNT "
;                  Opens a frame: the jobs pushed next, and the continuation
;                  that brings the client back. A = 1 if frames are too deep.
HUB_ENTER:      equ     6

; hub_push         HL = command, as typed at the prompt; C = flags
;                  Queues it in the open frame, after anything already pushed.
;                  A = 1 with no open frame, 2 if the queue is full,
;                  3 if the command is too long (HUB_CMD_MAX).
HUB_PUSH:       equ     10

; hub_return_to    HL = command
;                  Sets the frame's continuation: run last, whatever happened
;                  to the jobs before it. Push it after the frame's jobs.
;                  Errors as hub_push.
HUB_RETURN_TO:  equ     14

; hub_last_result  In a continuation: HL = the result of the last job of the
;                  frame it closes. Anywhere else: 0.
HUB_LAST_RESULT: equ    18

; hub_failed_job   In a continuation: HL = the index (from 0, in push order)
;                  of the job that stopped its frame, or -1 if none did.
;                  Anywhere else: -1.
HUB_FAILED_JOB: equ     22

; hub_block        HL = 4-byte tag, BC = size
;                  HL = a block of memory that keeps its contents between
;                  your program's runs, zeroed when first created; 0 if there
;                  is no room or the tag exists with a smaller size.
HUB_BLOCK:      equ     26

; hub_depth        HL = the number of open frames.
HUB_DEPTH:      equ     30

; hub_resumed      In a continuation: HL = 1 if the machine was reset while
;                  its frame's job was running -- the job then counts as
;                  failed, with HUB_RESULT_RESET -- and 0 otherwise.
;                  Anywhere else: 0. (Since version 0.2.)
HUB_RESUMED:    equ     34

HUB_RESULT_RESET:       equ     255     ; the result of a job a reset cut short

; Flags for hub_push.
HUB_STOP_ON_ERROR:      equ     $01     ; a non-zero result skips the rest of the
                                        ; frame's jobs, up to its continuation
HUB_USER_PROGRAM:       equ     $02     ; reserved: reset the screen first
HUB_PAUSE_AFTER:        equ     $04     ; reserved: "press a key" afterwards
HUB_CONTINUATION:       equ     $80     ; set by hub_return_to; not for hub_push

HUB_CMD_MAX:    equ     93              ; longest command a job can hold
