; shell/grow.s -- Growing a client block, for api_block.
;
; Part of the shell; hub.s includes it, in order.

; block_grow: grow a client block to the size asked for -- for api_block,
; when a program asks for more than its block holds, as a new version of the
; program with a bigger state does.
;
; In:   IX = the block's directory entry, IY = the size asked for, bigger
;       than its size.
; Out:  A = 0, HL = the block: its old contents kept, the rest zeroed, as a
;       new block is. A = 1, HL = 0 if there is no room; the block is then
;       as it was.
;
; The last block grows where it is. Any other is copied to BLK_NEXT, and the
; space it leaves is lost until hub next starts afresh: blocks are never
; freed. So a block can move, and a program must take its address again
; after asking for a bigger one.
block_grow:
        ld      hl, (ix+4)
        ld      de, (ix+7)
        add     hl, de                  ; its end
        ld      de, (BLK_NEXT)
        or      a, a
        sbc     hl, de
        jr      z, @in_place            ; the last block

        ld      hl, (BLK_NEXT)
        call    @fits
        jr      nc, @fail
        ld      hl, (ix+4)
        ld      de, (BLK_NEXT)
        ld      bc, (ix+7)
        ldir                            ; the old contents, to BLK_NEXT
        ld      hl, (BLK_NEXT)
        ld      (ix+4), hl
        jr      @grow

@in_place:
        ld      hl, (ix+4)
        call    @fits
        jr      nc, @fail

@grow:
        ld      hl, (ix+4)
        lea     de, iy+0
        add     hl, de
        ld      (BLK_NEXT), hl          ; it ends the blocks now

        lea     hl, iy+0
        ld      de, (ix+7)
        or      a, a
        sbc     hl, de
        push    hl
        pop     bc                      ; BC = the bytes added, at least 1
        ld      hl, (ix+4)
        add     hl, de                  ; HL = the first of them
        ld      (hl), 0                 ; zero it, then copy it forward
        dec     bc
        ld      a, b
        or      a, c
        jr      z, @zeroed              ; BCU is 0: blocks are under 64 KB
        push    hl
        pop     de
        inc     de
        ldir

@zeroed:
        lea     de, iy+0
        ld      (ix+7), de              ; its size
        ld      hl, (ix+4)
        xor     a, a

        ret

@fail:
        ld      hl, 0
        ld      a, 1

        ret

; @fits: carry set if a block of IY bytes starting at HL ends by BLK_END.
@fits:
        lea     de, iy+0
        add     hl, de
        ld      de, BLK_END + 1
        or      a, a
        sbc     hl, de

        ret
