// audio.asm -- MiniPlayer2 integration wrapper for the RIFT64 client.
//
// Wraps player.asm (MiniPlayer2 by Cadaver, ported to KickAssembler).
// Provides:
//   - audio_install:  call once at boot. Silences SID and hooks the
//                     KERNAL IRQ vector ($0314) so PlayRoutine is called
//                     once per jiffy (~50 Hz PAL / 60 Hz NTSC).
//   - protocol_audio: RIFT64 protocol 'A' command dispatcher. Maps the
//                     subcommands 0..7 onto the MiniPlayer2 API.
//
// Memory:
//   ZP $20..$36  -- MiniPlayer2 state (PLAYER_ZPBASE = $20, 23 bytes)
//   $0314/$0315  -- hooked by audio_install, old vector chained
//
// Protocol subcommands (mapped from the old audio.asm API):
//   A0 stop      -> PlayRoutine+1 = $ff, silence SID
//   A1 start     -> read 2 hex chars (subtune index, 1-based);
//                   PlayRoutine+1 = subtune
//   A2 pause     -> PlayRoutine+1 = $ff (MiniPlayer2 has no true pause)
//   A3 resume    -> PlayRoutine+1 = $00 (resumes whatever was last init'd)
//   A4 tempo     -> ack-and-ignore (tempo is baked into module data)
//   A5 module    -> read 4 hex chars (page-aligned module address);
//                   silence, jsr SetMusicData
//   A6 volume    -> read 2 hex chars (0..15); write low nibble to $d418
//   A7 state     -> emit 1 byte: current PlayRoutine+1 value

// =================================================================
// Player configuration constants (consumed by player.asm)
// =================================================================
.import source "player.asm"
.import source "soundbridge.asm"

// =================================================================
// audio_install
// Silence SID, set player to silenced state, hook KERNAL IRQ vector.
// Call once at boot, before raster_split or anything else that wraps
// the $0314 vector.
// =================================================================
audio_install:
  sei
  // Initialize SoundBridge (zeroes SID registers, clears shadow registers, stops SFX, zeroes ownership)
  jsr soundbridge_reset

  // Put player in silenced state (no module loaded yet)
  lda #$ff
  sta PlayRoutine+1

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
// Performs mode-based dispatch to player and soundbridge SFX tasks.
// =================================================================
audio_irq:
  lda audio_mode
  cmp #$00                    // AM00: PLAYER_ONLY
  beq _call_player_only
  cmp #$01                    // AM01: SOUNDBRIDGE_ONLY
  beq _call_sfx_only
  cmp #$02                    // AM02: MIXED_PLAYER_PLUS_SFX
  beq _call_mixed
  jmp _continue_chain         // AM03: DIRECT_SID_MANUAL (no background updates)

_call_player_only:
  jsr PlayRoutine
  jmp _continue_chain

_call_sfx_only:
  jsr sfx_update
  jsr soundbridge_effects_update
  jmp _continue_chain

_call_mixed:
  jsr PlayRoutine
  jsr sfx_update
  jsr soundbridge_effects_update

_continue_chain:
  jmp (audio_old_irq)

audio_old_irq:
  .word 0

// =================================================================
// Protocol entry: command 'A' (0x41)
// Dispatches player controls ('0'..'9') or SoundBridge ('A'..'Z').
// =================================================================
protocol_audio:
  jsr protocol_read_byte
  and #$7f                  // Strip parity
  
  cmp #'0'
  bcc audio_invalid
  
  cmp #'9'+1
  bcc audio_player_dispatch
  
  cmp #'A'
  bcc audio_invalid
  
  cmp #'Z'+1
  bcc audio_soundbridge_dispatch

audio_invalid:
  jmp protocol_nak

audio_player_dispatch:
  cmp #'0'
  bne !+
  jmp audio_cmd_stop
!:
  cmp #'1'
  bne !+
  jmp audio_cmd_start
!:
  cmp #'2'
  bne !+
  jmp audio_cmd_pause
!:
  cmp #'3'
  bne !+
  jmp audio_cmd_resume
!:
  cmp #'4'
  bne !+
  jmp audio_cmd_tempo
!:
  cmp #'5'
  bne !+
  jmp audio_cmd_module
!:
  cmp #'6'
  bne !+
  jmp audio_cmd_volume
!:
  cmp #'7'
  bne !+
  jmp audio_cmd_state
!:
  // '8' and '9' are unimplemented player subcommands
  jmp protocol_nak

audio_soundbridge_dispatch:
  cmp #'R'
  bne !+
  jmp sbridge_cmd_reset
!:
  cmp #'B'
  bne !+
  jmp sbridge_cmd_sfx_base
!:
  cmp #'V'
  bne !+
  jmp sbridge_cmd_volume
!:
  cmp #'M'
  bne !+
  jmp sbridge_cmd_mode
!:
  cmp #'I'
  bne !+
  jmp sbridge_cmd_instrument
!:
  cmp #'N'
  bne !+
  jmp sbridge_cmd_note_on
!:
  cmp #'O'
  bne !+
  jmp sbridge_cmd_note_off
!:
  cmp #'F'
  bne !+
  jmp sbridge_cmd_full_voice
!:
  cmp #'Q'
  bne !+
  jmp sbridge_cmd_freq
!:
  cmp #'D'
  bne !+
  jmp sbridge_cmd_adsr
!:
  cmp #'E'
  bne !+
  jmp sbridge_cmd_set_effect
!:
  cmp #'W'
  bne !+
  jmp sbridge_cmd_control
!:
  cmp #'P'
  bne !+
  jmp sbridge_cmd_pulse
!:
  cmp #'S'
  bne !+
  jmp sbridge_cmd_sfx_play
!:
  cmp #'X'
  bne !+
  jmp sbridge_cmd_sfx_stop
!:
  cmp #'Z'
  bne !+
  jmp sbridge_cmd_stop_all
!:
  jmp protocol_nak

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
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
  jsr protocol_read_hex_byte
  sta temp_args+3
  jsr protocol_read_hex_byte
  sta temp_args+4
  jsr protocol_read_hex_byte
  sta temp_args+5
  jsr soundbridge_define_instrument
  bcs !+
  jmp protocol_ack
!:
  jmp protocol_nak

sbridge_cmd_note_on:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
  jsr protocol_read_hex_byte
  sta temp_args+3
  jsr soundbridge_note_on
  rts                         // No-ACK

sbridge_cmd_note_off:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr soundbridge_note_off
  rts                         // No-ACK

sbridge_cmd_full_voice:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
  jsr protocol_read_hex_byte
  sta temp_args+3
  jsr protocol_read_hex_byte
  sta temp_args+4
  jsr protocol_read_hex_byte
  sta temp_args+5
  jsr protocol_read_hex_byte
  sta temp_args+6
  jsr protocol_read_hex_byte
  sta temp_args+7
  jsr soundbridge_full_voice_setup
  rts                         // No-ACK

sbridge_cmd_freq:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
  jsr soundbridge_set_frequency
  rts                         // No-ACK

sbridge_cmd_adsr:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
  jsr soundbridge_set_adsr
  rts                         // No-ACK

sbridge_cmd_set_effect:
  jsr protocol_read_hex_byte
  sta temp_args+0               // Voice (0..2)
  jsr protocol_read_hex_byte
  sta temp_args+1               // Effect Type (0..3)
  jsr protocol_read_hex_byte
  sta temp_args+2               // Speed
  jsr protocol_read_hex_byte
  sta temp_args+3               // Depth
  jsr soundbridge_set_effect
  rts                           // No-ACK

sbridge_cmd_control:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr soundbridge_set_control
  rts                         // No-ACK

sbridge_cmd_pulse:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
  jsr soundbridge_set_pulse_width
  rts                         // No-ACK

sbridge_cmd_sfx_play:
  jsr protocol_read_hex_byte
  sta temp_args+0
  jsr protocol_read_hex_byte
  sta temp_args+1
  jsr protocol_read_hex_byte
  sta temp_args+2
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
audio_cmd_stop:
  sei
  lda #$ff
  sta PlayRoutine+1
  cli
  jsr Play_SilenceSID
  jmp protocol_ack

// --- A1 start (subtune) ------------------------------------------
// Param: 1 hex byte = subtune index (1..127). 0 not allowed.
// NAK if no module has been loaded yet (PlayRoutine would read garbage).
audio_cmd_start:
  jsr protocol_read_hex_byte
  cmp #1
  bcc audio_cmd_start_nak
  cmp #$80
  bcs audio_cmd_start_nak
  ldx audio_mod_loaded
  beq audio_cmd_start_nak
  sei
  sta PlayRoutine+1
  cli
  jmp protocol_ack
audio_cmd_start_nak:
  jmp protocol_nak

// --- A2 pause ----------------------------------------------------
// MiniPlayer2 has no true pause -- silence the player and rely on
// A3 resume to restart. Position is lost.
audio_cmd_pause:
  sei
  lda #$ff
  sta PlayRoutine+1
  cli
  jsr Play_SilenceSID
  jmp protocol_ack

// --- A3 resume ---------------------------------------------------
// Sets command byte = $00 (playback ongoing). Only meaningful if a
// subtune was previously init'd via A1.
audio_cmd_resume:
  sei
  lda #$00
  sta PlayRoutine+1
  cli
  jmp protocol_ack

// --- A4 tempo (ack-and-ignore) -----------------------------------
// MiniPlayer2 has no external tempo control; tempo is baked into
// the module data. Accept and discard for backwards compatibility.
audio_cmd_tempo:
  jsr protocol_read_hex_byte
  jmp protocol_ack

// --- A5 set module address ---------------------------------------
// Param: 2 hex bytes (low, high) = page-aligned module base address.
// SetMusicData requires PlayRoutine to be silenced first.
audio_cmd_module:
  jsr protocol_read_hex_byte
  sta audio_mod_lo
  jsr protocol_read_hex_byte
  sta audio_mod_hi
  // Reject if low byte != 0 (must be page-aligned)
  lda audio_mod_lo
  bne audio_cmd_module_nak
  sei
  lda #$ff
  sta PlayRoutine+1
  jsr Play_SilenceSID
  lda audio_mod_lo
  ldx audio_mod_hi
  jsr SetMusicData
  lda #1
  sta audio_mod_loaded
  cli
  jmp protocol_ack
audio_cmd_module_nak:
  jmp protocol_nak

audio_mod_lo:     .byte 0
audio_mod_hi:     .byte 0
audio_mod_loaded: .byte 0

// --- A6 set volume -----------------------------------------------
// Param: 1 hex byte (low nibble = volume 0..15). High nibble of
// $d418 controls filter routing -- preserve it.
audio_cmd_volume:
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
// Emits 1 byte: current PlayRoutine+1 (the command/state byte).
//   $00       playback ongoing
//   $01..$7f  init pending (subtune index) -- rarely observed
//   $80..$ff  silenced
audio_cmd_state:
  lda PlayRoutine+1
  jsr sw_putxfer
  rts
