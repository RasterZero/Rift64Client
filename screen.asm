// Screen display routines.
//
// Character output, cursor management, screen clearing, and the
// screen/color RAM lookup tables used by all display operations.

print_string:
  stx ptr
  sty ptr+1
  ldy #0
print_loop:
  lda (ptr),y
  beq print_done
  sty string_index
  jsr print_char
  ldy string_index
  iny
  bne print_loop
print_done:
  rts

clear_screen:
  // Preserve current background and border colors to avoid visible flashing
  // when the host clears and then immediately applies a new palette.
  lda #1
  sta text_color
  lda #0
  sta cursor_x
  sta cursor_y
  sta cursor_visible
  // Point the four screen-page stores at the active screen base. Colour RAM
  // is fixed at $D800 by hardware, so the colour stores are never rebased.
  lda screen_base_hi
  sta clear_scr_p0+2
  clc
  adc #1
  sta clear_scr_p1+2
  clc
  adc #1
  sta clear_scr_p2+2
  clc
  adc #1
  sta clear_scr_p3+2
  ldx #0
clear_page:
  lda #32
clear_scr_p0:
  sta $0400,x
clear_scr_p1:
  sta $0500,x
clear_scr_p2:
  sta $0600,x
  lda #1
  sta $d800,x
  sta $d900,x
  sta $da00,x
  inx
  bne clear_page
  ldx #0
clear_last:
  lda #32
clear_scr_p3:
  sta $0700,x
  lda #1
  sta $db00,x
  inx
  cpx #232
  bne clear_last
  rts

print_char:
  cmp #$0a
  beq print_newline
  cmp #$0d
  beq print_newline
  cmp #$20
  bcc print_dot
  cmp #$7f
  bcs print_dot
  jsr ascii_to_screen_code
  pha
  ldx cursor_y
  lda screen_lo,x
  sta screen_store+1
  lda screen_hi,x
  sta screen_store+2
  lda color_lo,x
  sta color_store+1
  lda color_hi,x
  sta color_store+2
  ldy cursor_x
  pla
screen_store:
  sta $0400,y
  lda text_color
color_store:
  sta $d800,y
  inc cursor_x
  lda cursor_x
  cmp #40
  bcc print_done_char
print_newline:
  lda #0
  sta cursor_x
  inc cursor_y
  lda cursor_y
  cmp #25
  bcc print_done_char
  lda #24
  sta cursor_y
print_done_char:
  rts

print_dot:
  lda #46
  jmp print_char

show_cursor:
  lda cursor_enabled
  beq show_cursor_done
  lda cursor_visible
  bne show_cursor_done
  ldx cursor_x
  cpx #40
  bcs show_cursor_done
  ldx cursor_y
  cpx #25
  bcs show_cursor_done
  lda screen_lo,x
  sta cursor_screen_load+1
  sta cursor_screen_store+1
  lda screen_hi,x
  sta cursor_screen_load+2
  sta cursor_screen_store+2
  lda color_lo,x
  sta cursor_color_load+1
  sta cursor_color_store+1
  lda color_hi,x
  sta cursor_color_load+2
  sta cursor_color_store+2
  ldy cursor_x
cursor_screen_load:
  lda $0400,y
  sta cursor_saved_char
cursor_color_load:
  lda $d800,y
  sta cursor_saved_color
  lda #160
cursor_screen_store:
  sta $0400,y
  lda text_color
cursor_color_store:
  sta $d800,y
  lda #1
  sta cursor_visible
show_cursor_done:
  rts

hide_cursor:
  lda cursor_visible
  beq hide_cursor_done
  ldx cursor_y
  cpx #25
  bcs hide_cursor_off
  lda screen_lo,x
  sta hide_cursor_screen_store+1
  lda screen_hi,x
  sta hide_cursor_screen_store+2
  lda color_lo,x
  sta hide_cursor_color_store+1
  lda color_hi,x
  sta hide_cursor_color_store+2
  ldy cursor_x
  lda cursor_saved_char
hide_cursor_screen_store:
  sta $0400,y
  lda cursor_saved_color
hide_cursor_color_store:
  sta $d800,y
hide_cursor_off:
  lda #0
  sta cursor_visible
hide_cursor_done:
  rts

ascii_to_screen_code:
  cmp #$41
  bcc ascii_code_done
  cmp #$5b
  bcs ascii_code_done
  sec
  sbc #64
ascii_code_done:
  rts

screen_to_ascii:
  cmp #$0d
  beq screen_done
  cmp #$41
  bcc screen_done
  cmp #$5b
  bcs screen_done
  clc
  adc #$20
screen_done:
  rts

put_window_char:
  ldx cursor_x
  cpx #40
  bcs put_window_done
  ldx cursor_y
  cpx #25
  bcs put_window_done
  pha
  ldx cursor_y
  lda screen_lo,x
  sta put_window_screen_store+1
  lda screen_hi,x
  sta put_window_screen_store+2
  lda color_lo,x
  sta put_window_color_store+1
  lda color_hi,x
  sta put_window_color_store+2
  ldy cursor_x
  pla
put_window_screen_store:
  sta $0400,y
  lda text_color
put_window_color_store:
  sta $d800,y
put_window_done:
  rts

// Screen and color RAM row address lookup tables.
screen_lo:
  .byte $00,$28,$50,$78,$a0,$c8,$f0,$18
  .byte $40,$68,$90,$b8,$e0,$08,$30,$58
  .byte $80,$a8,$d0,$f8,$20,$48,$70,$98,$c0
screen_hi:
  .byte $04,$04,$04,$04,$04,$04,$04,$05
  .byte $05,$05,$05,$05,$05,$06,$06,$06
  .byte $06,$06,$06,$06,$07,$07,$07,$07,$07
// color_lo values are identical to screen_lo — reuse the same table.
.label color_lo = screen_lo
color_hi:
  .byte $d8,$d8,$d8,$d8,$d8,$d8,$d8,$d9
  .byte $d9,$d9,$d9,$d9,$d9,$da,$da,$da
  .byte $da,$da,$da,$da,$db,$db,$db,$db,$db

// apply_screen_base — derive the screen-matrix base from the active VIC bank
// (video_bank_bits) and screen slot ($D018 high nibble in video_d018_value),
// store it in screen_base_hi, and rebuild the screen_hi row table. Called by the
// 'F'/'I' command handlers after they program $DD00/$D018, so the CPU draw base
// always tracks the VIC's view. Colour RAM is fixed at $D800 and is not rebased.
//
//   screen_base_hi = (~video_bank_bits & 3) * $40   (VIC bank base, hi byte)
//                  + ((video_d018_value >> 4) & $0F) * $04   (screen slot pages)
apply_screen_base:
  lda video_d018_value
  lsr
  lsr
  lsr
  lsr                          // A = screen slot 0..15
  asl
  asl                          // * 4 pages per 1KB slot
  sta screen_base_hi           // hold slot contribution
  lda video_bank_bits
  eor #$ff
  and #$03                     // VIC bank index 0..3
  tax
  lda screen_bank_base_hi,x
  clc
  adc screen_base_hi
  sta screen_base_hi
  // Rebuild screen_hi[i] = screen_base_hi + screen_page_delta[i].
  ldx #24
apply_screen_base_loop:
  lda screen_page_delta,x
  clc
  adc screen_base_hi
  sta screen_hi,x
  dex
  bpl apply_screen_base_loop
  rts

// VIC bank base hi byte indexed by bank number (0=$0000..3=$C000).
screen_bank_base_hi:
  .byte $00,$40,$80,$c0
// Per-row page offset of the screen base ($00/$01/$02/$03), one per text row.
screen_page_delta:
  .byte $00,$00,$00,$00,$00,$00,$00,$01
  .byte $01,$01,$01,$01,$01,$02,$02,$02
  .byte $02,$02,$02,$02,$03,$03,$03,$03,$03
