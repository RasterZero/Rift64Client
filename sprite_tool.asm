// C64 sprite placement helper routines.
//
// These routines use a small parameter block so callers can update a whole
// sprite or just one attribute. X positions are 9-bit: SpriteXLo plus
// SpriteXHi bit 0. Values beyond 255 are written through $D010.
//
// Multicolor sprite support:
//   $D01C = per-sprite multicolor enable (1 bit per sprite)
//   $D025 = shared multicolor color 0 (pixel bits 01)
//   $D026 = shared multicolor color 1 (pixel bits 11)
//   $D027+n = individual sprite color  (pixel bits 10)
//   $D017 = Y expansion (1 bit per sprite, 2x height)
//   $D01D = X expansion (1 bit per sprite, 2x width)
//   $D01B = sprite-background priority (1 bit per sprite)

.const SPRITE_X_BASE = $d000
.const SPRITE_Y_BASE = $d001
.const SPRITE_X_MSB  = $d010
.const SPRITE_ENABLE = $d015
.const SPRITE_EXPAND_Y = $d017
.const SPRITE_PRIORITY = $d01b
.const SPRITE_MULTICOLOR = $d01c
.const SPRITE_EXPAND_X = $d01d
.const SPRITE_SHARED_COLOR_0 = $d025
.const SPRITE_SHARED_COLOR_1 = $d026
.const SPRITE_COLOR  = $d027
.const SPRITE_PTRS   = $07f8
.const VIC_BANK_REG  = $dd00
.const VIC_BANK_DDR  = $dd02

// SpriteId:      0-7
// SpriteXLo:     low 8 bits of X
// SpriteXHi:     bit 0 is X bit 8
// SpriteY:       Y position
// SpriteColor:   0-15
// SpritePointer: sprite data block index within the active VIC bank
// SpriteVicBank: CIA2 bank bits, where 0=$C000, 1=$8000, 2=$4000, 3=$0000
SpriteId:
  .byte 0
SpriteXLo:
  .byte 0
SpriteXHi:
  .byte 0
SpriteY:
  .byte 0
SpriteColor:
  .byte 1
SpritePointer:
  .byte 0
SpriteVicBank:
  .byte 3

sprite_set_full:
  jsr sprite_set_vic_bank
  jsr sprite_set_pointer
  jsr sprite_set_color
  jsr sprite_set_position
  jmp sprite_enable

sprite_set_position:
  jsr sprite_offset_for_id
  lda SpriteXLo
  sta SPRITE_X_BASE,x
  lda SpriteY
  sta SPRITE_Y_BASE,x
  jsr sprite_mask_for_id
  lda SpriteXHi
  and #1
  bne sprite_set_x_msb
  lda SpriteMask
  eor #$ff
  and SPRITE_X_MSB
  sta SPRITE_X_MSB
  rts
sprite_set_x_msb:
  lda SpriteMask
  ora SPRITE_X_MSB
  sta SPRITE_X_MSB
  rts

sprite_set_color:
  ldx SpriteId
  cpx #8
  bcc sprite_color_id_ok
  ldx #7
sprite_color_id_ok:
  lda SpriteColor
  and #$0f
  sta SPRITE_COLOR,x
  rts

sprite_set_pointer:
  // Sprite pointers live in the last 8 bytes of the active screen matrix
  // ($xxF8). Track the screen base so pointers follow a relocated screen:
  // hi byte = screen_base_hi + 3 (4th page of the 1KB screen slot).
  lda screen_base_hi
  clc
  adc #3
  sta sprite_ptr_store+2
  ldx SpriteId
  cpx #8
  bcc sprite_pointer_id_ok
  ldx #7
sprite_pointer_id_ok:
  lda SpritePointer
sprite_ptr_store:
  sta SPRITE_PTRS,x
  rts

sprite_enable:
  jsr sprite_mask_for_id
  lda SpriteMask
  ora SPRITE_ENABLE
  sta SPRITE_ENABLE
  rts

sprite_disable:
  jsr sprite_mask_for_id
  lda SpriteMask
  eor #$ff
  and SPRITE_ENABLE
  sta SPRITE_ENABLE
  rts

sprite_set_vic_bank:
  lda VIC_BANK_DDR
  ora #%00000011
  sta VIC_BANK_DDR
  lda SpriteVicBank
  and #3
  sta SpriteBankBits
  lda VIC_BANK_REG
  and #%11111100
  ora SpriteBankBits
  sta VIC_BANK_REG
  rts

sprite_offset_for_id:
  lda SpriteId
  and #7
  asl
  tax
  rts

sprite_mask_for_id:
  lda SpriteId
  and #7
  tax
  lda SpriteMaskTable,x
  sta SpriteMask
  rts

SpriteMask:
  .byte 0
SpriteBankBits:
  .byte 0
SpriteMaskTable:
  .byte $01,$02,$04,$08,$10,$20,$40,$80

// --- Multicolor sprite parameter block ---

SpriteMulticolorFlag:
  .byte 0
SpriteExpandXFlag:
  .byte 0
SpriteExpandYFlag:
  .byte 0
SpritePriorityFlag:
  .byte 0
SpriteSharedColor0:
  .byte 0
SpriteSharedColor1:
  .byte 0

// --- Multicolor sprite functions ---

// Generic sprite bit-flag setter using SMC.
// Each entry patches the target register address then jumps to shared logic.
sprite_set_multicolor:
  lda #<SPRITE_MULTICOLOR
  ldx #>SPRITE_MULTICOLOR
  ldy SpriteMulticolorFlag
  jmp sprite_bit_flag_apply

sprite_set_expand_x:
  lda #<SPRITE_EXPAND_X
  ldx #>SPRITE_EXPAND_X
  ldy SpriteExpandXFlag
  jmp sprite_bit_flag_apply

sprite_set_expand_y:
  lda #<SPRITE_EXPAND_Y
  ldx #>SPRITE_EXPAND_Y
  ldy SpriteExpandYFlag
  jmp sprite_bit_flag_apply

sprite_set_priority:
  lda #<SPRITE_PRIORITY
  ldx #>SPRITE_PRIORITY
  ldy SpritePriorityFlag
  jmp sprite_bit_flag_apply

// Generic: A=register lo, X=register hi, Y=flag value (0=clear, nonzero=set).
sprite_bit_flag_apply:
  sta sbf_load+1
  sta sbf_store+1
  sta sbf_load2+1
  sta sbf_store2+1
  stx sbf_load+2
  stx sbf_store+2
  stx sbf_load2+2
  stx sbf_store2+2
  sty sbf_flag
  jsr sprite_mask_for_id
  lda sbf_flag
  beq sbf_clear
  // Set bit: register |= mask
sbf_load: lda $d01c
  ora SpriteMask
sbf_store: sta $d01c
  rts
sbf_clear:
  // Clear bit: register &= ~mask
  lda SpriteMask
  eor #$ff
  sta sbf_invmask
sbf_load2: lda $d01c
  and sbf_invmask
sbf_store2: sta $d01c
  rts
sbf_flag: .byte 0
sbf_invmask: .byte 0

sprite_set_shared_colors:
  // Write the two global multicolor shared colors.
  lda SpriteSharedColor0
  and #$0f
  sta SPRITE_SHARED_COLOR_0
  lda SpriteSharedColor1
  and #$0f
  sta SPRITE_SHARED_COLOR_1
  rts

sprite_set_full_mc:
  // Full multicolor sprite setup: position, color, pointer, bank,
  // multicolor, expansion, priority, shared colors, then enable/disable.
  jsr sprite_set_vic_bank
  jsr sprite_set_pointer
  jsr sprite_set_color
  jsr sprite_set_position
  jsr sprite_set_multicolor
  jsr sprite_set_expand_x
  jsr sprite_set_expand_y
  jsr sprite_set_priority
  jsr sprite_set_shared_colors
  lda SpriteEnabled
  beq sprite_set_full_mc_disable
  jmp sprite_enable
sprite_set_full_mc_disable:
  jmp sprite_disable
