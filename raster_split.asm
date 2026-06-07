// raster_split.asm
// VIC-II raster split: two graphics modes on one screen.
//
// Caller configures TOP mode and BOTTOM mode (each = raw $D011/$D016/$D018
// values) plus the split raster line. RS_Enable installs a chained IRQ on
// $0314 (so the existing audio IRQ keeps working) that flips VIC registers
// at the split line, then flips back near the top of the next frame.
//
// Off by default. RS_Enable / RS_Disable toggle it at runtime. Re-calling
// RS_Enable while already enabled is safe (no double-install of vector).
//
// IRQ flow:
//   hardware -> $FFFE -> KERNAL pushes A/X/Y -> jmp ($0314) -> rs_irq
//     - if VIC raster IRQ ($D019 bit 0 set): swap registers, ack, RTI
//     - otherwise: jmp through the saved previous $0314 vector
//       (chains to audio_irq -> KERNAL -> CIA ack)

// ------------------------------------------------------------
// Public config block (set by caller before RS_Enable).
// Raw VIC register values; caller is responsible for preserving
// vscroll/screen-on/25-row bits in $D011 and hscroll/40-col in $D016.
// ------------------------------------------------------------
RS_SplitLine:     .byte 120    // raster line where top->bot switch fires
RS_TopD011:       .byte $1b    // standard text mode (vscroll=3, screen on, 25 rows)
RS_TopD016:       .byte $08
RS_TopD018:       .byte $15    // screen=$0400, charset=$1000
RS_BotD011:       .byte $1b
RS_BotD016:       .byte $08
RS_BotD018:       .byte $15
RS_Enabled:       .byte 0      // 0=off, 1=on

// Internal state
RS_TopRetLine:    .byte 250    // raster line to swap back to TOP (lower border)
RS_NextState:     .byte 0      // 0 = next IRQ goes to BOT; 1 = next goes to TOP
RS_OldIrqVec:
RS_OldIrqLo:      .byte 0
RS_OldIrqHi:      .byte 0

// ------------------------------------------------------------
// RS_Enable -- install the chained IRQ if not already installed,
// enable VIC raster IRQ at the split line. Safe to re-call.
// ------------------------------------------------------------
RS_Enable:
  sei
  lda RS_Enabled
  bne rs_enable_already_hooked
  // capture current $0314 (likely audio_irq) and install ours
  lda $0314
  sta RS_OldIrqLo
  lda $0315
  sta RS_OldIrqHi
  lda #<rs_irq
  sta $0314
  lda #>rs_irq
  sta $0315
rs_enable_already_hooked:
  // configure VIC raster IRQ
  // clear high raster bit (split line range is 0..255 here)
  lda $d011
  and #$7f
  sta $d011
  // first IRQ = split line (TOP currently active, IRQ switches to BOT)
  lda RS_SplitLine
  sta $d012
  lda #0
  sta RS_NextState
  // make sure TOP mode is currently displayed
  lda RS_TopD011
  and #$7f                     // keep high raster bit clear
  sta $d011
  lda RS_TopD016
  sta $d016
  lda RS_TopD018
  sta $d018
  // enable VIC raster IRQ, ack any pending
  lda #$01
  sta $d01a
  sta $d019
  lda #1
  sta RS_Enabled
  cli
  rts

// ------------------------------------------------------------
// RS_Disable -- restore TOP mode, unhook IRQ vector, disable raster IRQ.
// ------------------------------------------------------------
RS_Disable:
  sei
  lda RS_Enabled
  beq rs_disable_done
  // disable VIC raster IRQ
  lda #$00
  sta $d01a
  // ack any pending
  lda #$01
  sta $d019
  // restore previous $0314 vector
  lda RS_OldIrqLo
  sta $0314
  lda RS_OldIrqHi
  sta $0315
  // restore TOP mode so the screen looks normal afterwards
  lda RS_TopD011
  sta $d011
  lda RS_TopD016
  sta $d016
  lda RS_TopD018
  sta $d018
  lda #0
  sta RS_Enabled
rs_disable_done:
  cli
  rts

// ------------------------------------------------------------
// rs_irq -- hooked into $0314. KERNAL has already pushed A/X/Y.
// If the IRQ is a VIC raster IRQ, swap modes and exit via RTI
// (popping the kernel-pushed registers ourselves). Otherwise
// chain through to the saved previous $0314 vector (audio).
// ------------------------------------------------------------
rs_irq:
  lda $d019
  and #$01
  beq rs_irq_chain

  lda RS_NextState
  bne rs_irq_to_top

  // ---- switch TOP -> BOT ----
  lda RS_BotD011
  and #$7f
  sta $d011
  lda RS_BotD016
  sta $d016
  lda RS_BotD018
  sta $d018
  lda RS_TopRetLine
  sta $d012
  lda #1
  sta RS_NextState
  jmp rs_irq_ack_exit

rs_irq_to_top:
  // ---- switch BOT -> TOP ----
  lda RS_TopD011
  and #$7f
  sta $d011
  lda RS_TopD016
  sta $d016
  lda RS_TopD018
  sta $d018
  lda RS_SplitLine
  sta $d012
  lda #0
  sta RS_NextState

rs_irq_ack_exit:
  // ack raster IRQ
  lda #$01
  sta $d019
  // pop KERNAL-pushed A/X/Y and RTI (no chaining)
  pla
  tay
  pla
  tax
  pla
  rti

rs_irq_chain:
  jmp (RS_OldIrqVec)
