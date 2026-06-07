// telemetry_tool.asm — Upstream telemetry: joystick + sprite collision
//
// Sends fixed 8-byte packets to server when enabled and subscribed.
// All channels off by default. Server enables via 'J' command.
//
// Packet format (8 bytes):
//   0x7E  sync
//   0x55  type id
//   seq   rolling sequence 0..255
//   joy1  joystick port 2 ($DC00) active-high, or 0 if unsubscribed
//   joy2  joystick port 1 ($DC01) active-high, or 0 if unsubscribed
//   spr_spr  sprite-sprite collision ($D01E), or 0 if unsubscribed
//   spr_bg   sprite-background collision ($D01F), or 0 if unsubscribed
//   checksum (bytes 2..7 sum) & 0xFF

.const CIA1_PORT_A = $DC00  // Joystick port 2
.const CIA1_PORT_B = $DC01  // Joystick port 1
.const VIC_SPR_SPR = $D01E  // Sprite-sprite collision latch
.const VIC_SPR_BG  = $D01F  // Sprite-background collision latch

.const TELEM_SYNC  = $7E
.const TELEM_TYPE  = $55

// Channel mask bits
.const TELEM_CH_JOY1    = $01
.const TELEM_CH_JOY2    = $02
.const TELEM_CH_SPR_SPR = $04
.const TELEM_CH_SPR_BG  = $08

// ---------------------------------------------------------------------------
// telemetry_maybe_send — called from main loop each iteration
//   Checks enabled flag, decrements countdown, sends packet when due.
// ---------------------------------------------------------------------------
telemetry_maybe_send:
  lda telemetry_enabled
  beq telemetry_done
  dec telemetry_countdown
  bne telemetry_done
  // Countdown expired — reload and send
  lda telemetry_divider
  sta telemetry_countdown
  jsr telemetry_sample
  jsr telemetry_build_packet
  jsr telemetry_send_packet
telemetry_done:
  rts

// ---------------------------------------------------------------------------
// telemetry_oneshot — send a single telemetry packet immediately
// ---------------------------------------------------------------------------
telemetry_oneshot:
  jsr telemetry_sample
  jsr telemetry_build_packet
  jsr telemetry_send_packet
  rts

// ---------------------------------------------------------------------------
// telemetry_sample — read hardware based on channel mask
// ---------------------------------------------------------------------------
telemetry_sample:
  lda #0
  sta telemetry_joy1
  sta telemetry_joy2
  sta telemetry_spr_spr
  sta telemetry_spr_bg

  lda telemetry_mask
  lsr                       // bit 0 -> carry = joy1 (port 2)
  bcc telemetry_skip_joy1
  lda CIA1_PORT_A
  eor #$1f                  // invert low 5 bits -> active high
  and #$1f
  sta telemetry_joy1
telemetry_skip_joy1:

  lda telemetry_mask
  lsr
  lsr                       // bit 1 -> carry = joy2 (port 1)
  bcc telemetry_skip_joy2
  lda CIA1_PORT_B
  eor #$1f
  and #$1f
  sta telemetry_joy2
telemetry_skip_joy2:

  lda telemetry_mask
  lsr
  lsr
  lsr                       // bit 2 -> carry = sprite-sprite
  bcc telemetry_skip_spr_spr
  lda VIC_SPR_SPR
  sta telemetry_spr_spr
telemetry_skip_spr_spr:

  lda telemetry_mask
  lsr
  lsr
  lsr
  lsr                       // bit 3 -> carry = sprite-bg
  bcc telemetry_skip_spr_bg
  lda VIC_SPR_BG
  sta telemetry_spr_bg
telemetry_skip_spr_bg:
  rts

// ---------------------------------------------------------------------------
// telemetry_build_packet — fill 8-byte buffer, compute checksum
// ---------------------------------------------------------------------------
telemetry_build_packet:
  lda #TELEM_SYNC
  sta telemetry_buffer+0
  lda #TELEM_TYPE
  sta telemetry_buffer+1
  lda telemetry_seq
  sta telemetry_buffer+2
  lda telemetry_joy1
  sta telemetry_buffer+3
  lda telemetry_joy2
  sta telemetry_buffer+4
  lda telemetry_spr_spr
  sta telemetry_buffer+5
  lda telemetry_spr_bg
  sta telemetry_buffer+6
  // Checksum = (bytes 2..7 sum) & 0xFF
  clc
  lda telemetry_buffer+2
  adc telemetry_buffer+3
  adc telemetry_buffer+4
  adc telemetry_buffer+5
  adc telemetry_buffer+6
  and #$ff
  sta telemetry_buffer+7
  // Increment sequence counter
  inc telemetry_seq
  rts

// ---------------------------------------------------------------------------
// telemetry_send_packet — blast 8 bytes via sw_putxfer
// ---------------------------------------------------------------------------
telemetry_send_packet:
  ldx #0
telemetry_send_loop:
  lda telemetry_buffer,x
  jsr sw_putxfer
  inx
  cpx #8
  bne telemetry_send_loop
  rts

// ---------------------------------------------------------------------------
// protocol_telemetry — 'J' command handler
//   J0       = disable telemetry
//   J1 dd mm = enable with divider dd (hex), channel mask mm (hex)
//   J2       = one-shot immediate packet
// ---------------------------------------------------------------------------
protocol_telemetry:
  jsr protocol_read_byte
  and #$7f
  cmp #$30                  // '0' = disable
  beq protocol_telemetry_off
  cmp #$31                  // '1' = enable
  beq protocol_telemetry_on
  cmp #$32                  // '2' = one-shot
  beq protocol_telemetry_oneshot
  rts

protocol_telemetry_off:
  lda #0
  sta telemetry_enabled
  sta telemetry_mask
  rts

protocol_telemetry_on:
  jsr protocol_read_hex_byte
  sta telemetry_divider
  sta telemetry_countdown
  jsr protocol_read_hex_byte
  sta telemetry_mask
  lda #0
  sta telemetry_seq
  lda #1
  sta telemetry_enabled
  rts

protocol_telemetry_oneshot:
  jsr telemetry_oneshot
  rts

// ---------------------------------------------------------------------------
// Telemetry state variables
// ---------------------------------------------------------------------------
telemetry_enabled:
  .byte 0
telemetry_divider:
  .byte 3                   // default 3 frames between sends (20Hz PAL)
telemetry_countdown:
  .byte 3
telemetry_seq:
  .byte 0
telemetry_mask:
  .byte 0                   // no channels active by default
telemetry_joy1:
  .byte 0
telemetry_joy2:
  .byte 0
telemetry_spr_spr:
  .byte 0
telemetry_spr_bg:
  .byte 0
telemetry_buffer:
  .fill 8, 0
