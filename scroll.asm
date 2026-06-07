// Scroll region handler (Tier-1 optimised).
//
// Same protocol as before:  G x y w h dir
//   x      hex byte, clamped to 0..39
//   y      hex byte, clamped to 0..24
//   w      hex byte, 1..40-x   (0 -> 1)
//   h      hex byte, 1..25-y   (0 -> 1)
//   dir    hex nibble, low 2 bits: 0=up, 1=down, 2=left, 3=right
//
// Performance notes:
//   * Each direction routine hoists screen/colour-RAM pointer setup
//     OUT of the per-cell inner loop. Address-table lookups happen
//     ~21 times per call instead of ~840 times.
//   * Inner loops fold screen and colour stores into a single pass
//     using one Y register (lda src,y / sta dst,y for chars, then
//     for colour, one iter).
//   * Edge clears are inlined two-pass loops (chars then colours)
//     so each pass has a single hot lda/sta -- no helper calls.

protocol_scroll_region:
  jsr protocol_read_hex_byte
  cmp #40
  bcc scroll_x_ok
  lda #39
scroll_x_ok:
  sta scroll_x

  jsr protocol_read_hex_byte
  cmp #25
  bcc scroll_y_ok
  lda #24
scroll_y_ok:
  sta scroll_y

  jsr protocol_read_hex_byte
  beq scroll_width_zero
  jmp scroll_width_have
scroll_width_zero:
  lda #1
scroll_width_have:
  sta scroll_width
  lda scroll_x
  clc
  adc scroll_width
  cmp #41
  bcc scroll_width_ok
  lda #40
  sec
  sbc scroll_x
  sta scroll_width
scroll_width_ok:

  jsr protocol_read_hex_byte
  beq scroll_height_zero
  jmp scroll_height_have
scroll_height_zero:
  lda #1
scroll_height_have:
  sta scroll_height
  lda scroll_y
  clc
  adc scroll_height
  cmp #26
  bcc scroll_height_ok
  lda #25
  sec
  sbc scroll_y
  sta scroll_height
scroll_height_ok:

  // Pre-compute scroll_x_end = scroll_x + scroll_width into scroll_col,
  // used as the inner-loop terminator for forward copies/clears.
  lda scroll_x
  clc
  adc scroll_width
  sta scroll_col

  jsr protocol_read_hex_nibble
  and #$03
  sta scroll_dir
  beq scroll_up
  cmp #1
  beq scroll_down_jump
  cmp #2
  beq scroll_left_jump
  jmp scroll_right
scroll_down_jump:
  jmp scroll_down
scroll_left_jump:
  jmp scroll_left

// =====================================================================
//   scroll_up : content moves up one row.
//   For r = 0 .. height-2 :  copy row (scroll_y+r+1) -> row (scroll_y+r).
//   Then clear row (scroll_y+height-1).
// =====================================================================
scroll_up:
  lda scroll_col
  sta copy_row_term+1
  lda scroll_height
  cmp #2
  bcc scroll_up_clear_only
  lda #0
  sta scroll_row
scroll_up_loop:
  lda scroll_row
  clc
  adc #1
  cmp scroll_height
  beq scroll_up_clear_only
  // src row = scroll_y + scroll_row + 1
  lda scroll_y
  clc
  adc scroll_row
  clc
  adc #1
  tax
  jsr patch_row_src
  // dst row = scroll_y + scroll_row
  lda scroll_y
  clc
  adc scroll_row
  tax
  jsr patch_row_dst
  jsr copy_row
  inc scroll_row
  jmp scroll_up_loop
scroll_up_clear_only:
  // Clear bottom row.
  lda scroll_y
  clc
  adc scroll_height
  sec
  sbc #1
  tax
  jsr patch_row_dst
  jsr clear_dst_row
  rts

// =====================================================================
//   scroll_down : content moves down one row.
//   For r = height-1 .. 1 :  copy row (scroll_y+r-1) -> row (scroll_y+r).
//   Then clear row scroll_y.
// =====================================================================
scroll_down:
  lda scroll_col
  sta copy_row_term+1
  lda scroll_height
  cmp #2
  bcc scroll_down_clear_only
  lda scroll_height
  sta scroll_row
scroll_down_loop:
  dec scroll_row
  lda scroll_row
  beq scroll_down_clear_only
  // src row = scroll_y + scroll_row - 1
  lda scroll_y
  clc
  adc scroll_row
  sec
  sbc #1
  tax
  jsr patch_row_src
  // dst row = scroll_y + scroll_row
  lda scroll_y
  clc
  adc scroll_row
  tax
  jsr patch_row_dst
  jsr copy_row
  jmp scroll_down_loop
scroll_down_clear_only:
  ldx scroll_y
  jsr patch_row_dst
  jsr clear_dst_row
  rts

// =====================================================================
//   scroll_left : content moves left one column.
//   Per row : copy cells [scroll_x+1 .. scroll_x+w-1] left by 1, then
//             clear cell at column (scroll_x + w - 1).
//   We reuse copy_row with terminator = scroll_col-1, so it iterates
//   Y = scroll_x..scroll_x+w-2 (w-1 cells). No off-region access.
//     dst patched to row_base   -> addr = base + Y          (col Y)
//     src patched to row_base+1 -> addr = base + 1 + Y      (col Y+1)
// =====================================================================
scroll_left:
  lda scroll_height
  beq scroll_left_done
  lda scroll_width
  cmp #2
  bcs scroll_left_normal
  // width < 2 -> nothing to slide; just clear the single column.
  jmp scroll_left_clear_only
scroll_left_normal:
  // copy_row terminator = scroll_col - 1 (last cell handled by edge clear)
  lda scroll_col
  sec
  sbc #1
  sta copy_row_term+1
  lda #0
  sta scroll_row
scroll_left_loop:
  lda scroll_row
  cmp scroll_height
  beq scroll_left_done
  lda scroll_y
  clc
  adc scroll_row
  tax
  jsr patch_row_dst
  jsr patch_src_from_dst_plus1
  jsr copy_row
  jsr clear_dst_last_cell
  inc scroll_row
  jmp scroll_left_loop
scroll_left_clear_only:
  // For w<2 we still need to clear the (single) target column on each row.
  lda #0
  sta scroll_row
scroll_left_clr_loop:
  lda scroll_row
  cmp scroll_height
  beq scroll_left_done
  lda scroll_y
  clc
  adc scroll_row
  tax
  jsr patch_row_dst
  jsr clear_dst_last_cell
  inc scroll_row
  jmp scroll_left_clr_loop
scroll_left_done:
  rts

// =====================================================================
//   scroll_right : content moves right one column.
//   Per row : copy cells [scroll_x .. scroll_x+w-2] right by 1 (REVERSE
//             order to avoid clobbering source), then clear cell at
//             column scroll_x.
//   Reverse loop runs Y = scroll_col-2 down to scroll_x:
//     src patched to row_base   -> addr = base + Y          (col Y)
//     dst patched to row_base+1 -> addr = base + 1 + Y      (col Y+1)
// =====================================================================
scroll_right:
  lda scroll_height
  beq scroll_right_done
  lda scroll_width
  cmp #2
  bcs scroll_right_normal
  jmp scroll_right_clear_only
scroll_right_normal:
  lda #0
  sta scroll_row
scroll_right_loop:
  lda scroll_row
  cmp scroll_height
  beq scroll_right_done
  lda scroll_y
  clc
  adc scroll_row
  tax
  jsr patch_row_src
  jsr patch_dst_from_src_plus1
  jsr copy_row_right
  jsr clear_src_first_cell
  inc scroll_row
  jmp scroll_right_loop
scroll_right_clear_only:
  lda #0
  sta scroll_row
scroll_right_clr_loop:
  lda scroll_row
  cmp scroll_height
  beq scroll_right_done
  lda scroll_y
  clc
  adc scroll_row
  tax
  jsr patch_row_src
  jsr clear_src_first_cell
  inc scroll_row
  jmp scroll_right_clr_loop
scroll_right_done:
  rts

// =====================================================================
//   Per-row pointer patchers.  X = row index (0..24).
// =====================================================================

patch_row_src:
  lda screen_lo,x
  sta scroll_src_screen+1
  sta scroll_src_color+1
  sta scroll_src_screen_r+1
  sta scroll_src_color_r+1
  sta scroll_src_first_clr+1
  sta scroll_src_first_clr_color+1
  lda screen_hi,x
  sta scroll_src_screen+2
  sta scroll_src_screen_r+2
  sta scroll_src_first_clr+2
  lda color_hi,x
  sta scroll_src_color+2
  sta scroll_src_color_r+2
  sta scroll_src_first_clr_color+2
  rts

patch_row_dst:
  lda screen_lo,x
  sta scroll_dst_screen+1
  sta scroll_dst_color+1
  sta scroll_dst_screen_r+1
  sta scroll_dst_color_r+1
  sta scroll_dst_chr_clr+1
  sta scroll_dst_col_clr+1
  sta scroll_dst_last_clr+1
  sta scroll_dst_last_clr_color+1
  lda screen_hi,x
  sta scroll_dst_screen+2
  sta scroll_dst_screen_r+2
  sta scroll_dst_chr_clr+2
  sta scroll_dst_last_clr+2
  lda color_hi,x
  sta scroll_dst_color+2
  sta scroll_dst_color_r+2
  sta scroll_dst_col_clr+2
  sta scroll_dst_last_clr_color+2
  rts

// src_low = dst_low + 1 (high byte unchanged: screen_lo never reaches $ff).
patch_src_from_dst_plus1:
  lda scroll_dst_screen+1
  clc
  adc #1
  sta scroll_src_screen+1
  sta scroll_src_color+1
  lda scroll_dst_screen+2
  sta scroll_src_screen+2
  lda scroll_dst_color+2
  sta scroll_src_color+2
  rts

// dst_low (reverse-copy site) = src_low + 1.
patch_dst_from_src_plus1:
  lda scroll_src_screen+1
  clc
  adc #1
  sta scroll_dst_screen_r+1
  sta scroll_dst_color_r+1
  lda scroll_src_screen+2
  sta scroll_dst_screen_r+2
  lda scroll_src_color+2
  sta scroll_dst_color_r+2
  rts

// =====================================================================
//   Inner loops.
// =====================================================================

// Forward copy: dst[Y] = src[Y]  for Y in scroll_x..(terminator-1).
// The terminator is a self-modified immediate at copy_row_term+1, set
// by each direction routine before entry:
//   scroll_up / scroll_down  -> scroll_col      (full row, w iters)
//   scroll_left              -> scroll_col - 1  (skip last cell, w-1 iters,
//                                                avoids reading past region)
copy_row:
  ldy scroll_x
copy_row_loop:
scroll_src_screen:
  lda $0400,y
scroll_dst_screen:
  sta $0400,y
scroll_src_color:
  lda $d800,y
scroll_dst_color:
  sta $d800,y
  iny
copy_row_term:
  cpy #$28
  bne copy_row_loop
  rts

// Reverse copy: Y from scroll_col-2 down to scroll_x.
// src patched to row_base, dst patched to row_base+1.
copy_row_right:
  ldy scroll_col
  dey
  dey                          // Y = scroll_col - 2
  cpy scroll_x                 // signed/unsigned: bcc if Y < scroll_x
  bcc copy_row_right_done      // (only when width < 2 -> guarded earlier)
copy_row_right_loop:
scroll_src_screen_r:
  lda $0400,y
scroll_dst_screen_r:
  sta $0400,y
scroll_src_color_r:
  lda $d800,y
scroll_dst_color_r:
  sta $d800,y
  cpy scroll_x
  beq copy_row_right_done
  dey
  jmp copy_row_right_loop
copy_row_right_done:
  rts

// =====================================================================
//   Clears (use already-patched dst row pointers).
// =====================================================================

// Clear the entire row.  Two passes (chars then colours).
clear_dst_row:
  ldy scroll_x
  lda #32
clear_dst_row_chars:
scroll_dst_chr_clr:
  sta $0400,y
  iny
  cpy scroll_col
  bne clear_dst_row_chars
  ldy scroll_x
  lda text_color
clear_dst_row_colors:
scroll_dst_col_clr:
  sta $d800,y
  iny
  cpy scroll_col
  bne clear_dst_row_colors
  rts

// Clear ONLY the last cell of the dst row (column scroll_col-1).
clear_dst_last_cell:
  ldy scroll_col
  dey
  lda #32
scroll_dst_last_clr:
  sta $0400,y
  lda text_color
scroll_dst_last_clr_color:
  sta $d800,y
  rts

// Clear ONLY the first cell of the src row (column scroll_x).
clear_src_first_cell:
  ldy scroll_x
  lda #32
scroll_src_first_clr:
  sta $0400,y
  lda text_color
scroll_src_first_clr_color:
  sta $d800,y
  rts
