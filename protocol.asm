// Protocol command handlers.
//
// Dispatches incoming RIFT64 protocol bytes to the appropriate handler.
// Includes all command implementations: text, color, position, window,
// border, scroll, memory, sprite, frame, capabilities, and helpers.

protocol_read_byte:
  jsr sw_getxfer
  bcs protocol_read_byte
  rts

poll_keyboard:
  jsr GETIN
  beq poll_keyboard_done
  jsr sw_putxfer
poll_keyboard_done:
  rts

// Dispatcher: each entry uses bne+jmp instead of beq to a jump shim, so
// the branch distance is bounded (always to the next !: label) regardless
// of how far the target handler lives in the file. Adding new commands
// here is safe — no relative-branch-too-far risk.
protocol_handle_byte:
  and #$7f
  cmp #33
  bne !+
  jmp protocol_text
!:
  cmp #84
  bne !+
  jmp protocol_colored_text
!:
  cmp #75
  bne !+
  jmp protocol_color
!:
  cmp #80
  bne !+
  jmp protocol_position
!:
  cmp #67
  bne !+
  jmp protocol_clear
!:
  cmp #87
  bne !+
  jmp protocol_window
!:
  cmp #86
  bne !+
  jmp protocol_colored_window
!:
  cmp #66
  bne !+
  jmp protocol_border
!:
  cmp #83
  bne !+
  jmp protocol_save_buffer
!:
  cmp #82
  bne !+
  jmp protocol_restore_buffer
!:
  cmp #69
  bne !+
  jmp protocol_erase_line
!:
  cmp #77
  bne !+
  jmp protocol_memory_store
!:
  cmp #89
  bne !+
  jmp protocol_sprite_set
!:
  cmp #64
  bne !+
  jmp protocol_sprite_position
!:
  cmp #71
  bne !+
  jmp protocol_scroll_region
!:
  cmp #72
  bne !+
  jmp protocol_cursor_visibility
!:
  cmp #63
  bne !+
  jmp protocol_capabilities
!:
  cmp #76
  bne !+
  jmp protocol_length_text
!:
  cmp #81
  bne !+
  jmp protocol_color_block
!:
  cmp #88
  bne !+
  jmp protocol_checked_window
!:
  cmp #90
  bne !+
  jmp protocol_checked_memory
!:
  cmp #126
  bne !+
  jmp protocol_frame
!:
  cmp #70
  bne !+
  jmp protocol_charset_bank
!:
  cmp #65
  bne !+
  jmp protocol_audio
!:
  cmp #73
  bne !+
  jmp protocol_display_mode
!:
  cmp #85
  bne !+
  jmp protocol_sprite_mc
!:
  cmp #74
  bne !+
  jmp protocol_telemetry
!:
  cmp #68
  bne !+
  jmp protocol_draw_metatile
!:
  cmp #78
  bne !+
  jmp protocol_raster_split
!:
  cmp #79 // ASCII 'O'
  bne !+
  jmp protocol_custom_restore
!:
  rts

protocol_text:
  jsr protocol_read_byte
  and #$7f
  cmp #13
  beq protocol_done
  cmp #10
  beq protocol_done
  jsr print_char
  jmp protocol_text

protocol_colored_text:
  jsr protocol_read_hex_nibble
  and #$0f
  sta text_color
  jmp protocol_text

protocol_color:
  jsr protocol_read_hex_nibble
  and #$0f
  sta $d021
  sta $d020
  jsr protocol_read_hex_nibble
  and #$0f
  sta text_color
protocol_done:
  rts

protocol_charset_bank:
  jsr protocol_read_hex_nibble
  and #$07
  sta video_bank_bits
  lda $dd02
  ora #%00000011
  sta $dd02
  lda $dd00
  and #%11111100
  ora video_bank_bits
  sta $dd00
  jsr protocol_read_hex_byte
  sta video_d018_value
  lda video_d018_value
  sta $d018
  jsr apply_screen_base
  jmp protocol_ack

protocol_display_mode:
  jsr protocol_read_hex_byte
  sta video_mode_value
  jsr protocol_read_hex_byte
  and #$03
  sta video_bank_bits
  lda $dd02
  ora #%00000011
  sta $dd02
  lda $dd00
  and #%11111100
  ora video_bank_bits
  sta $dd00
  jsr protocol_read_hex_byte
  sta video_d018_value
  sta $d018
  jsr protocol_read_hex_byte
  sta $d011
  jsr protocol_read_hex_byte
  sta $d016
  jsr protocol_read_hex_byte
  sta $d020
  jsr protocol_read_hex_byte
  sta $d021
  jsr apply_screen_base
  jmp protocol_ack

protocol_position:
  jsr protocol_read_hex_byte
  cmp #40
  bcc protocol_position_x_ok
  lda #39
protocol_position_x_ok:
  sta cursor_x
  jsr protocol_read_hex_byte
  cmp #25
  bcc protocol_position_y_ok
  lda #24
protocol_position_y_ok:
  sta cursor_y
  rts

protocol_clear:
  jmp clear_screen

protocol_erase_line:
  jsr protocol_read_hex_byte
  sta erase_count
  lda cursor_x
  sta erase_start_x
  lda cursor_y
  sta erase_start_y
protocol_erase_loop:
  lda erase_count
  beq protocol_erase_done
  lda #32
  jsr put_window_char
  inc cursor_x
  dec erase_count
  jmp protocol_erase_loop
protocol_erase_done:
  lda erase_start_x
  sta cursor_x
  lda erase_start_y
  sta cursor_y
  rts

protocol_capabilities:
  ldx #<capability_msg
  ldy #>capability_msg
  jmp send_string

protocol_ack:
  lda #65
  jmp sw_putxfer

protocol_nak:
  lda #78
  jmp sw_putxfer

protocol_length_text:
  jsr protocol_read_hex_byte
  sta transfer_remaining
  beq protocol_length_text_256
protocol_length_text_loop:
  jsr protocol_read_byte
  and #$7f
  jsr print_char
  dec transfer_remaining
  bne protocol_length_text_loop
  jmp protocol_ack
protocol_length_text_256:
  jsr protocol_read_byte
  and #$7f
  jsr print_char
  dec transfer_remaining
  bne protocol_length_text_256
  jmp protocol_ack

protocol_color_block:
  jsr protocol_read_hex_byte
  cmp #40
  bcc color_block_x_ok
  lda #39
color_block_x_ok:
  sta block_x
  jsr protocol_read_hex_byte
  cmp #25
  bcc color_block_y_ok
  lda #24
color_block_y_ok:
  sta block_y
  jsr protocol_read_hex_byte
  beq color_block_width_zero
  jmp color_block_width_have
color_block_width_zero:
  lda #1
color_block_width_have:
  sta block_width
  jsr protocol_read_hex_byte
  beq color_block_height_zero
  jmp color_block_height_have
color_block_height_zero:
  lda #1
color_block_height_have:
  sta block_height
  lda #0
  sta block_row
color_block_row_loop:
  lda block_row
  cmp block_height
  beq color_block_done
  lda block_y
  clc
  adc block_row
  cmp #25
  bcs color_block_skip_row
  tax
  lda color_lo,x
  sta color_block_store+1
  lda color_hi,x
  sta color_block_store+2
  lda #0
  sta block_col
color_block_col_loop:
  lda block_col
  cmp block_width
  beq color_block_next_row
  jsr protocol_read_byte
  and #$0f
  sta block_color
  lda block_x
  clc
  adc block_col
  cmp #40
  bcs color_block_col_done
  tay
  lda block_color
color_block_store:
  sta $d800,y
color_block_col_done:
  inc block_col
  jmp color_block_col_loop
color_block_skip_row:
  lda #0
  sta block_col
color_block_skip_loop:
  lda block_col
  cmp block_width
  beq color_block_next_row
  jsr protocol_read_byte
  inc block_col
  jmp color_block_skip_loop
color_block_next_row:
  inc block_row
  jmp color_block_row_loop
color_block_done:
  jmp protocol_ack

protocol_checked_window:
  jsr read_clamp_width
  sta window_width
  jsr read_clamp_height
  sta window_height
  jsr compute_window_total
  lda transfer_total
  sta transfer_remaining
  lda #0
  sta checksum_calc
  ldy #0
checked_window_read_loop:
  jsr protocol_read_byte
  sta MemoryStoreBuffer,y
  clc
  adc checksum_calc
  sta checksum_calc
  iny
  dec transfer_remaining
  bne checked_window_read_loop
  jsr protocol_read_hex_byte
  cmp checksum_calc
  beq checked_window_valid
  jmp protocol_nak
checked_window_valid:
  jsr protocol_ack
  lda cursor_x
  sta window_start_x
  lda #0
  sta buffer_index
  sta window_row
checked_window_row_loop:
  lda window_row
  cmp window_height
  beq checked_window_done
  lda window_start_x
  sta cursor_x
  lda #0
  sta window_col
checked_window_col_loop:
  lda window_col
  cmp window_width
  beq checked_window_next_row
  ldy buffer_index
  lda MemoryStoreBuffer,y
  and #$7f
  jsr put_window_char
  inc cursor_x
  inc buffer_index
  inc window_col
  jmp checked_window_col_loop
checked_window_next_row:
  inc cursor_y
  inc window_row
  jmp checked_window_row_loop
checked_window_done:
  rts

protocol_checked_memory:
  jsr protocol_read_hex_byte
  sta MemoryStoreDestHi
  jsr protocol_read_hex_byte
  sta MemoryStoreDestLo
  jsr protocol_read_hex_byte
  sta MemoryStoreLength
  lda MemoryStoreLength
  sta transfer_remaining
  lda #0
  sta checksum_calc
  ldy #0
checked_memory_read_loop:
  jsr protocol_read_byte
  sta MemoryStoreBuffer,y
  clc
  adc checksum_calc
  sta checksum_calc
  iny
  dec transfer_remaining
  bne checked_memory_read_loop
  jsr protocol_read_hex_byte
  cmp checksum_calc
  beq checked_memory_valid
  jmp protocol_nak
checked_memory_valid:
  jsr memory_store_copy
  jmp protocol_ack

protocol_frame:
  jsr protocol_read_byte
  and #$7f
  sta frame_command
  sta checksum_calc
  jsr protocol_read_hex_byte
  sta frame_length
  sta transfer_remaining
  clc
  adc checksum_calc
  sta checksum_calc
  ldy #0
  lda frame_length
  beq frame_read_256
frame_read_loop:
  jsr protocol_read_byte
  sta MemoryStoreBuffer,y
  clc
  adc checksum_calc
  sta checksum_calc
  iny
  dec transfer_remaining
  bne frame_read_loop
  jmp frame_read_done
frame_read_256:
  jsr protocol_read_byte
  sta MemoryStoreBuffer,y
  clc
  adc checksum_calc
  sta checksum_calc
  iny
  bne frame_read_256
frame_read_done:
  jsr protocol_read_hex_byte
  cmp checksum_calc
  beq frame_valid
  jmp protocol_nak
frame_valid:
  jsr protocol_ack
  lda frame_command
  cmp #67
  beq frame_clear
  cmp #76
  beq frame_text
  rts
frame_clear:
  jmp clear_screen
frame_text:
  lda frame_length
  sta transfer_remaining
  ldy #0
frame_text_loop:
  lda MemoryStoreBuffer,y
  and #$7f
  jsr print_char
  iny
  dec transfer_remaining
  bne frame_text_loop
  rts

compute_window_total:
  lda #0
  sta transfer_total
  ldx window_height
compute_window_total_row:
  clc
  adc window_width
  dex
  bne compute_window_total_row
  sta transfer_total
  rts

protocol_cursor_visibility:
  jsr protocol_read_byte
  and #$7f
  cmp #49
  beq protocol_cursor_visibility_on
  lda #0
  sta cursor_enabled
  jmp hide_cursor
protocol_cursor_visibility_on:
  lda #1
  sta cursor_enabled
  rts

.import source "scroll.asm"

protocol_memory_store:
  jsr protocol_read_hex_byte
  sta MemoryStoreDestHi
  jsr protocol_read_hex_byte
  sta MemoryStoreDestLo
  jsr protocol_read_hex_byte
  sta MemoryStoreLength
  ldy #0
  lda MemoryStoreLength
  beq protocol_memory_read_256
  sta MemoryStoreReadRemaining
protocol_memory_read_loop:
  jsr protocol_read_byte
  sta MemoryStoreBuffer,y
  iny
  dec MemoryStoreReadRemaining
  bne protocol_memory_read_loop
  jmp memory_store_copy

protocol_memory_read_256:
  jsr protocol_read_byte
  sta MemoryStoreBuffer,y
  iny
  bne protocol_memory_read_256
  jmp memory_store_copy

// Common sprite parameter reader: reads 8 hex bytes into Sprite* variables.
sprite_read_common:
  jsr protocol_read_hex_byte
  sta SpriteId
  jsr protocol_read_hex_byte
  sta SpriteXHi
  jsr protocol_read_hex_byte
  sta SpriteXLo
  jsr protocol_read_hex_byte
  sta SpriteY
  jsr protocol_read_hex_byte
  sta SpriteColor
  jsr protocol_read_hex_byte
  sta SpritePointer
  jsr protocol_read_hex_byte
  sta SpriteVicBank
  jsr protocol_read_hex_byte
  sta SpriteEnabled
  rts

protocol_sprite_set:
  jsr sprite_read_common
  jsr sprite_set_vic_bank
  jsr sprite_set_pointer
  jsr sprite_set_color
  jsr sprite_set_position
  lda SpriteEnabled
  beq protocol_sprite_disable
  jmp sprite_enable
protocol_sprite_disable:
  jmp sprite_disable

// @ command: Lightweight batch sprite position set
// Format: 1 hex byte (sprite mask), followed by 3 hex bytes (XHi, XLo, Y) per active sprite
protocol_sprite_position:
  jsr protocol_read_hex_byte
  sta sprite_pos_mask
  lda #0
  sta sprite_pos_id

psp_loop:
  lda sprite_pos_mask
  beq psp_done

  lsr sprite_pos_mask
  bcc psp_next

  jsr protocol_read_hex_byte
  sta SpriteXHi
  jsr protocol_read_hex_byte
  sta SpriteXLo
  jsr protocol_read_hex_byte
  sta SpriteY

  lda sprite_pos_id
  sta SpriteId
  jsr sprite_set_position

psp_next:
  inc sprite_pos_id
  lda sprite_pos_id
  cmp #8
  bne psp_loop

psp_done:
  rts

sprite_pos_mask: .byte 0
sprite_pos_id:   .byte 0

// U command: Multicolor sprite set (extended Y with MC/expansion/priority/shared colors)
// Format: 12 hex bytes:
//   SpriteId, XHi, XLo, Y, Color, Pointer, VicBank, Enabled,
//   Flags (bit0=multicolor, bit1=expandY, bit2=expandX, bit3=priority),
//   SharedColor0, SharedColor1, (reserved/pad)
protocol_sprite_mc:
  jsr sprite_read_common
  jsr protocol_read_hex_byte
  // Flags byte: bit0=multicolor, bit1=expandY, bit2=expandX, bit3=priority
  pha
  and #$01
  sta SpriteMulticolorFlag
  pla
  pha
  lsr
  and #$01
  sta SpriteExpandYFlag
  pla
  pha
  lsr
  lsr
  and #$01
  sta SpriteExpandXFlag
  pla
  lsr
  lsr
  lsr
  and #$01
  sta SpritePriorityFlag
  jsr protocol_read_hex_byte
  sta SpriteSharedColor0
  jsr protocol_read_hex_byte
  sta SpriteSharedColor1
  jsr protocol_read_hex_byte
  // reserved - discard
  jmp sprite_set_full_mc

protocol_window:
  jsr read_clamp_width
  sta window_width

  jsr read_clamp_height
  sta window_height

  lda cursor_x
  sta window_start_x
  lda #0
  sta window_row
protocol_window_row_loop:
  lda window_row
  cmp window_height
  beq protocol_window_done
  lda window_start_x
  sta cursor_x
  lda #0
  sta window_col
protocol_window_col_loop:
  lda window_col
  cmp window_width
  beq protocol_window_next_row
  jsr protocol_read_byte
  and #$7f
  jsr put_window_char
  inc cursor_x
  inc window_col
  jmp protocol_window_col_loop
protocol_window_next_row:
  inc cursor_y
  inc window_row
  jmp protocol_window_row_loop
protocol_window_done:
  rts

protocol_colored_window:
  jsr protocol_read_hex_nibble
  and #$0f
  sta text_color
  jmp protocol_window

protocol_border:
  jsr read_clamp_width
  sta border_width

  jsr read_clamp_height
  sta border_height

  jsr protocol_read_hex_byte
  sta border_char_table+0
  jsr protocol_read_hex_byte
  sta border_char_table+1
  jsr protocol_read_hex_byte
  sta border_char_table+2
  jsr protocol_read_hex_byte
  sta border_char_table+3
  jsr protocol_read_hex_byte
  sta border_char_table+5
  jsr protocol_read_hex_byte
  sta border_char_table+6
  jsr protocol_read_hex_byte
  sta border_char_table+7
  jsr protocol_read_hex_byte
  sta border_char_table+8

  lda cursor_x
  sta border_start_x
  lda cursor_y
  sta border_start_y
  lda #0
  sta border_row
protocol_border_row_loop:
  lda border_row
  cmp border_height
  beq protocol_border_done
  lda #0
  sta border_col
protocol_border_col_loop:
  lda border_col
  cmp border_width
  beq protocol_border_next_row
  jsr select_border_char
  pha
  lda border_start_x
  clc
  adc border_col
  sta cursor_x
  lda border_start_y
  clc
  adc border_row
  sta cursor_y
  pla
  jsr put_window_char
  inc border_col
  jmp protocol_border_col_loop
protocol_border_next_row:
  inc border_row
  jmp protocol_border_row_loop
protocol_border_done:
  lda border_start_x
  sta cursor_x
  lda border_start_y
  sta cursor_y
  rts

// Border character selection via lookup table.
// Index: bit1 = top/bottom edge, bit0 = left/right edge
// Rows: top=0, middle=3, bottom=6. Cols: left=0, mid=1, right=2.
select_border_char:
  lda #0
  tax
  // Determine row class: 0=top, 3=middle, 6=bottom
  lda border_row
  bne sbc_not_top
  // top row → X=0
  jmp sbc_col
sbc_not_top:
  clc
  adc #1
  cmp border_height
  bne sbc_mid_row
  ldx #6
  jmp sbc_col
sbc_mid_row:
  ldx #3
sbc_col:
  // Determine col class: 0=left, 1=middle, 2=right
  lda border_col
  beq sbc_lookup
  clc
  adc #1
  cmp border_width
  bne sbc_col_mid
  inx
  inx
  jmp sbc_lookup
sbc_col_mid:
  inx
sbc_lookup:
  lda border_char_table,x
  rts

// 9-byte table: [top-left, top-mid, top-right, mid-left, mid-mid, mid-right, bot-left, bot-mid, bot-right]
border_char_table:
  .byte $70, $40, $6e, $42, $20, $42, $6d, $40, $7d

protocol_save_buffer:
  jsr protocol_read_byte
  and #$7f
  cmp #49
  beq save_buffer_1_setup
  lda #>screen_buffer_0
  sta save_scr_p0+2
  lda #>(screen_buffer_0+$100)
  sta save_scr_p1+2
  lda #>(screen_buffer_0+$200)
  sta save_scr_p2+2
  lda #>(screen_buffer_0+$300)
  sta save_scr_p3+2
  lda #>color_buffer_0
  sta save_col_p0+2
  lda #>(color_buffer_0+$100)
  sta save_col_p1+2
  lda #>(color_buffer_0+$200)
  sta save_col_p2+2
  lda #>(color_buffer_0+$300)
  sta save_col_p3+2
  jmp save_buffer_exec
save_buffer_1_setup:
  lda #>screen_buffer_1
  sta save_scr_p0+2
  lda #>(screen_buffer_1+$100)
  sta save_scr_p1+2
  lda #>(screen_buffer_1+$200)
  sta save_scr_p2+2
  lda #>(screen_buffer_1+$300)
  sta save_scr_p3+2
  lda #>color_buffer_1
  sta save_col_p0+2
  lda #>(color_buffer_1+$100)
  sta save_col_p1+2
  lda #>(color_buffer_1+$200)
  sta save_col_p2+2
  lda #>(color_buffer_1+$300)
  sta save_col_p3+2
save_buffer_exec:
  // Point the screen-page source reads at the active screen base. Colour RAM
  // is fixed at $D800 and is never rebased.
  lda screen_base_hi
  sta save_src_p0+2
  clc
  adc #1
  sta save_src_p1+2
  clc
  adc #1
  sta save_src_p2+2
  clc
  adc #1
  sta save_src_p3+2
  ldx #0
save_buffer_page_loop:
save_src_p0:
  lda $0400,x
save_scr_p0: sta screen_buffer_0,x
save_src_p1:
  lda $0500,x
save_scr_p1: sta screen_buffer_0+$100,x
save_src_p2:
  lda $0600,x
save_scr_p2: sta screen_buffer_0+$200,x
  lda $d800,x
save_col_p0: sta color_buffer_0,x
  lda $d900,x
save_col_p1: sta color_buffer_0+$100,x
  lda $da00,x
save_col_p2: sta color_buffer_0+$200,x
  inx
  bne save_buffer_page_loop
  ldx #0
save_buffer_last_loop:
save_src_p3:
  lda $0700,x
save_scr_p3: sta screen_buffer_0+$300,x
  lda $db00,x
save_col_p3: sta color_buffer_0+$300,x
  inx
  cpx #232
  bne save_buffer_last_loop
  rts

protocol_restore_buffer:
  jsr protocol_read_byte
  and #$7f
  cmp #49
  beq restore_buffer_1_setup
  lda #>screen_buffer_0
  sta rest_scr_p0+2
  lda #>(screen_buffer_0+$100)
  sta rest_scr_p1+2
  lda #>(screen_buffer_0+$200)
  sta rest_scr_p2+2
  lda #>(screen_buffer_0+$300)
  sta rest_scr_p3+2
  lda #>color_buffer_0
  sta rest_col_p0+2
  lda #>(color_buffer_0+$100)
  sta rest_col_p1+2
  lda #>(color_buffer_0+$200)
  sta rest_col_p2+2
  lda #>(color_buffer_0+$300)
  sta rest_col_p3+2
  jmp restore_buffer_exec
restore_buffer_1_setup:
  lda #>screen_buffer_1
  sta rest_scr_p0+2
  lda #>(screen_buffer_1+$100)
  sta rest_scr_p1+2
  lda #>(screen_buffer_1+$200)
  sta rest_scr_p2+2
  lda #>(screen_buffer_1+$300)
  sta rest_scr_p3+2
  lda #>color_buffer_1
  sta rest_col_p0+2
  lda #>(color_buffer_1+$100)
  sta rest_col_p1+2
  lda #>(color_buffer_1+$200)
  sta rest_col_p2+2
  lda #>(color_buffer_1+$300)
  sta rest_col_p3+2
restore_buffer_exec:
  // Point the screen-page dest writes at the active screen base. Colour RAM
  // is fixed at $D800 and is never rebased.
  lda screen_base_hi
  sta rest_dst_p0+2
  clc
  adc #1
  sta rest_dst_p1+2
  clc
  adc #1
  sta rest_dst_p2+2
  clc
  adc #1
  sta rest_dst_p3+2
  ldx #0
restore_buffer_page_loop:
rest_scr_p0: lda screen_buffer_0,x
rest_dst_p0:
  sta $0400,x
rest_scr_p1: lda screen_buffer_0+$100,x
rest_dst_p1:
  sta $0500,x
rest_scr_p2: lda screen_buffer_0+$200,x
rest_dst_p2:
  sta $0600,x
rest_col_p0: lda color_buffer_0,x
  sta $d800,x
rest_col_p1: lda color_buffer_0+$100,x
  sta $d900,x
rest_col_p2: lda color_buffer_0+$200,x
  sta $da00,x
  inx
  bne restore_buffer_page_loop
  ldx #0
restore_buffer_last_loop:
rest_scr_p3: lda screen_buffer_0+$300,x
rest_dst_p3:
  sta $0700,x
rest_col_p3: lda color_buffer_0+$300,x
  sta $db00,x
  inx
  cpx #232
  bne restore_buffer_last_loop
  rts

protocol_read_hex_byte:
  jsr protocol_read_hex_nibble
  asl
  asl
  asl
  asl
  sta hex_temp
  jsr protocol_read_hex_nibble
  ora hex_temp
  rts

protocol_read_hex_nibble:
  jsr protocol_read_byte
  and #$7f
  cmp #58
  bcc protocol_hex_digit
  cmp #65
  bcc protocol_hex_zero
  cmp #71
  bcs protocol_hex_zero
  sec
  sbc #55
  rts
protocol_hex_digit:
  sec
  sbc #48
  rts
protocol_hex_zero:
  lda #0
  rts

// Read hex byte and clamp to 1..40 (screen width). Result in A.
read_clamp_width:
  jsr protocol_read_hex_byte
  beq clamp_to_one
  cmp #41
  bcc clamp_width_done
  lda #40
clamp_width_done:
  rts

// Read hex byte and clamp to 1..25 (screen height). Result in A.
read_clamp_height:
  jsr protocol_read_hex_byte
  beq clamp_to_one
  cmp #26
  bcc clamp_height_done
  lda #25
clamp_height_done:
  rts

clamp_to_one:
  lda #1
  rts

.import source "metatile.asm"
.import source "raster_split.asm"

// D command: Draw metatile window. All 17 args are ASCII hex pairs.
//   D mode mapPtrLo mapPtrHi mapW mapH metaPtrHi
//     tgtPtrLo tgtPtrHi stride winW winH x y offX offY fillChar
//     colorMode colorTgtLo colorTgtHi colorSrcLo colorSrcHi colorFill
// Tile data (map + metatile slot pages) is uploaded separately via the
// existing memory-store (M) or checked-memory (Z) commands. metaPtrHi is
// a page-aligned base; renderer expects N pages of 256 bytes each, one per
// metatile slot.
//
// Colour modes:
//   00 NONE - skip colour RAM writes (caller pre-paints)
//   01 FILL - every rendered cell + edge fill gets colorFill
//   02 MAP  - mode 1: per-cell colour map at colorSrcPtr (parallel to tile map)
//             modes 2/3: 256-byte colour-per-tileId table at colorSrcPtr
//
// Acks with 'A' after render completes.
protocol_draw_metatile:
  jsr protocol_read_hex_byte
  sta MT_TileMode
  jsr protocol_read_hex_byte
  sta MT_MapPtrLo
  jsr protocol_read_hex_byte
  sta MT_MapPtrHi
  jsr protocol_read_hex_byte
  sta MT_MapWidth
  jsr protocol_read_hex_byte
  sta MT_MapHeight
  jsr protocol_read_hex_byte
  sta MT_MetaPtrHi
  jsr protocol_read_hex_byte
  sta MT_TargetPtrLo
  jsr protocol_read_hex_byte
  sta MT_TargetPtrHi
  jsr protocol_read_hex_byte
  sta MT_TargetStride
  jsr protocol_read_hex_byte
  sta MT_WindowWidth
  jsr protocol_read_hex_byte
  sta MT_WindowHeight
  jsr protocol_read_hex_byte
  sta MT_X
  jsr protocol_read_hex_byte
  sta MT_Y
  jsr protocol_read_hex_byte
  sta MT_OffX
  jsr protocol_read_hex_byte
  sta MT_OffY
  jsr protocol_read_hex_byte
  sta MT_FillChar
  jsr protocol_read_hex_byte
  sta MT_ColorMode
  jsr protocol_read_hex_byte
  sta MT_ColorTgtLo
  jsr protocol_read_hex_byte
  sta MT_ColorTgtHi
  jsr protocol_read_hex_byte
  sta MT_ColorSrcLo
  jsr protocol_read_hex_byte
  sta MT_ColorSrcHi
  jsr protocol_read_hex_byte
  sta MT_ColorFill
  jsr MT_RenderWindow
  jmp protocol_ack

// N command: VIC-II raster split.
// All 8 args are ASCII hex pairs (16 chars total after the 'N').
//   N enable splitLine topD011 topD016 topD018 botD011 botD016 botD018
// enable: 00 = disable, 01 = enable.
// All other params are always copied into RS_* config first; if enable=01
// RS_Enable is called (idempotent), else RS_Disable. Acks with 'A'.
protocol_raster_split:
  jsr protocol_read_hex_byte
  pha                          // hold enable flag
  jsr protocol_read_hex_byte
  sta RS_SplitLine
  jsr protocol_read_hex_byte
  sta RS_TopD011
  jsr protocol_read_hex_byte
  sta RS_TopD016
  jsr protocol_read_hex_byte
  sta RS_TopD018
  jsr protocol_read_hex_byte
  sta RS_BotD011
  jsr protocol_read_hex_byte
  sta RS_BotD016
  jsr protocol_read_hex_byte
  sta RS_BotD018
  pla
  beq protocol_rs_disable
  jsr RS_Enable
  jmp protocol_ack
protocol_rs_disable:
  jsr RS_Disable
  jmp protocol_ack
