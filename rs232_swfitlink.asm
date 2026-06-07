// CCGMS Terminal
//
// Copyright (c) 2016,2022, Craig Smith, alwyz, Michael Steil. All rights reserved.
// This project is licensed under the BSD 3-Clause License.
//
// RS232 SwiftLink/Turbo232 (MOS 6551 ACIA) Driver
//  based on Jeff Brown adaptation of Novaterm version
//

// KERNAL RS-232 workspace
.const RIDBE   = $029b
.const RIDBS   = $029c
.const RODBS   = $029d
.const rtail   = RIDBE
.const rhead   = RIDBS
.const rfree   = RODBS
.const JIFFIES = $a2

// Receive buffer used by the original CCGMS driver.
// ribuf is allocated dynamically at the end of rift64.asm

.const stopsw  = 1
.const startsw = 0

// SwiftLink registers
.const swift = $de00   // will be runtime-patched to $DE00/$DF00/$D700
.const sw_data = swift
.const sw_stat = swift+1
.const sw_cmd  = swift+2
.const sw_ctrl = swift+3

//----------------------------------------------------------------------
// new NMI handler
nmisw:
  pha
  txa
  pha
  tya
  pha
sm1:  lda sw_stat
  and #%00001000  // mask out all but receive interrupt reg
  bne sm2   // get outta here if interrupts are disabled (disk access etc)
  // Non-receive NMI (the RESTORE key was pressed). If RUN/STOP is also held,
  // perform a clean software reset back to the endpoint screen; otherwise a
  // bare RESTORE press remains a harmless no-op.
  lda #$7f
  sta $dc00       // select keyboard matrix column 7
  lda $dc01
  and #%10000000  // bit 7 = RUN/STOP (0 = pressed)
  bne nmi_no_reset
  jmp software_reset
nmi_no_reset:
  sec   // set carry upon return
  bcs recch1
sm2:  lda sw_cmd
  ora #%00000010  // disable receive interrupts
sm3:  sta sw_cmd
sm4:  lda sw_data
  ldx rtail
  sta ribuf,x
  inc rtail
  inc rfree
  lda rfree
  cmp #200  // check byte count against tolerance
  bcc nmisw_buffer_ok // is it over the top?
  ldx #stopsw
  stx paused  // x=1 for stop, by the way
  jsr flow
nmisw_buffer_ok:
sm5:  lda sw_cmd
  and #%11111101  // re-enable receive interrupt
sm6:  sta sw_cmd
  clc
recch1: pla
  tay
  pla
  tax
  pla
  jmp rs232_rti

//----------------------------------------------------------------------
flow:
sm7:  lda sw_cmd
  and #%11110011
  cpx #stopsw
  beq flow_done
  ora #%00001000
flow_done:
sm8:  sta sw_cmd
  rts

//----------------------------------------------------------------------
swwait:
sm9:  lda sw_cmd
  ora #%00001000  // enable transmitter
sm10: sta sw_cmd
sm11: lda sw_stat
  and #%00110000
  beq swwait
  rts

//----------------------------------------------------------------------
sw_disable:
sm12: lda sw_cmd
  ora #%00000010  // disable receive interrupt
sm13: sta sw_cmd
  rts

//----------------------------------------------------------------------
sw_enable:
sm14: lda sw_cmd
  and #%11111101  // enable receive interrupt
sm15: sta sw_cmd
  rts

//----------------------------------------------------------------------
// A: modem_type
// X: baud_rate
sw_setup:
// set SwiftLink address by modifying all access code
  cmp #MODEM_TYPE_SWIFTLINK_DE
  beq sw_setup_de
  cmp #MODEM_TYPE_SWIFTLINK_DF
  beq sw_setup_df
  lda #$d7  // else MODEM_TYPE_SWIFTLINK_D7
  bne sw_setup_cont
sw_setup_de:
  lda #$de
  bne sw_setup_cont
sw_setup_df:
  lda #$df
sw_setup_cont:
  sta sm1+2
  sta sm2+2
  sta sm3+2
  sta sm4+2
  sta sm5+2
  sta sm6+2
  sta sm7+2
  sta sm8+2
  sta sm9+2
  sta sm10+2
  sta sm11+2
  sta sm12+2
  sta sm13+2
  sta sm14+2
  sta sm15+2
  sta sm16+2
  sta sm17+2
  sta sm18+2
  sta sm19+2
  sta sm20+2
  sta sm21+2
  sta sm22+2
  sta sm23+2
  sta sm24+2

  sei
//             .------------------------- parity control,
//             :.------------------------ bits 5-7
//             ::.----------------------- 000 = no parity
//             :::
//             :::.------------------- echo mode, 0 = normal (no echo)
//             ::::
//             ::::.----------- transmit interrupt control, bits 2-3
//             :::::.---------- 10 = xmit interrupt off, RTS low
//             ::::::
//             ::::::.------ receive interrupt control, 0 = enabled
//             :::::::
//             :::::::.--- DTR control, 1=DTR low
  lda #%00001001
sm16: sta sw_cmd
//             .------------------------- 0 = one stop bit
//             :
//             :.-------------------- word length, bits 6-7
//             ::.------------------- 00 = eight-bit word
//             :::
//             :::.------------- clock source, 1 = internal generator
//             ::::
//             ::::.----- baud
//             :::::.---- rate
//             ::::::.--- bits   //1010 == 4800 baud, changes later
//             :::::::.-- 0-3
  lda #%00010000
sm17: sta sw_ctrl

sm18: lda sw_ctrl
  and #$f0
  ora swbaud,x  // baud_rate
sm19: sta sw_ctrl

  lda #<nmisw
  ldx #>nmisw
  sta $0318 // NMINV
  stx $0319

  cli
  rts

//----------------------------------------------------------------------
sw_putxfer:
  pha
sm20: lda sw_cmd
  sta sw_putxfer_saved_cmd
  jsr swwait
  pla
  pha
sm21: sta sw_data
  jsr swwait
  lda sw_putxfer_saved_cmd
sm22: sta sw_cmd
  pla
  clc
  rts

//----------------------------------------------------------------------
// get byte from serial interface
sw_getxfer:
  ldx rhead
  cpx rtail
  beq sw_getxfer_empty // skip (empty buffer, return with carry set)
  lda ribuf,x
  pha
  inc rhead
  dec rfree
  ldx paused  // are we stopped?
  beq sw_getxfer_resume_done // no, don't bother
  lda rfree // check buffer free
  cmp #50   // against restart limit
  bcs sw_getxfer_resume_done // is it larger than 50?
  ldx #startsw  // if no, then don't start yet
  stx paused
  jsr flow
sw_getxfer_resume_done:
  clc
  pla
sw_getxfer_empty:
  rts

// Standalone RTI target for this single-file conversion.
rs232_rti:
  rti

//----------------------------------------------------------------------
// Hardware carrier detect (MOS 6551 ACIA /DCD, status register bit 5).
//   bit 5 = 0 -> /DCD low  -> carrier present (connected)
//   bit 5 = 1 -> /DCD high -> no carrier      (line dropped)
// TCPSER asserts/drops DCD on TCP socket connect/close, so this detects a
// dropped *direct* connection even when no "NO CARRIER" text ever arrives.

// Arm carrier monitoring. Call once right after CONNECT. If DCD already reads
// "no carrier" here, the SwiftLink/host isn't presenting a usable DCD line,
// so monitoring stays disabled to avoid false disconnects (the in-band
// "NO CARRIER" matcher remains as the fallback).
sw_carrier_arm:
sm23: lda sw_stat
  and #%00100000
  beq sw_carrier_arm_on
  lda #0
  sta dcd_monitor
  rts
sw_carrier_arm_on:
  lda #1
  sta dcd_monitor
  rts

// Poll for carrier loss. Returns carry SET if the line has dropped (only when
// monitoring was successfully armed), carry CLEAR otherwise.
sw_carrier_lost:
  lda dcd_monitor
  beq sw_carrier_present   // monitoring disabled -> never report loss
sm24: lda sw_stat
  and #%00100000
  bne sw_carrier_gone      // bit set -> no carrier
sw_carrier_present:
  clc
  rts
sw_carrier_gone:
  sec
  rts

//----------------------------------------------------------------------
paused:
  .byte 0
sw_putxfer_saved_cmd:
  .byte 0
dcd_monitor:
  .byte 0

//----------------------------------------------------------------------
// MOS 6551 ACIA baud rate constants used by the CCGMS baud table
.const SW_BAUD_150 = %10101
.const SW_BAUD_600 = %10111
.const SW_BAUD_1200  = %11000
.const SW_BAUD_2400  = %11010
.const SW_BAUD_4800  = %11100
.const SW_BAUD_9600  = %11110
.const SW_BAUD_19200 = %11111

swbaud:
// The SwiftLink/Turbo232 baud rate generator is 2x that of the spec,
// so the ACIA has half the rates set up.
  .byte SW_BAUD_150 // 300
  .byte SW_BAUD_600 // 1200
  .byte SW_BAUD_1200  // 2400
  .byte SW_BAUD_2400  // 2400
  .byte SW_BAUD_4800  // 4800
  .byte SW_BAUD_9600  // 9600
  .byte SW_BAUD_19200 // 38400

  .byte $10,$10,$10 // [XXX unused]
