// audio.asm -- AudioBridge wrapper for the RIFT64 client.
//
// Front-end for soundbridge.asm (synth + SFX bytecode) and tracker.asm
// (pattern sequencer). Provides:
//   - audio_install:  call once at boot. Silences SID and hooks the
//                     KERNAL IRQ vector ($0314) so the audio engines tick
//                     once per jiffy (~50 Hz PAL / 60 Hz NTSC).
//   - protocol_audio: RIFT64 protocol 'A' command dispatcher. Digits
//                     0..7 are tracker transport; letters dispatch to
//                     SoundBridge and the remote-tracker stream.
//
// Memory:
//   $0314/$0315  -- hooked by audio_install, old vector chained
//
// Tracker transport subcommands (digits, wire-compatible with the old
// MiniPlayer2 commands):
//   A0 stop      -> tracker stop + release all voices
//   A1 play      -> read 2 hex chars (start order index, 0-based)
//   A2 pause     -> tracker pause (position kept, voices keep sustaining)
//   A3 resume    -> tracker resume from paused position
//   A4 speed     -> read 2 hex chars (frames per row, 1..31)
//   A5 bind      -> read 4 hex chars (song base address lo,hi; >= $4000)
//   A6 volume    -> read 2 hex chars (0..15); write low nibble to $d418
//   A7 state     -> emit 1 byte: tracker state
//
// Remote tracker / streaming subcommands (letters):
//   AT mode      -> 01 enter remote (streamed-row) mode, 00 exit
//   AU rows      -> count n, then n*6 row bytes appended to the ring
//   AY status    -> emit 5 bytes: state, order, row, buffered, under/over
//   AJ jump      -> jump to order index at next row boundary
//   AC insfx     -> per-instrument auto-effect: inst, type, speed, depth
//   AG filter    -> SID filter: cutoff lo/hi, resonance+routing, mode
//   AK note      -> note on by note-table index: voice, index, instrument

.import source "soundbridge.asm"
.import source "tracker.asm"

// =================================================================
// audio_install
// Silence SID, retune the jiffy IRQ to true frame rate, and hook the
// KERNAL IRQ vector. Call once at boot, before raster_split or
// anything else that wraps the $0314 vector.
// =================================================================
audio_install:
  sei
  // Initialize SoundBridge (zeroes SID registers, clears shadow registers, stops SFX, zeroes ownership)
  jsr soundbridge_reset

  // The KERNAL programs CIA1 Timer A for ~60 Hz on BOTH video standards
  // (the jiffy drives TI$, defined in 1/60 s) -- so on PAL the audio tick
  // would run 20% fast against the documented 50 frames/sec. Retune the
  // timer to one PAL frame when the KERNAL's standard flag says PAL;
  // NTSC keeps 60 Hz (its native frame rate). Period = latch + 1 cycles.
  lda $02a6                   // 0 = NTSC, 1 = PAL
  beq _install_keep_60hz
  lda #<19704                 // 985248 / 50 = 19705 cycles per tick
  sta $dc04
  lda #>19704
  sta $dc05
  lda #%00010001              // force-load latch + start Timer A, continuous
  sta $dc0e
_install_keep_60hz:

  // Hook KERNAL IRQ vector
  lda $0314
  sta audio_old_irq+0
  lda $0315
  sta audio_old_irq+1
  lda #<audio_irq
  sta $0314
  lda #>audio_irq
  sta $0315
  cli
  rts

// =================================================================
// audio_irq
// Hooked into $0314. KERNAL has already pushed A/X/Y.
// Ticks the tracker, SFX scripts and note effects unless the host has
// taken the SID for itself (DIRECT mode).
// =================================================================
audio_irq:
  lda audio_mode
  cmp #3                      // DIRECT_SID_MANUAL: no background updates
  beq _continue_chain
  jsr tracker_update
  jsr sfx_update
  jsr soundbridge_effects_update

_continue_chain:
  jmp (audio_old_irq)

audio_old_irq:
  .word 0

// =================================================================
// Protocol entry: command 'A' (0x41)
// Table-driven dispatch (same scheme as protocol.asm): the subcommand
// byte is matched against audio_cmd_tbl and the paired handler address
// is jumped to through an RTS trampoline.
// =================================================================
.const AUDIO_CMD_COUNT = 31

protocol_audio:
  jsr protocol_read_byte
  and #$7f                  // Strip parity
  ldx #0
_pa_loop:
  cmp audio_cmd_tbl,x
  beq _pa_found
  inx
  cpx #AUDIO_CMD_COUNT
  bne _pa_loop
  jmp protocol_nak          // Unknown subcommand
_pa_found:
  lda audio_hnd_hi,x
  pha
  lda audio_hnd_lo,x
  pha
  rts

audio_cmd_tbl:
  .byte '0','1','2','3','4','5','6','7'                          // tracker transport
  .byte 'T','U','Y','J','C'                                      // remote tracker / status
  .byte 'R','B','V','M','I','G'                                  // engine control
  .byte 'N','K','O','F','Q','D','E','W','P'                      // real-time stream
  .byte 'S','X','Z'                                              // SFX

audio_hnd_lo:
  .byte <(trk_cmd_stop-1),       <(trk_cmd_play-1),        <(trk_cmd_pause-1),    <(trk_cmd_resume-1)
  .byte <(trk_cmd_speed-1),      <(trk_cmd_bind-1),        <(trk_cmd_volume-1),   <(trk_cmd_state-1)
  .byte <(trk_cmd_remote-1),     <(trk_cmd_stream-1),      <(trk_cmd_status-1),   <(trk_cmd_jump-1)
  .byte <(trk_cmd_inst_effect-1)
  .byte <(sbridge_cmd_reset-1),  <(sbridge_cmd_sfx_base-1),<(sbridge_cmd_volume-1),<(sbridge_cmd_mode-1)
  .byte <(sbridge_cmd_instrument-1), <(sbridge_cmd_filter-1)
  .byte <(sbridge_cmd_note_on-1),<(sbridge_cmd_note_idx-1),<(sbridge_cmd_note_off-1),<(sbridge_cmd_full_voice-1)
  .byte <(sbridge_cmd_freq-1),   <(sbridge_cmd_adsr-1),    <(sbridge_cmd_set_effect-1),<(sbridge_cmd_control-1)
  .byte <(sbridge_cmd_pulse-1)
  .byte <(sbridge_cmd_sfx_play-1),<(sbridge_cmd_sfx_stop-1),<(sbridge_cmd_stop_all-1)

audio_hnd_hi:
  .byte >(trk_cmd_stop-1),       >(trk_cmd_play-1),        >(trk_cmd_pause-1),    >(trk_cmd_resume-1)
  .byte >(trk_cmd_speed-1),      >(trk_cmd_bind-1),        >(trk_cmd_volume-1),   >(trk_cmd_state-1)
  .byte >(trk_cmd_remote-1),     >(trk_cmd_stream-1),      >(trk_cmd_status-1),   >(trk_cmd_jump-1)
  .byte >(trk_cmd_inst_effect-1)
  .byte >(sbridge_cmd_reset-1),  >(sbridge_cmd_sfx_base-1),>(sbridge_cmd_volume-1),>(sbridge_cmd_mode-1)
  .byte >(sbridge_cmd_instrument-1), >(sbridge_cmd_filter-1)
  .byte >(sbridge_cmd_note_on-1),>(sbridge_cmd_note_idx-1),>(sbridge_cmd_note_off-1),>(sbridge_cmd_full_voice-1)
  .byte >(sbridge_cmd_freq-1),   >(sbridge_cmd_adsr-1),    >(sbridge_cmd_set_effect-1),>(sbridge_cmd_control-1)
  .byte >(sbridge_cmd_pulse-1)
  .byte >(sbridge_cmd_sfx_play-1),>(sbridge_cmd_sfx_stop-1),>(sbridge_cmd_stop_all-1)

// --- SoundBridge Wrappers (Parsers & Dispatchers) ---
sbridge_cmd_reset:
  jsr soundbridge_reset
  jmp protocol_ack

sbridge_cmd_sfx_base:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr soundbridge_set_sfx_base
  jmp protocol_ack

sbridge_cmd_volume:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr soundbridge_set_volume
  jmp protocol_ack

sbridge_cmd_mode:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr soundbridge_set_mode
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

sbridge_cmd_instrument:
  lda #6
  jsr read_hex_args
  jsr soundbridge_define_instrument
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// AG: cutoff lo (0-7), cutoff hi, resonance+routing, filter mode bits
sbridge_cmd_filter:
  lda #4
  jsr read_hex_args
  jsr soundbridge_set_filter
  jmp protocol_ack

sbridge_cmd_note_on:
  lda #4
  jsr read_hex_args
  jsr soundbridge_note_on
  rts                         // No-ACK

// AK: voice, note index (1..95, C-0..B-7), instrument id (1..16)
sbridge_cmd_note_idx:
  lda #3
  jsr read_hex_args
  jsr soundbridge_note_on_by_index
  rts                         // No-ACK

sbridge_cmd_note_off:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr soundbridge_note_off
  rts                         // No-ACK

sbridge_cmd_full_voice:
  lda #8
  jsr read_hex_args
  jsr soundbridge_full_voice_setup
  rts                         // No-ACK

sbridge_cmd_freq:
  lda #3
  jsr read_hex_args
  jsr soundbridge_set_frequency
  rts                         // No-ACK

sbridge_cmd_adsr:
  lda #3
  jsr read_hex_args
  jsr soundbridge_set_adsr
  rts                         // No-ACK

sbridge_cmd_set_effect:
  lda #4
  jsr read_hex_args
  jsr soundbridge_set_effect
  rts                           // No-ACK

sbridge_cmd_control:
  lda #2
  jsr read_hex_args
  jsr soundbridge_set_control
  rts                         // No-ACK

sbridge_cmd_pulse:
  lda #3
  jsr read_hex_args
  jsr soundbridge_set_pulse_width
  rts                         // No-ACK

sbridge_cmd_sfx_play:
  lda #3
  jsr read_hex_args
  jsr soundbridge_sfx_play
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

sbridge_cmd_sfx_stop:
  jsr soundbridge_sfx_stop
  jmp protocol_ack

sbridge_cmd_stop_all:
  jsr soundbridge_sound_stop_all
  jmp protocol_ack

// --- A0 stop -----------------------------------------------------
trk_cmd_stop:
  jsr tracker_stop
  jmp protocol_ack

// --- A1 play (start order) ---------------------------------------
// Param: 1 hex byte = orderlist start index (0-based).
// NAK if no song is bound or the index is past the orderlist end.
trk_cmd_play:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr tracker_play
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// --- A2 pause ----------------------------------------------------
// Position is kept; sustaining voices keep ringing.
trk_cmd_pause:
  jsr tracker_pause
  jmp protocol_ack

// --- A3 resume ---------------------------------------------------
trk_cmd_resume:
  jsr tracker_resume
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// --- A4 speed ----------------------------------------------------
// Param: 1 hex byte = frames per row (1..31).
trk_cmd_speed:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr tracker_set_speed
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// --- A5 bind song ------------------------------------------------
// Param: 2 hex bytes (low, high) = song base address. Must point into
// the server upload zone (high byte >= $40). Stops playback and caches
// the song header.
trk_cmd_bind:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr tracker_bind
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// --- A6 set volume -----------------------------------------------
// Param: 1 hex byte (low nibble = volume 0..15). High nibble of
// $d418 controls filter routing -- preserve it.
trk_cmd_volume:
  jsr protocol_read_hex_byte
  and #$0f
  sta audio_vol_tmp
  lda $d418
  and #$f0
  ora audio_vol_tmp
  sta $d418
  jmp protocol_ack

audio_vol_tmp: .byte 0

// --- A7 query state ----------------------------------------------
// Emits 1 byte: 0 stopped, 1 playing (local), 2 paused, 3 remote.
trk_cmd_state:
  jsr tracker_query_state
  jsr sw_putxfer
  rts

// --- AT remote mode ----------------------------------------------
// Param: 1 hex byte: 01 = enter remote (streamed-row) mode, 00 = exit.
trk_cmd_remote:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr tracker_remote_mode
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// --- AU stream rows (no ACK) -------------------------------------
// Params: 1 hex byte frame count n (1..8), then n frames of 6 hex
// bytes each (one tracker row: note,inst for 3 voices). Frames that
// do not fit in the ring are dropped and counted as overruns.
trk_cmd_stream:
  jsr protocol_read_hex_byte
  sta trk_stream_n
  beq trk_stream_done
trk_stream_frame:
  lda #6
  jsr read_hex_args
  jsr tracker_ring_push
  dec trk_stream_n
  bne trk_stream_frame
trk_stream_done:
  rts                         // Fire-and-forget, like N/O/F/Q

trk_stream_n: .byte 0

// --- AY status (5 raw bytes) -------------------------------------
// state, order, row, buffered frame count, (overruns<<4)|underruns.
trk_cmd_status:
  jsr tracker_query_state
  jsr sw_putxfer
  lda trk_order
  jsr sw_putxfer
  lda trk_row
  jsr sw_putxfer
  lda trk_ring_count
  jsr sw_putxfer
  lda trk_overruns
  asl
  asl
  asl
  asl
  ora trk_underruns
  jsr sw_putxfer
  rts

// --- AJ jump to order --------------------------------------------
// Param: 1 hex byte = orderlist index. Takes effect at the next row
// boundary. Only meaningful during local playback.
trk_cmd_jump:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr tracker_jump
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

// --- AC per-instrument auto-effect -------------------------------
// Params: 4 hex bytes: instrument id (1..16), effect type (0..4),
// speed, depth. Applied by the tracker on every note-on with that
// instrument; type 0 clears.
trk_cmd_inst_effect:
  lda #4
  jsr read_hex_args
  jsr tracker_set_inst_effect
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak
