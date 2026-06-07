// Custom High-speed Local Animation Player command 'O'
.const RESTORE_SCR_HI = >RESTORE_BUF_BASE
.const RESTORE_COL_HI = >(RESTORE_BUF_BASE + $0400)

// Receives:
//   - Frame Count (hex byte)
//   - Jiffy Delay (hex byte)
//   - Palette Mode (hex byte: 0=B&W, 1=Color)
//
// Buffers are expected at:
//   - Screen RAM starts at $2C00 (high byte $2C)
//   - Color RAM starts at $3000 (high byte $30)

protocol_custom_restore:
  cld                        // Clear decimal flag to guarantee binary addition
  jsr protocol_read_hex_byte // 1. Read Frame Count
  sta anim_frame_count
  jsr protocol_read_hex_byte // 2. Read Jiffy Delay
  sta anim_jiffy_delay
  jsr protocol_read_hex_byte // 3. Read Palette Mode (0=B&W, 1=Color)
  sta anim_palette_mode

  // Point all screen-page dest writes (both loop variants) at the active
  // screen base. Colour RAM is fixed at $D800 and is never rebased.
  lda screen_base_hi
  sta cust_dst_p0+2
  sta cust_dst_so0+2
  clc
  adc #1
  sta cust_dst_p1+2
  sta cust_dst_so1+2
  clc
  adc #1
  sta cust_dst_p2+2
  sta cust_dst_so2+2
  clc
  adc #1
  sta cust_dst_p3+2
  sta cust_dst_so3+2

anim_loop_start:
  lda #0
  sta anim_current_frame

anim_frame_loop:
  // Check if any byte has arrived in the serial ring buffer (from the server)
  lda rhead
  cmp rtail
  beq !+
  jmp anim_exit              // If a byte is received over serial, exit animation loop!
!:

  // Also check local keyboard for manual exit
  jsr GETIN
  beq !+
  jmp anim_exit
!:

  // Calculate addresses for current frame
  lda anim_palette_mode
  bne anim_color_mode

  // B&W Mode: screen_hi = RESTORE_SCR_HI + idx * 4
  lda anim_current_frame
  asl
  asl                        // idx * 4
  clc
  adc #RESTORE_SCR_HI        // + RESTORE_SCR_HI
  sta cust_scr_p0_so+2
  clc
  adc #1
  sta cust_scr_p1_so+2
  clc
  adc #1
  sta cust_scr_p2_so+2
  clc
  adc #1
  sta cust_scr_p3_so+2
  
  jsr custom_restore_screen_only_loop_exec
  jmp anim_wait

anim_color_mode:
  // Color Mode: screen_hi = RESTORE_SCR_HI + idx * 8, color_hi = RESTORE_COL_HI + idx * 8
  lda anim_current_frame
  asl
  asl
  asl                        // idx * 8
  sta temp_offset
  
  clc
  lda temp_offset
  adc #RESTORE_SCR_HI
  sta cust_scr_p0+2
  clc
  adc #1
  sta cust_scr_p1+2
  clc
  adc #1
  sta cust_scr_p2+2
  clc
  adc #1
  sta cust_scr_p3+2

  clc
  lda temp_offset
  adc #RESTORE_COL_HI
  sta cust_col_p0+2
  clc
  adc #1
  sta cust_col_p1+2
  clc
  adc #1
  sta cust_col_p2+2
  clc
  adc #1
  sta cust_col_p3+2

  jsr custom_restore_loop_exec

anim_wait:
  // Wait for Jiffy Delay
  lda anim_jiffy_delay
  beq anim_next              // If delay is 0, skip wait
  sta wait_counter
anim_wait_loop:
  lda $a2                    // Read jiffy clock low byte
!:
  cmp $a2
  beq !-                     // Wait for jiffy to change (1/60 sec)
  dec wait_counter
  bne anim_wait_loop

anim_next:
  // Advance frame
  inc anim_current_frame
  lda anim_current_frame
  cmp anim_frame_count
  bcs !+                     // If carry set (idx >= count), loop infinitely
  jmp anim_frame_loop        // Else (idx < count), jump back to frame loop!
!:
  
  // Loop infinitely
  jmp anim_loop_start

anim_exit:
  jsr sw_getxfer             // Consume the serial stop byte
  jmp protocol_ack           // Send ACK back to server and return to main loop

// Subroutines
custom_restore_loop_exec:
  ldx #0
custom_restore_loop:
cust_scr_p0: lda RESTORE_BUF_BASE,x
cust_dst_p0:
  sta $0400,x
cust_scr_p1: lda (RESTORE_BUF_BASE + $0100),x
cust_dst_p1:
  sta $0500,x
cust_scr_p2: lda (RESTORE_BUF_BASE + $0200),x
cust_dst_p2:
  sta $0600,x
cust_col_p0: lda (RESTORE_BUF_BASE + $0400),x
  sta $d800,x
cust_col_p1: lda (RESTORE_BUF_BASE + $0500),x
  sta $d900,x
cust_col_p2: lda (RESTORE_BUF_BASE + $0600),x
  sta $da00,x
  inx
  bne custom_restore_loop

  ldx #0
custom_restore_last_loop:
cust_scr_p3: lda (RESTORE_BUF_BASE + $0300),x
cust_dst_p3:
  sta $0700,x
cust_col_p3: lda (RESTORE_BUF_BASE + $0700),x
  sta $db00,x
  inx
  cpx #232
  bne custom_restore_last_loop
  rts

custom_restore_screen_only_loop_exec:
  ldx #0
custom_restore_screen_only_loop:
cust_scr_p0_so: lda RESTORE_BUF_BASE,x
cust_dst_so0:
  sta $0400,x
cust_scr_p1_so: lda (RESTORE_BUF_BASE + $0100),x
cust_dst_so1:
  sta $0500,x
cust_scr_p2_so: lda (RESTORE_BUF_BASE + $0200),x
cust_dst_so2:
  sta $0600,x
  inx
  bne custom_restore_screen_only_loop

  ldx #0
custom_restore_screen_only_last:
cust_scr_p3_so: lda (RESTORE_BUF_BASE + $0300),x
cust_dst_so3:
  sta $0700,x
  inx
  cpx #232
  bne custom_restore_screen_only_last
  rts

// Storage variables
anim_frame_count: .byte 0
anim_jiffy_delay: .byte 0
anim_palette_mode: .byte 0
anim_current_frame: .byte 0
temp_offset: .byte 0
wait_counter: .byte 0
