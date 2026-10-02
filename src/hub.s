; hub's shell: the prompt, and what starts hub. src/README.md is the guide to
; the code; this file is the shell's table of contents.
;
; MOS loads this as a moslet at SHELL_BASE. On start it copies the core into
; the on-chip SRAM and hands over to it; from then on the core calls back in
; through the jumps below. A moslet run later loads over this code, and the
; core reloads it from the card, so nothing here may hold state that has to
; survive a command: that lives in the control block.
;
;   hub               an interactive prompt, like MOS's own
;   hub -f <script>   run each line of a file, then leave (for tests)
;
; After a warm reset, running hub again (autoexec.txt, or F12) resumes
; where it was: the arguments are ignored then.

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"
        INCLUDE "hub.inc"
        INCLUDE "config.inc"

        ORG     SHELL_BASE

        jp      start
        ALIGN   64
        db      "MOS", 0, 1             ; moslet header: version 0, ADL
        blkb    3, 0

        jp      readline                ; SHELL_READLINE
        jp      job_start               ; SHELL_JOB_START
        jp      job_end                 ; SHELL_JOB_END
        jp      block_grow              ; SHELL_BLOCK_GROW

LINE_BUF:       equ     SHELL_VARS              ; 256
PROMPT_BUF:     equ     SHELL_VARS + 256        ; 128
SCRIPT_FH:      equ     SHELL_VARS + 384        ; 1
SKIP:           equ     SHELL_VARS + 385        ; 3
RESUMING:       equ     SHELL_VARS + 388        ; 1 while resuming after a reset
NUM_VAL:        equ     SHELL_VARS + 389        ; 3: number's value so far
NUM_NEG:        equ     SHELL_VARS + 392        ; 1: it had a '-'
NUM_DIG:        equ     SHELL_VARS + 393        ; 1: the digit being added

        INCLUDE "shell/start.s"
        INCLUDE "shell/lines.s"
        INCLUDE "shell/jobs.s"
        INCLUDE "shell/grow.s"
        INCLUDE "shell/font.s"
        INCLUDE "shell/script.s"
        INCLUDE "shell/text.s"
        INCLUDE "shell/data.s"

core_image:
        INCBIN  "core.bin"
core_image_end:

shell_code_end:
