; core/blocks.s -- Client blocks, and their copy on the card that survives a moslet.
;
; Part of the core; core.s includes it, in order.

; ============================================================================
; Keeping the client blocks
; ============================================================================
;
; The blocks live in the moslet area, above the shell, where a big enough
; moslet (nano is 6.5 KB) loads over them. So the core keeps a copy on the
; card: before each command, if the blocks' checksum differs from the one
; taken at the last save, they are saved again -- the header, the directory
; and the part of the data in use, as one file next to hub.bin. After a
; moslet, they are restored from it.
;
; What a restore can lose is only what a program wrote to its block during
; the same command in which it then ran a moslet itself: the copy on the card
; is from before that command started.
; ============================================================================

; ----------------------------------------------------------------------------
; init_blocks: an empty block area.            Clobbers A, BC, DE, HL.
; ----------------------------------------------------------------------------
init_blocks:
        ld      hl, blk_magic
        ld      de, BLK_MAGIC
        ld      bc, 4
        ldir
        ld      hl, BLK_DATA
        ld      (BLK_NEXT), hl
        xor     a, a
        ld      (BLK_COUNT), a

        ret

; ----------------------------------------------------------------------------
; blocks_valid: Z if the block area's header makes sense -- the magic is
; there and BLK_NEXT lies within the area. Clobbers A, B, DE, HL.
; ----------------------------------------------------------------------------
blocks_valid:
        ld      hl, blk_magic
        ld      de, BLK_MAGIC
        ld      b, 4

@cmp:
        ld      a, (de)
        cp      a, (hl)
        ret     nz
        inc     de
        inc     hl
        djnz    @cmp

        ld      hl, (BLK_NEXT)
        ld      de, BLK_DATA
        or      a, a
        sbc     hl, de
        jr      c, @bad
        ld      hl, (BLK_NEXT)
        ld      de, BLK_END + 1
        or      a, a
        sbc     hl, de
        jr      nc, @bad
        xor     a, a                    ; Z

        ret

@bad:
        or      a, 1                    ; NZ

        ret

; ----------------------------------------------------------------------------
; blocks_len: BC = the bytes of the block area in use, header included.
; blocks_sum: HL = their checksum.
; Both assume blocks_valid. Clobber A, BC, DE, HL (and IY: blocks_sum).
; ----------------------------------------------------------------------------
blocks_len:
        ld      hl, (BLK_NEXT)
        ld      de, BLOCKS
        or      a, a
        sbc     hl, de
        push    hl
        pop     bc

        ret

blocks_sum:
        call    blocks_len
        ld      iy, BLOCKS

        jp      sum_range

; ----------------------------------------------------------------------------
; snapshot_blocks: save the blocks if they have changed since the last save.
; save_blocks: save them regardless.
;
; mos_save (API 0x02): HL = file name, DE = address, BC = length; A = 0 when
; saved. A failed save leaves CTL_BLKSUM as it was, so the next command tries
; again. Clobbers everything a MOS call may.
; ----------------------------------------------------------------------------
snapshot_blocks:
        IF SNAPSHOT
        call    blocks_valid
        ret     nz                      ; never save a damaged area
        call    blocks_sum
        ld      de, (CTL_BLKSUM)
        or      a, a
        sbc     hl, de
        ret     z                       ; unchanged
        ENDIF

save_blocks:
        IF SNAPSHOT
        call    blocks_sum
        push    hl
        call    blocks_len
        ld      hl, CTL_BLKPATH
        ld      de, BLOCKS
        ld      a, mos_save
        rst.lil $08
        pop     hl
        or      a, a
        ret     nz
        ld      (CTL_BLKSUM), hl
        ENDIF

        ret

; ----------------------------------------------------------------------------
; restore_blocks: after a moslet, put the blocks back from the card.
;
; Falls back to what is in memory if the file can't be read but the area
; still looks valid, and to an empty area (with a message) if not.
; Clobbers everything a MOS call may.
; ----------------------------------------------------------------------------
restore_blocks:
        IF SNAPSHOT
        ld      hl, CTL_BLKPATH
        ld      de, BLOCKS
        ld      bc, BLK_END - BLOCKS
        ld      a, mos_load
        rst.lil $08
        ENDIF

        call    blocks_valid
        jr      z, @done
        call    init_blocks
        ld      hl, msg_blocks_lost
        call    print

@done:
        call    blocks_sum
        ld      (CTL_BLKSUM), hl

        ret
