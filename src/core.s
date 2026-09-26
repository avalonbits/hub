; ============================================================================
; hub's core
; ============================================================================
;
; The core is the part of hub that gets control back from every command.
;
; WHY THERE IS A CORE AT ALL
;
; The Agon runs one program at a time. MOS loads a normal program at 0x40000
; and a moslet at 0xB0000, calls it, and when it returns, control goes back to
; whoever asked MOS to run it. hub wants to be that "whoever" for every
; command, so that it can run the next one, clean up after the last one, and
; eventually bring programs back when they ask. That means the code that calls
; MOS -- and so the code MOS returns into -- must still be intact after any
; command, whatever that command loaded.
;
; Nothing MOS loads is ever placed in the on-chip SRAM (0xB7E000-0xB7FFFF): not
; normal programs, not moslets, not MOS itself. So the core lives there, and
; is the only code on the path back from a command:
;
;       MOS  --calls-->  shell (0xB0000)  --calls-->  core (0xB7F300)
;                                                        |
;                                           OSCLI  <-----+   each command
;                                             |
;                                  the command runs, returns to the core
;
; The shell -- everything else in hub -- is a moslet at 0xB0000, and any
; moslet the user runs loads over it. The core notices that after the command
; and reloads the shell from the card before calling into it again.
;
; WHERE THINGS ARE (see layout.inc)
;
;   0xB7E000-0xB7F2FF   12AM Commander's launcher and mailboxes. Not ours;
;                       hub starts above them so both can be present.
;   0xB7F300            CORE_BASE: this file's code, copied here by the shell
;                       at start-up. It must end before CTL_BASE; the Makefile
;                       fails the build if it doesn't.
;   0xB7FE00            CTL_BASE: the control block, hub's state. It is not
;                       part of this image, so copying the core in never
;                       overwrites it, and it survives a reloaded shell.
;   0xB80000            SRAM_END.
;
; HOW THE SHELL USES THE CORE
;
; The shell calls two fixed entry points, the jump table at the very start of
; this image (so the addresses never move when the code does):
;
;   CORE_BASE + 0   core_main   run commands until the shell says stop
;   CORE_BASE + 4   shell_sum   checksum the shell's code (used at start-up)
;
; and the core calls back into the shell at one fixed address, SHELL_READLINE,
; which returns the next line to run (or HL = 0 to leave hub). Those three
; addresses are the whole contract between the two parts.
;
; CALLING MOS
;
; Every MOS call here is `ld a, <function>` then `rst.lil $08`, with the
; arguments in the registers MOS documents for that function (src/mos_api.asm
; in MOS 3.0.2). MOS returns its status in A. It does not promise to keep any
; other register, so this code assumes every MOS call clobbers A, BC, DE, HL,
; IX, IY and the flags, and reloads whatever it needs afterwards.
;
; STACK
;
; The core runs on MOS's own 2 KB SPL stack (0xBF800-0xBFFFF), which it shares
; with MOS, with every command MOS runs for it until that command switches to
; its own stack, and with FatFS, which puts a ~512-byte long-filename buffer
; on it during every file open and load. Nothing in the core keeps data on
; the stack beyond a few saved registers; buffers live in the control block.
;
; ASSEMBLY-TIME SWITCHES (config.inc, written by the Makefile)
;
;   GUARDS  1 = clean up after every command. 0 exists only so the tests can
;             show their checks fail without it.
;   REPAIR  1 = reload the shell when a moslet has overwritten it. 0 likewise.
; ============================================================================

        ASSUME  ADL=1
        INCLUDE "mos_api.inc"
        INCLUDE "layout.inc"
        INCLUDE "config.inc"

        ORG     CORE_BASE

; ----------------------------------------------------------------------------
; Entry points. Each `jp` is four bytes in ADL mode, so these sit at exactly
; CORE_BASE + 0 and CORE_BASE + 4. Only ever add entries at the end.
; ----------------------------------------------------------------------------
        jp      core_main               ; CORE_BASE + 0
        jp      shell_sum               ; CORE_BASE + 4

; ----------------------------------------------------------------------------
; core_main: run commands until the shell hands back HL = 0.
;
; In:   nothing. The control block must already be set up by the shell:
;       CTL_SUMLEN, CTL_SUM and CTL_SELF in particular, since the first thing
;       the loop does is check the shell against them.
; Out:  returns to the shell when the shell's readline returns HL = 0.
;       IX and IY are preserved for the caller; everything else is clobbered.
;
; Each turn of the loop:
;
;   1. check_shell   make sure the shell is intact before calling into it --
;                    the previous command may have been a moslet.
;   2. readline      ask the shell for the next line (prompt or script).
;   3. build_cmd     turn it into "Try <line>".
;   4. OSCLI         run it.
;   5. guards        clean up after it.
;   6. report        print MOS's message if it failed.
;
; Why "Try <line>" rather than the line itself or "Do <line>":
;
;   - OSCLI runs its argument with mos_exec(cmd, in_mos = false). With that
;     flag, a bare name like "aed" is only looked up as a moslet, because
;     MOS assumes a program calling OSCLI doesn't want to be overwritten by a
;     program at 0x40000. hub wants exactly that, so it needs the rules
;     MOS's own prompt uses: mos_exec(line, in_mos = true).
;   - Both Do and Try call mos_exec(line, true). But Do is declared with
;     expandArgs, so MOS runs GSTrans over the line before Do sees it, and
;     the command then expands it again: "Echo |<once>" would print nothing
;     instead of "<once>". Try is not, so a line is expanded exactly once,
;     as at MOS's prompt. test/run.sh checks this.
;   - Try always returns 0 itself and stores the command's real result in the
;     variable Try$ReturnCode, which report reads.
; ----------------------------------------------------------------------------
core_main:
        push    ix
        push    iy

@loop:
        call    check_shell             ; a moslet may have loaded over it
        call    SHELL_READLINE          ; HL = next line, or 0 to stop
        call    hl_is_zero
        jr      z, @done

        call    build_cmd               ; CTL_CMD = "Try " + line
        jr      c, @loop                ; too long: reported, skip it

        ld      hl, CTL_CMD
        ld      a, mos_oscli            ; run it; A = low byte of Try's own
        rst.lil $08                     ; result, always 0, so ignored

        IF GUARDS
        call    guards
        ENDIF

        call    report
        jr      @loop

@done:
        pop     iy
        pop     ix

        ret

; ----------------------------------------------------------------------------
; build_cmd: CTL_CMD = "Try " followed by the line at HL.
;
; In:   HL = the line, zero-terminated.
; Out:  carry clear: CTL_CMD holds the command, zero-terminated.
;       carry set:   the line was longer than CMD_MAX; a message has been
;                    printed and CTL_CMD is not usable.
;       Clobbers A, B, BC, DE, HL.
;
; The copy is needed, not just the prefix: mos_exec writes into the string it
; is given (mos_trim puts NULs in it), and the shell's line buffer is in the
; moslet area, where the command about to run may load over it.
;
; B counts down from CMD_MAX. DJNZ uses only the 8-bit B, which is why the
; limit is 255; CTL_CMD has room for "Try " + 255 + the terminator.
; ----------------------------------------------------------------------------
build_cmd:
        push    hl
        ld      hl, try_prefix
        ld      de, CTL_CMD
        ld      bc, 4
        ldir                            ; DE now points just after "Try "
        pop     hl
        ld      b, CMD_MAX

@copy:
        ld      a, (hl)
        ld      (de), a
        or      a, a                    ; the terminator? (also clears carry)
        ret     z
        inc     hl
        inc     de
        djnz    @copy

        ld      hl, msg_long
        call    print
        scf

        ret

; ----------------------------------------------------------------------------
; guards: undo what a command may have left behind.
;
; In:   nothing.
; Out:  clobbers everything a MOS call may.
;
; Runs after every command, whether or not the program knows about hub.
; Each of these is something MOS 3.0.2 doesn't clean up when a program exits:
;
;   Keyboard hook   A program can register a routine that MOS calls from the
;                   UART interrupt on every key event (API 0x1D). MOS never
;                   removes it. If the program forgets, MOS goes on calling
;                   into memory the next program has loaded over, from inside
;                   an interrupt. Setting HL = 0 removes any hook; with no
;                   hook, it does nothing. (C = 0: HL is a full 24-bit
;                   address, not one relative to MB.)
;
;   Open files      MOS has eight file handles and never closes a program's
;                   files for it. A program that leaks three leaves the next
;                   one with five. mos_fclose with C = 0 closes all of them.
;                   That is safe only because hub itself never holds a file
;                   open while a command runs: the shell opens its script,
;                   reads one line and closes it again before handing the
;                   line over.
;
; Not yet: interrupt vectors a program changed with API 0x14. Restoring them
; needs hub to record them at start-up; that is phase 1.
; ----------------------------------------------------------------------------
guards:
        ld      hl, 0                   ; no hook
        ld      c, 0                    ; HL is a 24-bit address
        ld      a, mos_setkbvector
        rst.lil $08

        ld      c, 0                    ; 0 = every open file
        ld      a, mos_fclose
        rst.lil $08

        ret

; ----------------------------------------------------------------------------
; report: print MOS's message for a failed command, as MOS's prompt does.
;
; In:   nothing; reads the variable Try$ReturnCode that Try just set.
; Out:  CTL_RC holds the result (0 if the variable couldn't be read).
;       Clobbers everything a MOS call may.
;
; MOS's own loop (main.c) prints "\n\r<message>\n\r" when a command returns a
; non-zero code that has an entry in its message table, and nothing at all
; for 0 or for codes past the table. This does the same, using MOS's table
; through mos_getError rather than a copy of it.
;
; Note that the code is not always what the program returned: when a program
; found on the run path returns 1, 4 or 5, mos_exec replaces it with 20,
; "Invalid command", since it can't tell a failing program from a missing
; one. MOS's prompt shows the same thing, so hub does too.
;
; readvarval (API 0x31) arguments:
;   HL = variable name        IX = where to put the value
;   DE = size of that buffer  IY = 0 (not iterating over several variables)
;   C  = 0 (the raw value: a Number comes back as its 3 bytes)
; ----------------------------------------------------------------------------
report:
        ld      hl, 0
        ld      (CTL_RC), hl            ; 0 unless the read succeeds
        ld      hl, v_try_rc
        ld      ix, CTL_RC
        ld      de, 3
        ld      iy, 0
        ld      c, 0
        ld      a, mos_readvarval
        rst.lil $08
        or      a, a
        ret     nz                      ; no Try$ReturnCode: nothing to say

        ld      hl, (CTL_RC)
        call    hl_is_zero
        ret     z                       ; success: MOS prints nothing

        ld      de, MOS_ERRORS
        or      a, a
        sbc     hl, de
        ret     nc                      ; past MOS's table: MOS prints nothing

; The code is below 27, so its low byte is all of it. CTL_CMD has served its
; purpose and doubles as the buffer for the message.
        ld      a, (CTL_RC)
        ld      e, a                    ; E = the error code
        ld      hl, CTL_CMD             ; HL = buffer
        ld      bc, CMD_MAX             ; BC = its size
        ld      a, mos_getError
        rst.lil $08

        ld      hl, nlcr
        call    print
        ld      hl, CTL_CMD
        call    print
        ld      hl, nlcr

        jp      print                   ; tail call: print returns for us

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
; past the shell's area into the shell's variables and beyond.
;
; Only the code is summed, not the shell's variables at SHELL_VARS, which
; change as it runs. A plain sum can in principle miss a change that happens
; to add up to the same total; for telling "hub's code" from "some other
; program's code" that is not a practical concern.
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
        ld      bc, SHELL_VARS - SHELL_BASE
        ld      a, mos_load
        rst.lil $08
        or      a, a
        jr      nz, @failed

        ld      hl, CTL_RELOADS
        inc     (hl)                    ; counted, for tests and diagnostics
        ld      hl, msg_reloaded

        jp      print

@failed:
        ld      hl, msg_lost
        call    print

@stop:
        jr      @stop
        ENDIF

        ret

; ----------------------------------------------------------------------------
; shell_sum: HL = the 24-bit sum of the shell's code bytes.
;
; In:   CTL_SUMLEN = how many bytes, from SHELL_BASE. Must not be 0.
; Out:  HL = the sum. Clobbers A, BC, DE, IY.
;
; DE is zeroed once and only E is ever loaded, so `add hl, de` adds one
; unsigned byte each time. The largest possible sum, 28 KB of 0xFF, is under
; 7.2 million and fits in 24 bits.
;
; The loop's end test: in ADL mode `dec bc` sets no flags, and testing B and C
; alone would miss the upper byte. Adding BC to a zeroed HL with carry clear
; sets Z only when all 24 bits of BC are zero.
; ----------------------------------------------------------------------------
shell_sum:
        ld      iy, SHELL_BASE
        ld      bc, (CTL_SUMLEN)
        ld      hl, 0
        ld      de, 0

@next:
        ld      e, (iy+0)
        add     hl, de
        inc     iy
        dec     bc
        push    hl
        ld      hl, 0
        or      a, a                    ; clear carry for the adc
        adc     hl, bc                  ; Z if BC == 0
        pop     hl
        jr      nz, @next

        ret

; ----------------------------------------------------------------------------
; hl_is_zero: Z set if all 24 bits of HL are zero.
;
; In:   HL.
; Out:  Z flag. HL and DE unchanged; carry cleared.
;
; `sbc hl, de` with DE = 0 and carry clear sets Z on the full 24-bit result.
; `add hl, de` then puts HL back without touching Z (ADD HL only sets carry).
; ----------------------------------------------------------------------------
hl_is_zero:
        push    de
        ld      de, 0
        or      a, a
        sbc     hl, de
        add     hl, de
        pop     de

        ret

; ----------------------------------------------------------------------------
; print: write the zero-terminated string at HL to the console.
;
; In:   HL = the string.
; Out:  clobbers A, BC, and whatever MOS's output routine does.
;
; RST 18h is MOS's "write a block" call: with BC = 0 it writes up to the
; delimiter in A instead of a count, so A = 0 means "up to the terminator".
; ----------------------------------------------------------------------------
print:
        ld      bc, 0
        xor     a, a
        rst.lil $18

        ret

; ----------------------------------------------------------------------------
; Constants and messages.
; ----------------------------------------------------------------------------

; Entries in mos_errors[] in MOS 3.0.2 (src/mos.c): 0-19 are FatFS's, 20-26
; MOS's own. MOS's prompt prints a message only for codes below this.
MOS_ERRORS:     equ     27

try_prefix:     db      "Try "                  ; no terminator: build_cmd copies 4
v_try_rc:       db      "Try$ReturnCode", 0
nlcr:           db      10, 13, 0               ; MOS's own order, "\n\r"
msg_long:       db      "hub: line too long", 13, 10, 0
msg_reloaded:   db      "hub: shell reloaded", 13, 10, 0
msg_lost:       db      "hub: cannot reload the shell; reset the machine", 13, 10, 0

core_end:
