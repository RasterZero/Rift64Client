// RIFT64 Protocol SwiftLink/Turbo232 client
//
// Memory layout:
//   $0400-$07FF  Screen RAM (VIC)
//   $0801-$37FF  Program code + data
//   $3800-$3FFF  Sprite data (32 blocks, VIC bank 3)
//   $4000-$CFFF  Server upload zone (bitmaps, fonts, music, metatiles)
//   $A000-$AFFF  Screen save buffers (BASIC ROM banked out)
//   $2B00-$2BFF  Serial RX ring buffer (allocated dynamically at the end of code)
//
// Load and run with: LOAD "RIFT64",8,1 then RUN
//
// Suggested VICE setup:
//   SwiftLink base: $DE00
//   SwiftLink baud: 38400
//   Default virtual modem endpoint: 192.168.0.188:8000
//
// Start the local TCP protocol server first.
//
// This program talks to the emulator's virtual modem through the SwiftLink
// driver, then renders incoming RIFT64 protocol commands from the server.

.pc = $0801 "Basic Upstart"
:BasicUpstart2(start)

.pc = $0810 "RIFT64 Main"

.const GETIN  = $ffe4

.const BAUD_38400 = 6
.const MODEM_TYPE_SWIFTLINK_DE = 2
.const MODEM_TYPE_SWIFTLINK_DF = 3

// --- Named Memory Map Configurations ---
.const CODE_LIMIT           = $4000  // Code + RX ring buffer must end <= $4000 (server upload zone starts here)
.const SFX_SCRIPT_BASE      = $c000  // Base address for SFX script slots in RAM
.const SFX_SLOT_SIZE        = 64     // 64 bytes per SFX slot
.const SFX_SLOT_COUNT       = 16     // 16 slots

.const RESULT_OK = 1
.const RESULT_CONNECT = 2
.const RESULT_VALID = 3
.const RESULT_ERROR = 255

.const ptr = $fb
.const ENDPOINT_MAX = 32

start:
  // Bank out BASIC ROM — frees $A000-$BFFF as RAM
  lda $01
  and #$fe              // clear bit 0 (BASIC ROM off)
  sta $01
  jsr audio_install
  // Pre-fill the endpoint field with the default address on cold boot only.
  // app_start is re-entered on every disconnect/reset and must NOT reload it,
  // so a user-edited endpoint persists across reconnects.
  jsr load_default_endpoint

app_start:
  lda #0
  sta disconnect_seen
  sta match_no_carrier
  sta dcd_monitor
  sta endpoint_accept_return
  sta endpoint_idle_lo
  sta endpoint_idle_hi
  jsr hardware_init
  // Centered title + version
  lda #8
  sta cursor_x
  lda #2
  sta cursor_y
  ldx #<title_msg
  ldy #>title_msg
  jsr print_string

  // Print Address 1 (Test Connection) on row 5, column 3
  lda #3
  sta cursor_x
  lda #5
  sta cursor_y
  ldx #<addr1_msg
  ldy #>addr1_msg
  jsr print_string

  // Print Address 2 (RiftWire IRC) on row 6, column 3
  lda #3
  sta cursor_x
  lda #6
  sta cursor_y
  ldx #<addr2_msg
  ldy #>addr2_msg
  jsr print_string

  // Left-justified example hint above the entry line
  lda #0
  sta cursor_x
  lda #10
  sta cursor_y
  ldx #<example_msg
  ldy #>example_msg
  jsr print_string
  jsr render_endpoint
  jsr drain_keyboard
  jsr endpoint_input_loop

connect_start:
  lda #MODEM_TYPE_SWIFTLINK_DE
  ldx #BAUD_38400
  jsr sw_setup
  jsr sw_enable
  jsr flush_rx_buffer
  jsr clear_screen

  ldx #<dial_prefix
  ldy #>dial_prefix
  jsr print_string
  lda #32
  jsr print_char
  jsr print_endpoint_buffer
  lda #13
  jsr print_char

  jsr modem_hangup_sequence

  ldx #<at_cmd
  ldy #>at_cmd
  jsr send_string
  lda #RESULT_OK
  jsr wait_for_result
  bcc at_failed

  jsr build_dial_command
  ldx #<dial_buffer
  ldy #>dial_buffer
  jsr send_string
  lda #RESULT_CONNECT
  jsr wait_for_result
  bcc connect_failed

  ldx #<client_ready
  ldy #>client_ready
  jsr send_string

  ldx #<connected_msg
  ldy #>connected_msg
  jsr print_string

  // Arm hardware carrier (DCD) monitoring so a dropped direct/TCPSER socket
  // is detected even if no "NO CARRIER" text is ever received.
  jsr sw_carrier_arm

  // Flush any residual local keypresses from endpoint entry/accept before
  // live protocol keyboard forwarding begins.
  jsr drain_keyboard

  jmp protocol_loop

at_failed:
  ldx #<at_fail_msg
  ldy #>at_fail_msg
  jsr print_string
  jmp wait_key_restart

connect_failed:
  ldx #<connect_fail_msg
  ldy #>connect_fail_msg
  jsr print_string
  jmp wait_key_restart

validation_failed:
  ldx #<validation_fail_msg
  ldy #>validation_fail_msg
  jsr print_string
  jmp wait_key_restart

wait_key_restart:
  ldx #<press_key_msg
  ldy #>press_key_msg
  jsr print_string
wait_key_restart_loop:
  jsr GETIN
  beq wait_key_restart_loop
  jmp app_start

protocol_loop:
  jsr poll_keyboard
  jsr telemetry_maybe_send
  jsr sw_carrier_lost
  bcs connection_lost
  jsr sw_getxfer
  bcc protocol_got_byte
  jmp protocol_loop

protocol_got_byte:
  jsr update_disconnect_matcher
  lda disconnect_seen
  bne connection_lost
  lda rx_char
  pha
  jsr hide_cursor
  pla
  jsr protocol_handle_byte
  jsr show_cursor
  jmp protocol_loop

connection_lost:
  jsr sw_disable
  jsr sw_enable
  jmp app_start

// Clean software reset, triggered by RUN/STOP + RESTORE from within the NMI
// handler. Tears down the live connection and returns to the endpoint/start
// screen. Deliberately re-enters at app_start (NOT start): start runs
// audio_install, which would re-chain the KERNAL IRQ vector onto itself.
software_reset:
  sei
  ldx #$ff
  txs                   // reset stack (we arrive mid-NMI)
  jsr sw_disable        // stop SwiftLink receive NMIs
  jsr soundbridge_reset // silence SID / halt any SFX
  lda $01
  and #$fe              // keep BASIC ROM banked out ($A000-$BFFF = RAM)
  sta $01
  cli
  jmp app_start

// Reset the machine to a clean, known state: VIC text mode, all sprites off,
// SID/audio silenced, screen cleared, and all free RAM above the program +
// RX ring buffer wiped. Safe to call from cold boot (falls through here via
// app_start) and from the software_reset path. Leaves the program, ZP, stack,
// screen, hooked IRQ/NMI vectors, the RX ring buffer, and I/O untouched.
hardware_init:
  jsr soundbridge_reset      // stop tracker, silence SID, stop SFX, volume 0
  jsr animator_reset         // stop any animator slots left running from a prior session
  sei                        // keep IRQ off through the register/RAM reset

  // Reset screen base and lookup table to standard $0400 defaults
  lda #$03
  sta video_bank_bits
  lda #$14
  sta video_d018_value
  jsr apply_screen_base      // Sets screen_base_hi to $04 and rebuilds screen_hi row table!

  // --- All sprites off ---
  lda #0
  sta $d015                  // sprite enable
  sta $d010                  // sprite X MSB
  sta $d017                  // sprite Y expand
  sta $d01b                  // sprite-background priority
  sta $d01c                  // sprite multicolor enable
  sta $d01d                  // sprite X expand
  // --- VIC-II text-mode defaults ---
  lda #$1b
  sta $d011                  // display on, 25 rows, bitmap/ECM off
  lda #$c8
  sta $d016                  // 40 columns, multicolor off
  lda #$14
  sta $d018                  // screen $0400, character ROM $1000
  lda $dd02
  ora #%00000011
  sta $dd02
  lda $dd00
  and #%11111100
  ora #%00000011             // VIC bank 0 ($0000-$3FFF)
  sta $dd00
  lda #$0e
  sta $d020                  // border: light blue
  lda #$06
  sta $d021                  // background: blue
  // --- Clear screen + color RAM ---
  jsr clear_screen
  // --- Wipe all free RAM from the server upload zone ($4000) through $CFFF ---
  lda #0
  sta ptr
  lda #$40
  sta ptr+1
hardware_init_clear_page:
  ldy #0
  lda #0
hardware_init_clear_byte:
  sta (ptr),y
  iny
  bne hardware_init_clear_byte
  inc ptr+1
  lda ptr+1
  cmp #$d0                   // stop before $D000 I/O
  bne hardware_init_clear_page
  cli
  rts

done:
  jmp sw_disable

// Screen save buffers — located in RAM at $A000 (freed BASIC ROM area).
// Declared before module imports so forward references from imported
// files (e.g. protocol.asm save/restore handlers) resolve in pass 1.
.const screen_buffer_0 = $a000
.const color_buffer_0  = $a000 + 1000
.const screen_buffer_1 = $a000 + 2000
.const color_buffer_1  = $a000 + 3000

.import source "ui_input.asm"

.import source "modem.asm"

.import source "screen.asm"

.import source "protocol.asm"

wanted_result:
  .byte 0
found_result:
  .byte 0
rx_char:
  .byte 0
match_ok:
  .byte 0
match_connect:
  .byte 0
match_valid:
  .byte 0
match_no_carrier:
  .byte 0
disconnect_seen:
  .byte 0
timeout_lo:
  .byte 0
timeout_mid:
  .byte 0
timeout_hi:
  .byte 0
cursor_x:
  .byte 0
cursor_y:
  .byte 0
cursor_visible:
  .byte 0
cursor_enabled:
  .byte 1
cursor_saved_char:
  .byte 0
cursor_saved_color:
  .byte 0
text_color:
  .byte 1
hex_temp:
  .byte 0
window_width:
  .byte 0
window_height:
  .byte 0
window_start_x:
  .byte 0
window_row:
  .byte 0
window_col:
  .byte 0
border_width:
  .byte 0
border_height:
  .byte 0
border_start_x:
  .byte 0
border_start_y:
  .byte 0
border_row:
  .byte 0
border_col:
  .byte 0
erase_count:
  .byte 0
erase_start_x:
  .byte 0
erase_start_y:
  .byte 0
SpriteEnabled:
  .byte 0
scroll_x:
  .byte 0
scroll_y:
  .byte 0
scroll_width:
  .byte 0
scroll_height:
  .byte 0
scroll_dir:
  .byte 0
scroll_row:
  .byte 0
scroll_col:
  .byte 0
src_x:
  .byte 0
src_y:
  .byte 0
dest_x:
  .byte 0
dest_y:
  .byte 0
scroll_char:
  .byte 0
scroll_color:
  .byte 0
transfer_remaining:
  .byte 0
transfer_total:
  .byte 0
checksum_calc:
  .byte 0
frame_command:
  .byte 0
frame_length:
  .byte 0
buffer_index:
  .byte 0
block_x:
  .byte 0
block_y:
  .byte 0
block_width:
  .byte 0
block_height:
  .byte 0
block_row:
  .byte 0
block_col:
  .byte 0
block_color:
  .byte 0
video_bank_bits:
  .byte 0
video_d018_value:
  .byte 0
video_mode_value:
  .byte 0
// Hi byte of the active screen-matrix base. Single source of truth for where
// the CPU draws text/colour. Derived from video_bank_bits + video_d018_value by
// apply_screen_base whenever the 'F'/'I' commands change the VIC bank/slot.
// Default $04 = $0400 (boot default; matches the screen_hi table defaults).
screen_base_hi:
  .byte $04
string_index:
  .byte 0
dial_index:
  .byte 0
endpoint_len:
  .byte 0
endpoint_accept_return:
  .byte 0
endpoint_idle_lo:
  .byte 0
endpoint_idle_hi:
  .byte 0
endpoint_buffer:
  .fill ENDPOINT_MAX, 0
dial_buffer:
  .fill ENDPOINT_MAX+8, 0

title_msg:
  // "RIFT64 CLIENT V1.2 BETA"
  .byte 82,73,70,84,54,52,32,67,76,73,69,78,84,32,86,49,46,50,32,66,69,84,65,0
addr1_msg:
  // "RIFT64.COM:64001 - TEST CONNECTION"
  .byte 82,73,70,84,54,52,46,67,79,77,58,54,52,48,48,49,32,45,32,84,69,83,84,32,67,79,78,78,69,67,84,73,79,78,0
addr2_msg:
  // "RIFT64.COM:64002 - RIFTWIRE IRC"
  .byte 82,73,70,84,54,52,46,67,79,77,58,54,52,48,48,50,32,45,32,82,73,70,84,87,73,82,69,32,73,82,67,0
example_msg:
  // "ENTER REMOTE ADDRESS:"
  .byte 69,78,84,69,82,32,82,69,77,79,84,69,32,65,68,68,82,69,83,83,58,0
endpoint_label:
  .byte 62,32,0
connected_msg:
  // "\rCONNECT\r"
  .byte 13,67,79,78,78,69,67,84,13,0
at_fail_msg:
  // "\rERROR\r"
  .byte 13,69,82,82,79,82,13,0
connect_fail_msg:
  // "\rNO CARRIER\r"
  .byte 13,78,79,32,67,65,82,82,73,69,82,13,0
validation_fail_msg:
  // "\rNO VALIDATION\r"
  .byte 13,70,65,73,76,58,32,78,79,32,86,65,76,73,68,65,84,73,79,78,13,0
press_key_msg:
  // "\rPRESS KEY TO RESTART.\r"
  .byte 13,80,82,69,83,83,32,75,69,89,32,84,79,32,82,69,83,84,65,82,84,46,13,0

at_cmd:
  .byte 65,84,13,0
hangup_cmd:
  // "\rATH0\r" — leading CR clears any stray "+++" from the modem's
  // command buffer when it was already in command mode
  .byte 13,65,84,72,48,13,0
dial_prefix:
  .byte 65,84,68,84,0
default_endpoint:
  // "rift64.com:64001"
  .byte 114,105,102,116,54,52,46,99,111,109,58,54,52,48,48,49,0
client_ready:
  .byte 82,69,65,68,89,13,0

ok_token:
  .byte 79,75,0
connect_token:
  .byte 67,79,78,78,69,67,84,0
valid_token:
  .byte 83,87,73,70,84,76,73,78,75,32,86,65,76,73,68,65,84,73,79,78,32,79,75,0
no_carrier_token:
  .byte 78,79,32,67,65,82,82,73,69,82,0
capability_msg:
  .byte 82,73,70,84,54,52,32,67,75,80,76,81,88,90,126,70,73,68,89,64,85,71,72,78,65,32,65,67,75,13,0

.import source "rs232_swfitlink.asm"
.import source "memory_store.asm"
.import source "sprite_tool.asm"
.import source "audio.asm"
.import source "animator.asm"
.import source "telemetry_tool.asm"

// ============================================================================
// MEMORY CONSTRAINT WARNING:
// The 256-byte SwiftLink receive ring buffer (ribuf) is dynamically allocated
// here right after the compiled code.
// 1) It MUST be page-aligned (.align $100) because the ACIA driver relies on
//    natural 8-bit index wrapping (sta ribuf,x).
// 2) The combined size of all code + ribuf MUST fit below CODE_LIMIT so it
//    does not run into the server upload zone ($4000-$CFFF). Examples upload
//    screen RAM to $4000, so the program image + ribuf must end at or before
//    $4000 or the upload corrupts running firmware.
// ============================================================================
.print "RIFT64 code end (pre-ribuf) = $" + toHexString(*) + "  (target: <= $3F00 to stay under the $4000 upload zone)"
.if (* > (CODE_LIMIT - $100)) {
  .error "Program size exceeded code limit; ribuf would overlap the $4000 server upload zone"
}
.align $100
ribuf: .fill 256, 0
// First page-aligned byte above the program image + RX ring buffer. Marks the
// start of the free-RAM region wiped by hardware_init (through $CFFF).
ram_clear_start:
