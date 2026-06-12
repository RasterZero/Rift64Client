// Modem communication helpers.
//
// String transmission, receive buffer flushing, dial command building,
// and modem result token matching (OK, CONNECT, NO CARRIER, etc.).

// Hayes guard time is 1.0s of TX silence; 70 jiffies covers both
// 60Hz NTSC (1.17s) and 50Hz PAL (1.4s).
.const HANGUP_GUARD_JIFFIES = 70
.const HANGUP_RESPONSE_JIFFIES = 30

send_string:
  stx ptr
  sty ptr+1
  ldy #0
send_loop:
  lda (ptr),y
  beq send_done
  jsr sw_putxfer
  iny
  bne send_loop
send_done:
  rts

flush_rx_buffer:
  jsr sw_getxfer
  bcc flush_rx_buffer
  rts

// Force any lingering session out of online mode and hang up.
// A RUN/STOP+RESTORE mid-session leaves tcpser/Hayes modems connected
// (default profiles ignore the DTR drop in sw_disable), so escape and
// hang up before every AT handshake.
modem_hangup_sequence:
  jsr flush_rx_buffer
  ldx #HANGUP_GUARD_JIFFIES   // TX silence before escape
  jsr delay_jiffies
  lda #43                     // '+'
  jsr sw_putxfer
  lda #43
  jsr sw_putxfer
  lda #43
  jsr sw_putxfer
  ldx #HANGUP_GUARD_JIFFIES   // TX silence after escape
  jsr delay_jiffies
  ldx #<hangup_cmd
  ldy #>hangup_cmd
  jsr send_string
  ldx #HANGUP_RESPONSE_JIFFIES
  jsr delay_jiffies           // let OK/ERROR/NO CARRIER arrive
  jmp flush_rx_buffer         // discard responses; tail-call rts

// X = jiffies to wait (polls $A2 transitions; IRQ keeps it ticking)
delay_jiffies:
dj_next:
  lda $a2
dj_same:
  cmp $a2
  beq dj_same
  dex
  bne dj_next
  rts

build_dial_command:
  ldy #0
build_dial_prefix_loop:
  lda dial_prefix,y
  beq build_dial_endpoint
  sta dial_buffer,y
  iny
  jmp build_dial_prefix_loop
build_dial_endpoint:
  sty dial_index
  ldx #0
build_dial_endpoint_loop:
  cpx endpoint_len
  beq build_dial_done
  lda endpoint_buffer,x
  ldy dial_index
  sta dial_buffer,y
  inc dial_index
  inx
  jmp build_dial_endpoint_loop
build_dial_done:
  ldy dial_index
  lda #13
  sta dial_buffer,y
  iny
  lda #0
  sta dial_buffer,y
  rts

wait_for_result:
  sta wanted_result
  lda #0
  sta found_result
  sta match_ok
  sta match_connect
  sta match_valid
  sta timeout_hi
  sta timeout_mid
  ldx #$80
  stx timeout_lo

wait_loop:
  jsr sw_getxfer
  bcc wait_got_byte
  dec timeout_lo
  bne wait_loop
  dec timeout_mid
  bne wait_loop
  dec timeout_hi
  bne wait_loop
  clc
  rts

wait_got_byte:
  pha
  jsr print_char
  pla
  jsr update_matchers
  lda found_result
  cmp wanted_result
  beq wait_found
  lda found_result
  cmp #RESULT_ERROR
  beq wait_error
  jmp wait_loop

wait_found:
  sec
  rts

wait_error:
  clc
  rts

update_matchers:
  sta rx_char
  // Match OK token
  lda #<ok_token
  sta ptr
  lda #>ok_token
  sta ptr+1
  ldx match_ok
  lda #RESULT_OK
  sta mt_result_code
  jsr match_token_generic
  stx match_ok
  // Match CONNECT token
  lda #<connect_token
  sta ptr
  lda #>connect_token
  sta ptr+1
  ldx match_connect
  lda #RESULT_CONNECT
  sta mt_result_code
  jsr match_token_generic
  stx match_connect
  // Match VALID token
  lda #<valid_token
  sta ptr
  lda #>valid_token
  sta ptr+1
  ldx match_valid
  lda #RESULT_VALID
  sta mt_result_code
  jsr match_token_generic
  stx match_valid
  rts

// Generic token matcher using indirect addressing.
// Input: ptr = token string, X = current match index, mt_result_code = result value
// Output: X = updated match index (0 on match or mismatch reset)
match_token_generic:
  txa
  tay
  lda rx_char
  cmp (ptr),y
  bne mt_reset
  iny
  lda (ptr),y
  bne mt_no_match_yet
  // Token fully matched
  lda mt_result_code
  sta found_result
  ldx #0
  rts
mt_no_match_yet:
  tya
  tax
  rts
mt_reset:
  ldx #0
  rts
mt_result_code:
  .byte 0

update_disconnect_matcher:
  sta rx_char
  ldx match_no_carrier
  lda rx_char
  cmp no_carrier_token,x
  bne no_carrier_reset
  inx
  stx match_no_carrier
  lda no_carrier_token,x
  bne no_carrier_done
  lda #1
  sta disconnect_seen
  lda #0
  sta match_no_carrier
no_carrier_done:
  lda rx_char
  rts
no_carrier_reset:
  lda #0
  sta match_no_carrier
  lda rx_char
  rts
