; MOS API function numbers used by chain (MOS 3.0.2, src/mos_api.inc).
; Each is called with `ld a, <number>` then `rst.lil $08`.

mos_load:               equ     $01
mos_editline:           equ     $09
mos_fopen:              equ     $0A
mos_fclose:             equ     $0B
mos_fgetc:              equ     $0C
mos_feof:               equ     $0E
mos_getError:           equ     $0F
mos_oscli:              equ     $10
mos_setkbvector:        equ     $1D
mos_readvarval:         equ     $31

; mos_fopen modes (FatFS)
fa_read:                equ     $01

; readvarval flag: expand the value into a string
var_expand:             equ     3
