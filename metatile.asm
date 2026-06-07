// metatile.asm
// Optimized metatile window renderer (KickAssembler / C64).
//
// Modes:
//   1 = raw 1x1 (map byte is the screen char)
//   2 = 2x2 metatile (map byte is a tile id)
//   3 = 3x3 metatile (map byte is a tile id)
//
// Metatile data layout (mode 2 / 3): parallel slot arrays, each one full
// page (256 bytes), page-aligned, contiguous, indexed by tileId.
//   mode 2: 4 pages = TL, TR, BL, BR     (slot index = OffY*2 + OffX)
//   mode 3: 9 pages = row-major 3x3      (slot index = OffY*3 + OffX)
// MT_MetaPtrHi is the hi-byte of the first page; lo byte is always 0.
//
// Colour bank layout (MT_COLOR_MAP_PERCELL on modes 2/3): same scheme —
// parallel slot pages of 256 bytes each, page-aligned, indexed by tileId.
// MT_ColorSrcHi is the hi-byte of the first page; lo byte is ignored.
// Per cell colour = MT_ColorSrcHi'th page + slot, byte tileId.
//
// Optimizations vs the original reference:
//   * Map row base cached; no per-character Y*MapWidth multiply.
//   * Specialized renderer per tile mode; no per-char mode dispatch.
//   * Slot tables eliminate the per-char tileId*4 / *9 multiply.
//   * Slot base hi-byte patched into LDA abs,Y operand via SMC.
//   * Right-edge clip computed once per row; in-bounds run does no
//     per-char bounds check.
//
// Zero page used during MT_RenderWindow (transient, not preserved):
//   $02/$03  MT_ZP_MAP   (map row ptr for (zp),y reads)
//   $04/$05  MT_ZP_TGT   (screen target row ptr)
//   $06/$07  MT_ZP_CTGT  (colour target row ptr)
//   $08/$09  MT_ZP_CMAP  (colour-map row ptr, mode 1 + MT_COLOR_MAP only)

.const MT_ZP_MAP  = $02
.const MT_ZP_TGT  = $04
.const MT_ZP_CTGT = $06
.const MT_ZP_CMAP = $08

// Colour mode values for MT_ColorMode.
.const MT_COLOR_NONE         = 0 // skip colour RAM writes entirely
.const MT_COLOR_FILL         = 1 // every cell + fill tail gets MT_ColorFill
.const MT_COLOR_MAP          = 2 // mode 1: parallel colour map at MT_ColorSrcPtr
                                 // modes 2/3: 256-byte colour-per-tileId table
.const MT_COLOR_MAP_PERCELL  = 3 // mode 1: same as MAP (parallel per-cell map)
                                 // modes 2/3: parallel slot pages, 1 colour per
                                 //            child cell of each metatile id
                                 //            (MT_ColorSrcHi page-aligned; lo ignored)

// ------------------------------------------------------------
// Public config block (set by caller before MT_RenderWindow).
// ------------------------------------------------------------
MT_TileMode:      .byte 1
MT_MapPtrLo:      .byte 0
MT_MapPtrHi:      .byte 0
MT_MapWidth:      .byte 25
MT_MapHeight:     .byte 25
MT_MetaPtrHi:     .byte 0       // page-aligned slot pages base hi byte
MT_TargetPtrLo:   .byte <$0400
MT_TargetPtrHi:   .byte >$0400
MT_TargetStride:  .byte 40
MT_WindowWidth:   .byte 5
MT_WindowHeight:  .byte 5
MT_X:             .byte 0
MT_Y:             .byte 0
MT_OffX:          .byte 0
MT_OffY:          .byte 0
MT_FillChar:      .byte 32
// Colour config (added):
MT_ColorMode:     .byte 0       // 0=NONE, 1=FILL, 2=MAP
MT_ColorTgtLo:    .byte <$d800
MT_ColorTgtHi:    .byte >$d800
MT_ColorSrcLo:    .byte 0       // mode 1: per-cell colour map base
MT_ColorSrcHi:    .byte 0       // modes 2/3: per-tileId 256B table base
MT_ColorFill:     .byte 14      // FILL colour, also used for edge tail in MAP

// ------------------------------------------------------------
// Internal state.
// ------------------------------------------------------------
MT_RowBaseLo:     .byte 0
MT_RowBaseHi:     .byte 0
MT_TgtCurLo:      .byte 0
MT_TgtCurHi:      .byte 0
MT_CTgtCurLo:     .byte 0
MT_CTgtCurHi:     .byte 0
MT_CRowBaseLo:    .byte 0
MT_CRowBaseHi:    .byte 0
MT_RowMapY:       .byte 0
MT_RowOffY:       .byte 0
MT_RowIndex:      .byte 0
MT_ColIndex:      .byte 0
MT_WorkMapX:      .byte 0
MT_WorkOffX:      .byte 0
MT_InBoundsCols:  .byte 0       // # of columns this row that hit map cells
MT_FillTailCols:  .byte 0       // # of columns to fill after in-bounds run

// ------------------------------------------------------------
// MT_RenderWindow — public entry point.
// ------------------------------------------------------------
MT_RenderWindow:
  jsr mt_normalize
  lda MT_TargetPtrLo
  sta MT_TgtCurLo
  lda MT_TargetPtrHi
  sta MT_TgtCurHi
  lda MT_ColorTgtLo
  sta MT_CTgtCurLo
  lda MT_ColorTgtHi
  sta MT_CTgtCurHi
  jsr mt_color_setup
  lda MT_Y
  sta MT_RowMapY
  lda MT_OffY
  sta MT_RowOffY
  jsr mt_compute_row_base
  jsr mt_compute_color_row_base
  lda MT_TileMode
  cmp #2
  bne mt_not_mode2
  jmp mt_render_mode2
mt_not_mode2:
  cmp #3
  bne mt_render_mode1
  jmp mt_render_mode3
  // falls through to mode 1
mt_render_mode1:
  jmp mt_render_mode1_impl

// ------------------------------------------------------------
// mt_normalize — clamp mode and offsets to valid ranges.
// ------------------------------------------------------------
mt_normalize:
  lda MT_TileMode
  cmp #1
  beq mt_norm_mode_ok
  cmp #2
  beq mt_norm_mode_ok
  cmp #3
  beq mt_norm_mode_ok
  lda #1
  sta MT_TileMode
mt_norm_mode_ok:
  lda MT_OffX
  cmp MT_TileMode
  bcc mt_norm_offx_ok
  lda #0
  sta MT_OffX
mt_norm_offx_ok:
  lda MT_OffY
  cmp MT_TileMode
  bcc mt_norm_offy_ok
  lda #0
  sta MT_OffY
mt_norm_offy_ok:
  rts

// ------------------------------------------------------------
// mt_compute_row_base — RowBase = MapPtr + RowMapY * MapWidth.
// Repeated add; only called when RowMapY first set (start of render).
// ------------------------------------------------------------
mt_compute_row_base:
  lda MT_MapPtrLo
  sta MT_RowBaseLo
  lda MT_MapPtrHi
  sta MT_RowBaseHi
  ldx MT_RowMapY
  beq mt_row_base_done
mt_row_base_loop:
  clc
  lda MT_RowBaseLo
  adc MT_MapWidth
  sta MT_RowBaseLo
  lda MT_RowBaseHi
  adc #0
  sta MT_RowBaseHi
  dex
  bne mt_row_base_loop
mt_row_base_done:
  rts

// ------------------------------------------------------------
// mt_compute_color_row_base — CRowBase = ColorSrc + RowMapY*MapWidth.
// Used by mode 1 with MT_COLOR_MAP. Cheap to always call; result
// only consumed by SMC patched path that's NOPed out otherwise.
// ------------------------------------------------------------
mt_compute_color_row_base:
  lda MT_ColorSrcLo
  sta MT_CRowBaseLo
  lda MT_ColorSrcHi
  sta MT_CRowBaseHi
  ldx MT_RowMapY
  beq mt_crow_base_done
mt_crow_base_loop:
  clc
  lda MT_CRowBaseLo
  adc MT_MapWidth
  sta MT_CRowBaseLo
  lda MT_CRowBaseHi
  adc #0
  sta MT_CRowBaseHi
  dex
  bne mt_crow_base_loop
mt_crow_base_done:
  rts

// ------------------------------------------------------------
// mt_color_setup — patch all colour-block SMC sites based on
// MT_ColorMode. Called once per MT_RenderWindow.
//
//   NONE    : every colour block is `jmp end` (3 cycles overhead/cell).
//   FILL    : cload variants do `lda MT_ColorFill`; clookup blocks skip
//             (X preloaded with fill in each renderer's row setup).
//   MAP     : mode 1 cload = `lda (MT_ZP_CMAP),y`; modes 2/3 every
//             clookup slot executes `ldx MT_ColorSrc,y` (Y=tileId) -> X
//             (all slots share the same per-tileId table).
//   PERCELL : mode 1 same as MAP; modes 2/3 each clookup slot executes
//             `ldx <slot_page>,y` (Y=tileId) -> X. Slot page hi-bytes
//             are patched per-row by the renderer (mirrors char slots).
//
// Implementation: site addresses live in flat tables; mt_stamp_* loop
// helpers stamp jmp-skips or NOPs through ZP indirection.
// ------------------------------------------------------------

// Site index layout (low nibble = ordinal):
//  0: m1_cell      1: m1_fill
//  2: m2_clookup0  3: m2_clookup1
//  4: m2_cstore    5: m2_fill
//  6: m3_clookup
//  7: m3_cstore    8: m3_fill
.const MT_SITE_COUNT          = 9
.const MT_CLOOKUP_FIRST       = 2
.const MT_CLOOKUP_COUNT       = 3    // indices 2..4 in clookup-only tables
.const MT_PERCELL_COUNT       = 2    // mode 2 only (slot0, slot1)

mt_tbl_site_lo:
  .byte <mt_m1_cell_jmp,     <mt_m1_fill_jmp
  .byte <mt_m2_clookup0_jmp, <mt_m2_clookup1_jmp
  .byte <mt_m2_cstore_jmp,   <mt_m2_fill_jmp
  .byte <mt_m3_clookup_jmp
  .byte <mt_m3_cstore_jmp,   <mt_m3_fill_jmp
mt_tbl_site_hi:
  .byte >mt_m1_cell_jmp,     >mt_m1_fill_jmp
  .byte >mt_m2_clookup0_jmp, >mt_m2_clookup1_jmp
  .byte >mt_m2_cstore_jmp,   >mt_m2_fill_jmp
  .byte >mt_m3_clookup_jmp
  .byte >mt_m3_cstore_jmp,   >mt_m3_fill_jmp
mt_tbl_end_lo:
  .byte <mt_m1_cell_cend,    <mt_m1_fill_cend
  .byte <mt_m2_clookup0_end, <mt_m2_clookup1_end
  .byte <mt_m2_cstore_end,   <mt_m2_fill_cend
  .byte <mt_m3_clookup_end
  .byte <mt_m3_cstore_end,   <mt_m3_fill_cend
mt_tbl_end_hi:
  .byte >mt_m1_cell_cend,    >mt_m1_fill_cend
  .byte >mt_m2_clookup0_end, >mt_m2_clookup1_end
  .byte >mt_m2_cstore_end,   >mt_m2_fill_cend
  .byte >mt_m3_clookup_end
  .byte >mt_m3_cstore_end,   >mt_m3_fill_cend

// Operand-LO addresses for the 3 clookup `ldx abs,y` operands.
mt_tbl_op_lo_lo:
  .byte <(mt_m2_clookup0_op+1), <(mt_m2_clookup1_op+1)
  .byte <(mt_m3_clookup_op+1)
mt_tbl_op_lo_hi:
  .byte >(mt_m2_clookup0_op+1), >(mt_m2_clookup1_op+1)
  .byte >(mt_m3_clookup_op+1)

// mt_stamp_jmp / mt_stamp_nop3 use ZP $02/$03 (MT_ZP_MAP) as the site
// pointer. mt_color_setup runs before the renderer touches that ZP slot.
mt_stamp_jmp:
  ldy #0
  lda #$4c
  sta (MT_ZP_MAP),y
  iny
  lda mt_stamp_end_lo
  sta (MT_ZP_MAP),y
  iny
  lda mt_stamp_end_hi
  sta (MT_ZP_MAP),y
  rts
mt_stamp_end_lo: .byte 0
mt_stamp_end_hi: .byte 0

mt_stamp_nop3:
  lda #$ea
  ldy #0
  sta (MT_ZP_MAP),y
  iny
  sta (MT_ZP_MAP),y
  iny
  sta (MT_ZP_MAP),y
  rts

// Load mt_tbl_site/end[X] into ZP ptr + mt_stamp_end_*.
mt_load_site_x:
  lda mt_tbl_site_lo,x
  sta MT_ZP_MAP
  lda mt_tbl_site_hi,x
  sta MT_ZP_MAP+1
  lda mt_tbl_end_lo,x
  sta mt_stamp_end_lo
  lda mt_tbl_end_hi,x
  sta mt_stamp_end_hi
  rts

mt_color_setup:
  lda MT_ColorMode
  bne mt_csetup_active

  // -------- NONE: stamp jmp-skip across all 11 sites --------
  ldx #(MT_SITE_COUNT-1)
mt_csetup_none_loop:
  jsr mt_load_site_x
  jsr mt_stamp_jmp
  dex
  bpl mt_csetup_none_loop
  rts

mt_csetup_active:
  // -------- FILL/MAP/PERCELL: NOP every non-clookup site --------
  // sites 0,1 (m1 cell+fill), 4,5 (m2 cstore+fill), 7,8 (m3 cstore+fill)
  ldx #0
  jsr mt_csetup_nop_one
  ldx #1
  jsr mt_csetup_nop_one
  ldx #4
  jsr mt_csetup_nop_one
  ldx #5
  jsr mt_csetup_nop_one
  ldx #7
  jsr mt_csetup_nop_one
  ldx #8
  jsr mt_csetup_nop_one

  // dispatch on submode
  lda MT_ColorMode
  cmp #MT_COLOR_MAP
  beq mt_csetup_map
  cmp #MT_COLOR_MAP_PERCELL
  beq mt_csetup_percell

  // -------- FILL --------
  // clookup sites jmp-skip; mode 1 cload = lda MT_ColorFill
  ldx #(MT_CLOOKUP_FIRST + MT_CLOOKUP_COUNT - 1)
mt_csetup_fill_loop:
  jsr mt_load_site_x
  jsr mt_stamp_jmp
  dex
  cpx #(MT_CLOOKUP_FIRST-1)
  bne mt_csetup_fill_loop
  // mode 1 cload = `lda MT_ColorFill` (abs)
  lda #$ad
  sta mt_m1_cload
  lda #<MT_ColorFill
  sta mt_m1_cload+1
  lda #>MT_ColorFill
  sta mt_m1_cload+2
  rts

mt_csetup_map:
  // NOP all clookup leading jmps; patch every clookup operand to ColorSrc base
  jsr mt_csetup_nop_clookups
  ldx #(MT_CLOOKUP_COUNT-1)
mt_csetup_map_op_loop:
  // store ColorSrcLo at *(op_lo[x])
  lda mt_tbl_op_lo_lo,x
  sta MT_ZP_MAP
  lda mt_tbl_op_lo_hi,x
  sta MT_ZP_MAP+1
  ldy #0
  lda MT_ColorSrcLo
  sta (MT_ZP_MAP),y
  iny
  lda MT_ColorSrcHi
  sta (MT_ZP_MAP),y
  dex
  bpl mt_csetup_map_op_loop
  jmp mt_csetup_set_mode1_cmap

mt_csetup_percell:
  // -------- PERCELL (parallel slot pages, mode 2 only) --------
  // NOP every clookup leading jmp; clear mode-2 operand-LO bytes
  // (page-aligned, hi patched per-row by renderer). Mode 3 falls back to
  // MAP semantics (one colour per tile id).
  jsr mt_csetup_nop_clookups
  // mode 2 operands: zero lo
  lda #0
  sta mt_m2_clookup0_op+1
  sta mt_m2_clookup1_op+1
  // mode 3 operand: ColorSrc base (MAP semantics)
  lda MT_ColorSrcLo
  sta mt_m3_clookup_op+1
  lda MT_ColorSrcHi
  sta mt_m3_clookup_op+2
  jmp mt_csetup_set_mode1_cmap

mt_csetup_set_mode1_cmap:
  // mode 1 cload = `lda (MT_ZP_CMAP),y` + nop  ($B1 zp $EA)
  lda #$b1
  sta mt_m1_cload
  lda #MT_ZP_CMAP
  sta mt_m1_cload+1
  lda #$ea
  sta mt_m1_cload+2
  rts

// Helpers
mt_csetup_nop_one:
  jsr mt_load_site_x
  jmp mt_stamp_nop3

mt_csetup_nop_clookups:
  ldx #(MT_CLOOKUP_FIRST + MT_CLOOKUP_COUNT - 1)
mt_csetup_nop_cl_loop:
  jsr mt_load_site_x
  jsr mt_stamp_nop3
  dex
  cpx #(MT_CLOOKUP_FIRST-1)
  bne mt_csetup_nop_cl_loop
  rts

// ------------------------------------------------------------
// mt_advance_row — at end of each output row:
//   * step screen + colour target ptrs down by stride
//   * tick OffY; if it wraps, bump RowMapY and add MapWidth
//     to both RowBase and CRowBase
// ------------------------------------------------------------
mt_advance_row:
  clc
  lda MT_TgtCurLo
  adc MT_TargetStride
  sta MT_TgtCurLo
  lda MT_TgtCurHi
  adc #0
  sta MT_TgtCurHi
  clc
  lda MT_CTgtCurLo
  adc MT_TargetStride
  sta MT_CTgtCurLo
  lda MT_CTgtCurHi
  adc #0
  sta MT_CTgtCurHi
  inc MT_RowOffY
  lda MT_RowOffY
  cmp MT_TileMode
  bcc mt_adv_done
  lda #0
  sta MT_RowOffY
  inc MT_RowMapY
  clc
  lda MT_RowBaseLo
  adc MT_MapWidth
  sta MT_RowBaseLo
  lda MT_RowBaseHi
  adc #0
  sta MT_RowBaseHi
  clc
  lda MT_CRowBaseLo
  adc MT_MapWidth
  sta MT_CRowBaseLo
  lda MT_CRowBaseHi
  adc #0
  sta MT_CRowBaseHi
mt_adv_done:
  rts

// ------------------------------------------------------------
// mt_compute_clip — figure out the in-bounds column run and fill tail
// for the current row. Returns:
//   MT_InBoundsCols  = # cols starting at left edge that read real map
//   MT_FillTailCols  = # cols after that to fill with MT_FillChar
// Inputs: MT_RowMapY, MT_X, MT_OffX, MT_MapWidth, MT_MapHeight,
//         MT_WindowWidth, MT_TileMode.
// ------------------------------------------------------------
mt_compute_clip:
  // If row is past map height -> entire row is fill.
  lda MT_RowMapY
  cmp MT_MapHeight
  bcc mt_clip_row_ok
  lda #0
  sta MT_InBoundsCols
  lda MT_WindowWidth
  sta MT_FillTailCols
  rts
mt_clip_row_ok:
  // remaining map cells to right of (X,OffX) starting cell
  // = MapWidth - X (in map cells)
  // expanded character count = (MapWidth - X) * TileMode - OffX
  sec
  lda MT_MapWidth
  sbc MT_X
  bcs mt_clip_have_cells
  // X >= MapWidth: entire row is fill
  lda #0
  sta MT_InBoundsCols
  lda MT_WindowWidth
  sta MT_FillTailCols
  rts
mt_clip_have_cells:
  // A = MapWidth - X (>= 1 here). Multiply by TileMode.
  ldx MT_TileMode
  cpx #1
  beq mt_clip_chars_done
  // multiply by 2 or 3 via shift/add
  cpx #2
  bne mt_clip_mul3
  asl       // *2
  jmp mt_clip_chars_done
mt_clip_mul3:
  sta mt_clip_tmp
  asl
  clc
  adc mt_clip_tmp   // *3
mt_clip_chars_done:
  // Subtract OffX. A might be small enough to underflow into 0; clamp.
  sec
  sbc MT_OffX
  bcs mt_clip_no_under
  lda #0
mt_clip_no_under:
  // A = available chars to right of start (incl current). Clip to WindowWidth.
  cmp MT_WindowWidth
  bcc mt_clip_use_a
  lda MT_WindowWidth
mt_clip_use_a:
  sta MT_InBoundsCols
  sec
  lda MT_WindowWidth
  sbc MT_InBoundsCols
  sta MT_FillTailCols
  rts
mt_clip_tmp: .byte 0

// ------------------------------------------------------------
// Mode 1: raw. Map byte is the screen char.
// ------------------------------------------------------------
mt_render_mode1_impl:
  lda #0
  sta MT_RowIndex
mt_m1_row_loop:
  lda MT_RowIndex
  cmp MT_WindowHeight
  bne mt_m1_row_continue
  rts
mt_m1_row_continue:
  jsr mt_compute_clip
  // setup screen target ZP
  lda MT_TgtCurLo
  sta MT_ZP_TGT
  lda MT_TgtCurHi
  sta MT_ZP_TGT+1
  // setup colour target ZP
  lda MT_CTgtCurLo
  sta MT_ZP_CTGT
  lda MT_CTgtCurHi
  sta MT_ZP_CTGT+1
  // setup map ZP = RowBase + X
  clc
  lda MT_RowBaseLo
  adc MT_X
  sta MT_ZP_MAP
  lda MT_RowBaseHi
  adc #0
  sta MT_ZP_MAP+1
  // setup colour-map ZP = CRowBase + X (only consumed by MAP mode SMC)
  clc
  lda MT_CRowBaseLo
  adc MT_X
  sta MT_ZP_CMAP
  lda MT_CRowBaseHi
  adc #0
  sta MT_ZP_CMAP+1
  ldy #0
mt_m1_in_loop:
  cpy MT_InBoundsCols
  beq mt_m1_in_done
  lda (MT_ZP_MAP),y
  sta (MT_ZP_TGT),y
  // ---- cell colour block (9B: jmp + cload + cstore) ----
mt_m1_cell_jmp:
  jmp mt_m1_cell_cend     // SMC: NONE keeps jmp; FILL/MAP -> 3 NOPs
mt_m1_cload:
  lda MT_ColorFill        // SMC: FILL = lda abs; MAP = lda (MT_ZP_CMAP),y + nop
  sta (MT_ZP_CTGT),y      // 2B
  nop                     // pad to 3B (label mt_m1_cstore is at the sta)
mt_m1_cell_cend:
  iny
  jmp mt_m1_in_loop
mt_m1_in_done:
  // fill tail
  lda MT_FillTailCols
  beq mt_m1_row_end
mt_m1_fill_loop:
  cpy MT_WindowWidth
  beq mt_m1_row_end
  lda MT_FillChar
  sta (MT_ZP_TGT),y
  // ---- fill-tail colour block (9B) ----
mt_m1_fill_jmp:
  jmp mt_m1_fill_cend     // SMC: NONE keeps jmp; FILL/MAP -> 3 NOPs
  lda MT_ColorFill
  sta (MT_ZP_CTGT),y
  nop
mt_m1_fill_cend:
  iny
  jmp mt_m1_fill_loop
mt_m1_row_end:
  jsr mt_advance_row
  inc MT_RowIndex
  jmp mt_m1_row_loop

// ------------------------------------------------------------
// Mode 2: 2x2 metatiles via parallel slot pages.
// Per row, two slot pages are in play: OffY*2 (OffX=0) and OffY*2+1
// (OffX=1). We patch the LDA abs,Y operands' hi bytes at row start.
// ------------------------------------------------------------
mt_render_mode2:
  lda #0
  sta MT_RowIndex
mt_m2_row_loop:
  lda MT_RowIndex
  cmp MT_WindowHeight
  bne mt_m2_row_continue
  rts
mt_m2_row_continue:
  jsr mt_compute_clip
  // patch slot base hi bytes: slot0 hi = MetaPtrHi + OffY*2, slot1 hi = +1
  lda MT_RowOffY
  asl
  clc
  adc MT_MetaPtrHi
  sta mt_m2_slot0_load+2
  clc
  adc #1
  sta mt_m2_slot1_load+2
  // PERCELL: also patch colour-slot page hi bytes the same way
  lda MT_ColorMode
  cmp #MT_COLOR_MAP_PERCELL
  bne mt_m2_no_color_slot_patch
  lda MT_RowOffY
  asl
  clc
  adc MT_ColorSrcHi
  sta mt_m2_clookup0_op+2
  clc
  adc #1
  sta mt_m2_clookup1_op+2
mt_m2_no_color_slot_patch:
  // target ZP
  lda MT_TgtCurLo
  sta MT_ZP_TGT
  lda MT_TgtCurHi
  sta MT_ZP_TGT+1
  // colour target ZP
  lda MT_CTgtCurLo
  sta MT_ZP_CTGT
  lda MT_CTgtCurHi
  sta MT_ZP_CTGT+1
  // map ZP = RowBase (we'll index by WorkMapX via Y)
  lda MT_RowBaseLo
  sta MT_ZP_MAP
  lda MT_RowBaseHi
  sta MT_ZP_MAP+1
  // X preload for FILL colour mode (harmless waste for NONE/MAP)
  ldx MT_ColorFill
  // init working state
  lda MT_X
  sta MT_WorkMapX
  lda MT_OffX
  sta MT_WorkOffX
  lda #0
  sta MT_ColIndex
mt_m2_in_loop:
  lda MT_ColIndex
  cmp MT_InBoundsCols
  beq mt_m2_in_done
  // load tileId from map row at WorkMapX
  ldy MT_WorkMapX
  lda (MT_ZP_MAP),y
  tay                       // Y = tileId
  // dispatch on WorkOffX
  lda MT_WorkOffX
  bne mt_m2_use_slot1
  // ---- slot 0: clookup + char load (Y = tileId throughout) ----
  // clookup block (6B): NONE/FILL keep jmp; MAP/PERCELL -> 3 NOPs
mt_m2_clookup0_jmp:
  jmp mt_m2_clookup0_end
mt_m2_clookup0_op:
  ldx $ff00,y               // SMC operand: MAP=ColorSrc base; PERCELL=slot0 page
mt_m2_clookup0_end:
mt_m2_slot0_load:
  lda $ff00,y               // SMC: char slot 0 page (hi byte patched per row)
  jmp mt_m2_after_slots
mt_m2_use_slot1:
  // ---- slot 1: clookup + char load ----
mt_m2_clookup1_jmp:
  jmp mt_m2_clookup1_end
mt_m2_clookup1_op:
  ldx $ff00,y               // SMC operand: MAP=ColorSrc base; PERCELL=slot1 page
mt_m2_clookup1_end:
mt_m2_slot1_load:
  lda $ff00,y               // SMC: char slot 1 page (hi byte patched per row)
mt_m2_after_slots:
  ldy MT_ColIndex
  sta (MT_ZP_TGT),y
  // ---- cstore block (6B: jmp + txa + sta (zp),y) ----
mt_m2_cstore_jmp:
  jmp mt_m2_cstore_end      // SMC: NONE keeps jmp; FILL/MAP -> 3 NOPs
  txa
  sta (MT_ZP_CTGT),y
mt_m2_cstore_end:
  inc MT_ColIndex
  // advance OffX/MapX
  lda MT_WorkOffX
  eor #1
  sta MT_WorkOffX
  bne mt_m2_in_loop         // toggled 0->1: stay on same map cell
  inc MT_WorkMapX
  jmp mt_m2_in_loop
mt_m2_in_done:
  // fill tail
  ldy MT_ColIndex
mt_m2_fill_loop:
  cpy MT_WindowWidth
  beq mt_m2_row_end
  lda MT_FillChar
  sta (MT_ZP_TGT),y
  // ---- fill-tail colour block (9B) ----
mt_m2_fill_jmp:
  jmp mt_m2_fill_cend       // SMC: NONE keeps jmp; FILL/MAP -> 3 NOPs
  lda MT_ColorFill
  sta (MT_ZP_CTGT),y
  nop
mt_m2_fill_cend:
  iny
  jmp mt_m2_fill_loop
mt_m2_row_end:
  jsr mt_advance_row
  inc MT_RowIndex
  jmp mt_m2_row_loop

// ------------------------------------------------------------
// Mode 3: 3x3 metatiles. Three slot pages active per row.
// ------------------------------------------------------------
mt_render_mode3:
  lda #0
  sta MT_RowIndex
mt_m3_row_loop:
  lda MT_RowIndex
  cmp MT_WindowHeight
  bne mt_m3_row_continue
  rts
mt_m3_row_continue:
  jsr mt_compute_clip
  // slot base hi bytes: MetaPtrHi + OffY*3 + {0,1,2}
  lda MT_RowOffY
  asl                       // *2
  clc
  adc MT_RowOffY            // *3
  clc
  adc MT_MetaPtrHi
  sta mt_m3_slot0_load+2
  clc
  adc #1
  sta mt_m3_slot1_load+2
  clc
  adc #1
  sta mt_m3_slot2_load+2
  lda MT_TgtCurLo
  sta MT_ZP_TGT
  lda MT_TgtCurHi
  sta MT_ZP_TGT+1
  lda MT_CTgtCurLo
  sta MT_ZP_CTGT
  lda MT_CTgtCurHi
  sta MT_ZP_CTGT+1
  lda MT_RowBaseLo
  sta MT_ZP_MAP
  lda MT_RowBaseHi
  sta MT_ZP_MAP+1
  ldx MT_ColorFill          // X preload for FILL mode
  lda MT_X
  sta MT_WorkMapX
  lda MT_OffX
  sta MT_WorkOffX
  lda #0
  sta MT_ColIndex
mt_m3_in_loop:
  lda MT_ColIndex
  cmp MT_InBoundsCols
  beq mt_m3_in_done
  ldy MT_WorkMapX
  lda (MT_ZP_MAP),y
  tay                       // Y = tileId
  lda MT_WorkOffX
  bne mt_m3_try_slot1
mt_m3_slot0_load:
  lda $ff00,y
  jmp mt_m3_after_slots
mt_m3_try_slot1:
  cmp #1
  bne mt_m3_use_slot2
mt_m3_slot1_load:
  lda $ff00,y
  jmp mt_m3_after_slots
mt_m3_use_slot2:
mt_m3_slot2_load:
  lda $ff00,y
mt_m3_after_slots:
  // ---- clookup block (6B), Y still = tileId ----
mt_m3_clookup_jmp:
  jmp mt_m3_clookup_end     // SMC: NONE/FILL keep jmp; MAP -> 3 NOPs
mt_m3_clookup_op:
  ldx $ff00,y               // SMC operand = MT_ColorSrc base
mt_m3_clookup_end:
  ldy MT_ColIndex
  sta (MT_ZP_TGT),y
  // ---- cstore block (6B) ----
mt_m3_cstore_jmp:
  jmp mt_m3_cstore_end      // SMC: NONE keeps jmp; FILL/MAP -> 3 NOPs
  txa
  sta (MT_ZP_CTGT),y
mt_m3_cstore_end:
  inc MT_ColIndex
  // advance OffX (0->1->2->0, with map advance on the wrap)
  inc MT_WorkOffX
  lda MT_WorkOffX
  cmp #3
  bne mt_m3_in_loop
  lda #0
  sta MT_WorkOffX
  inc MT_WorkMapX
  jmp mt_m3_in_loop
mt_m3_in_done:
  ldy MT_ColIndex
mt_m3_fill_loop:
  cpy MT_WindowWidth
  beq mt_m3_row_end
  lda MT_FillChar
  sta (MT_ZP_TGT),y
  // ---- fill-tail colour block (9B) ----
mt_m3_fill_jmp:
  jmp mt_m3_fill_cend       // SMC: NONE keeps jmp; FILL/MAP -> 3 NOPs
  lda MT_ColorFill
  sta (MT_ZP_CTGT),y
  nop
mt_m3_fill_cend:
  iny
  jmp mt_m3_fill_loop
mt_m3_row_end:
  jsr mt_advance_row
  inc MT_RowIndex
  jmp mt_m3_row_loop
