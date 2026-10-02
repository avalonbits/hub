; core/entry.s -- The core's fixed entry points, and the API header programs find through
; Hub$API. Their addresses are part of hub's contract: never move them.
;
; Part of the core; core.s includes it, in order.

; ----------------------------------------------------------------------------
; Entry points. Each `jp` is four bytes in ADL mode, so these sit at exactly
; CORE_BASE + 0, 4 and 8. Only ever add entries at the end.
; ----------------------------------------------------------------------------
        jp      core_main               ; CORE_BASE + 0
        jp      shell_sum               ; CORE_BASE + 4
        jp      core_init               ; CORE_BASE + 8

; ----------------------------------------------------------------------------
; The client API: a header at HUB_HEADER (CORE_BASE + 12), which the Number
; variable Hub$API points to, followed by one jump per call. hub.inc gives the
; offsets and what each call takes and returns. A client checks the magic and
; the version before calling anything, so the order here is part of the
; contract: new calls go at the end, with HUB_MINOR raised.
; ----------------------------------------------------------------------------
api_header:
        db      "HUB"                   ; HUB_MAGIC
        db      0                       ; HUB_MAJOR
        db      4                       ; HUB_MINOR
        db      API_COUNT               ; HUB_COUNT: 9, unless a test build
                                        ; poses as an older hub
        jp      api_enter               ; HUB_ENTER
        jp      api_push                ; HUB_PUSH
        jp      api_return_to           ; HUB_RETURN_TO
        jp      api_last_result         ; HUB_LAST_RESULT
        jp      api_failed_job          ; HUB_FAILED_JOB
        jp      api_block               ; HUB_BLOCK
        jp      api_depth               ; HUB_DEPTH
        jp      api_resumed             ; HUB_RESUMED
        jp      api_user_screen         ; HUB_USER_SCREEN
