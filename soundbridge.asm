// ============================================================================
// soundbridge.asm -- SoundBridge Sound Engine, Synthesizer & SFX Interpreter
// ============================================================================

// --- SoundBridge Variables ---
audio_mode:         .byte 0           // 00=Player, 01=SoundBridge, 02=Mixed, 03=Direct
voice_owner:        .byte 0, 0, 0     // 0=None, 1=Player, 2=Note, 3=SFX, 4=Direct
voice_priority:     .byte 0, 0, 0     // Priorities for voice stealing / play rules
voice_last_ctrl:    .byte 0, 0, 0     // Unused in MVP, reserved for state tracking

// SID shadow registers ($D400-$D418)
sid_shadow:         .fill 25, 0

// Instrument table (16 instruments * 5 bytes = 80 bytes)
// Records layout: [PL, PH, AD, SR, CT]
instrument_table:   .fill 80, 0

// SFX interpreter state
.const sfx_ptr_lo = $fd
.const sfx_ptr_hi = $fe

// Default base page of the 16 SFX bytecode script slots (64 bytes each).
// The actual base is held in the runtime variable sfx_base_hi and can be
// relocated by the host via the AB (Set SFX Base) command. Page-aligned
// (low byte always $00); only the high byte is tracked.
.const SFX_SCRIPT_BASE_DEFAULT = $c0

sfx_base_hi:        .byte SFX_SCRIPT_BASE_DEFAULT

sfx_active:         .byte 0
sfx_id:             .byte 0
sfx_priority:       .byte 0
sfx_wait:           .byte 0
sfx_voice:          .byte 2           // SFX locked to Voice index 2 (offset 14)

// Global argument buffer for parsing
temp_args:          .fill 8, 0

// Per-voice modulation state (3 voices)
effect_type:     .byte 0, 0, 0     // 00=Off, 01=Vibrato, 02=Slide, 03=PWM, 04=Arpeggio
effect_speed:    .byte 0, 0, 0     // Rate of modulation
effect_depth:    .byte 0, 0, 0     // Scale of modulation offset
effect_phase:    .byte 0, 0, 0     // Tracks position in vibrato table / arp hold countdown
arp_step:        .byte 0, 0, 0     // Arpeggio tone index (0=root, 1=third, 2=fifth)

// Slide (portamento) target: next-note pitch the voice should glide toward.
// Set by NoteOn while Slide is active; reached when base_freq matches.
slide_target_lo: .byte 0, 0, 0
slide_target_hi: .byte 0, 0, 0

// Reference pitch anchors
base_freq_lo:    .byte 0, 0, 0     // Captured during NoteOn (AN), SetFreq (AQ), or FullVoice (AF)
base_freq_hi:    .byte 0, 0, 0     // Captured during NoteOn (AN), SetFreq (AQ), or FullVoice (AF)

// Reference pulse width anchors
base_pw_lo:      .byte 0, 0, 0     // Captured during NoteOn (AN), FullVoice (AF), or SetPulse (AP)
base_pw_hi:      .byte 0, 0, 0     // Captured during NoteOn (AN), FullVoice (AF), or SetPulse (AP)

// --- Lookup Tables ---
voice_offsets:
  .byte 0, 7, 14

vibrato_table:
  .byte 0, 1, 2, 3, 4, 3, 2, 1, 0, $ff, $fe, $fd, $fc, $fd, $fe, $ff
  // (where $FF = -1, $FE = -2, $FD = -3, and $FC = -4)

sfx_slot_lo:
  .byte $00, $40, $80, $c0, $00, $40, $80, $c0, $00, $40, $80, $c0, $00, $40, $80, $c0
sfx_slot_hi:
  .byte $00, $00, $00, $00, $01, $01, $01, $01, $02, $02, $02, $02, $03, $03, $03, $03

// ============================================================================
// Public Routines
// ============================================================================

// --- soundbridge_reset (AR) ---
// Silences all SID registers, clears shadow registers, stops SFX, zeroes ownership.
soundbridge_reset:
  sei
  lda #0
  sta sfx_active
  sta sfx_wait
  sta sfx_priority
  sta voice_owner+0
  sta voice_owner+1
  sta voice_owner+2
  sta voice_priority+0
  sta voice_priority+1
  sta voice_priority+2
  
  ldx #24
_clear_loop:
  sta $d400,x
  sta sid_shadow,x
  dex
  bpl _clear_loop

  // Clear local note effects state
  ldx #2
  lda #0
!:
  sta effect_type,x
  sta effect_speed,x
  sta effect_depth,x
  sta effect_phase,x
  sta arp_step,x
  sta base_freq_lo,x
  sta base_freq_hi,x
  sta base_pw_lo,x
  sta base_pw_hi,x
  sta slide_target_lo,x
  sta slide_target_hi,x
  dex
  bpl !-

  cli
  rts

// --- soundbridge_set_volume (AV) ---
// Sets global master volume (low nibble of $D418) while preserving filters.
soundbridge_set_volume:
  lda temp_args+0
  and #$0f
  sta _vol_tmp
  lda $d418
  and #$f0
  ora _vol_tmp
  sta $d418
  sta sid_shadow+24
  clc
  rts
_vol_tmp: .byte 0

// --- soundbridge_set_sfx_base (AB) ---
// Relocates the SFX bytecode script bank. Arg is the high byte (page) of
// the new base; the bank is always page-aligned (low byte $00). The host
// must upload its SFX scripts to (page<<8) + ID*64 before calling AS.
soundbridge_set_sfx_base:
  lda temp_args+0
  sta sfx_base_hi
  clc
  rts

// --- soundbridge_set_mode (AM) ---
// Standard audio mode transition coordinator with hardware cleanup.
soundbridge_set_mode:
  lda temp_args+0
  cmp #4
  bcc !+
  jmp _mode_error
!:
  sta _new_mode
  
  cmp #$00                    // AM00: PLAYER_ONLY
  bne _not_m00
  
  jsr soundbridge_sfx_stop    // Stop active SFX
  lda #0
  sta voice_owner+0
  sta voice_owner+1
  sta voice_owner+2
  sta voice_priority+0
  sta voice_priority+1
  sta voice_priority+2
  jmp _apply_mode

_not_m00:
  lda _new_mode
  cmp #$01                    // AM01: SOUNDBRIDGE_ONLY
  bne _not_m01
  
  sei
  lda #$ff
  sta PlayRoutine+1           // Pause/stop player
  cli
  jsr Play_SilenceSID
  
  // Clear SID and shadow registers $D400-$D417, leaving $D418 volume intact
  ldx #23
  lda #0
!:
  sta $d400,x
  sta sid_shadow,x
  dex
  bpl !-
  
  sta voice_owner+0
  sta voice_owner+1
  sta voice_owner+2
  sta voice_priority+0
  sta voice_priority+1
  sta voice_priority+2
  jmp _apply_mode

_not_m01:
  lda _new_mode
  cmp #$02                    // AM02: MIXED_PLAYER_PLUS_SFX
  bne _not_m02
  
  jsr soundbridge_sfx_stop    // Stop active SFX first
  ldx #14                     // Voice index 2 (SFX voice)
  lda #0
  sta sid_shadow+4,x          // Clear Gate and shadow for Voice 2
  sta $d400+4,x
  sta voice_owner+2
  sta voice_priority+2
  jmp _apply_mode

_not_m02:
  // AM03: DIRECT_SID_MANUAL
  sei
  lda #$ff
  sta PlayRoutine+1           // Stop player
  cli
  jsr Play_SilenceSID
  jsr soundbridge_sfx_stop    // Stop SFX
  
_apply_mode:
  lda _new_mode
  sta audio_mode
  clc
  rts

_mode_error:
  sec
  rts
_new_mode: .byte 0

// --- check_voice_allowed ---
// Helper: Checks if the current mode permits modifying the voice index in A.
// Returns carry clear if allowed, carry set if not allowed.
check_voice_allowed:
  pha
  lda audio_mode
  cmp #$00
  beq _not_allowed            // PLAYER_ONLY: SoundBridge cannot write any voice
  cmp #$01
  beq _is_allowed             // SOUNDBRIDGE_ONLY: All voices allowed
  cmp #$03
  beq _is_allowed             // DIRECT_SID_MANUAL: All voices allowed
  
  // MIXED_PLAYER_PLUS_SFX (AM02): Voice must be exactly 2
  pla
  cmp #2
  beq _mixed_allowed
  sec
  rts

_mixed_allowed:
  clc
  rts

_is_allowed:
  pla
  clc
  rts

_not_allowed:
  pla
  sec
  rts

// --- soundbridge_define_instrument (AI) ---
// Defines a reusable instrument. Maps ID 1-16 to internal slot 0-15.
soundbridge_define_instrument:
  lda temp_args+0
  beq _inst_error
  cmp #17
  bcs _inst_error
  sec
  sbc #1                      // 1-based to 0-based index
  
  // Offset = ID * 5 = (ID * 4) + ID
  sta _inst_tmp
  asl
  asl
  clc
  adc _inst_tmp
  tax                         // X is offset in instrument_table
  
  lda temp_args+1              // PL
  sta instrument_table+0,x
  lda temp_args+2              // PH
  sta instrument_table+1,x
  lda temp_args+3              // AD
  sta instrument_table+2,x
  lda temp_args+4              // SR
  sta instrument_table+3,x
  lda temp_args+5              // CT
  sta instrument_table+4,x
  clc
  rts
_inst_error:
  sec
  rts
_inst_tmp: .byte 0

// --- soundbridge_note_on (AN) ---
// Starts playing a simple note with instrument parameters on a voice.
soundbridge_note_on:
  lda temp_args+0              // Voice index (0..2)
  cmp #3
  bcc !+
  jmp _note_error
!:
  sta _note_voice
  
  jsr check_voice_allowed
  bcc !+
  jmp _note_error
!:
  
  lda temp_args+3              // Instrument ID (1..16)
  bne !+
  jmp _note_error
!:
  cmp #17
  bcc !+
  jmp _note_error
!:
  sec
  sbc #1                      // Map to 0..15
  sta _note_inst
  
  ldx _note_voice
  lda voice_offsets,x
  sta _voice_offset
  
  // Instrument Offset = ID * 5
  lda _note_inst
  asl
  asl
  clc
  adc _note_inst
  sta _inst_offset
  
  // Portamento: when Slide is armed AND this voice already has a pitch, this
  // NoteOn glides instead of jumping. We STILL re-trigger the envelope (so the
  // keypress attacks audibly) and reload the instrument, but leave the SID
  // frequency and base_freq untouched so _update_slide ramps the pitch toward
  // slide_target. A flag records which path the rest of the routine takes.
  lda #0
  sta _note_glide
  ldx _note_voice
  lda effect_type,x
  cmp #02
  bne _ng_decided
  lda base_freq_lo,x
  ora base_freq_hi,x
  beq _ng_decided               // No prior pitch -> hard note
  lda #1
  sta _note_glide
_ng_decided:

  ldx _note_voice
  lda voice_offsets,x
  sta _voice_offset
  ldy _voice_offset
  
  // Write frequency to SID & shadow — skipped on a glide so the prior pitch
  // keeps sounding while the slide engine ramps it.
  lda _note_glide
  bne _skip_note_freq
  lda temp_args+1              // FL
  sta $d400+0,y
  sta sid_shadow+0,y
  lda temp_args+2              // FH
  sta $d400+1,y
  sta sid_shadow+1,y
_skip_note_freq:
  
  // Write instrument settings
  ldx _inst_offset
  lda instrument_table+0,x     // PL
  sta $d400+2,y
  sta sid_shadow+2,y
  lda instrument_table+1,x     // PH
  sta $d400+3,y
  sta sid_shadow+3,y
  lda instrument_table+2,x     // AD
  sta $d400+5,y
  sta sid_shadow+5,y
  lda instrument_table+3,x     // SR
  sta $d400+6,y
  sta sid_shadow+6,y
  
  // Force envelope re-trigger by cycling gate off first
  lda instrument_table+4,x     // CT
  and #$fe                    // Ensure Gate = 0
  sta $d400+4,y
  
  // Insert a tiny delay (12 cycles) for the SID envelope generator to register gate-off
  nop
  nop
  nop
  nop
  nop
  nop
  
  // Now set the Gate bit and write final control byte
  lda instrument_table+4,x     // CT
  ora #$01                    // Set Gate = 1
  sta $d400+4,y
  sta sid_shadow+4,y
  
  // Anchor base frequency (hard note only — a glide leaves base_freq so the
  // slide engine can ramp it). slide_target is always set to the new pitch:
  // on a hard note this just keeps them in sync (no jump); on a glide it is
  // the goal the pitch ramps toward.
  ldx _note_voice
  lda _note_glide
  bne _skip_base_freq
  lda temp_args+1              // FL
  sta base_freq_lo,x
  lda temp_args+2              // FH
  sta base_freq_hi,x
_skip_base_freq:
  lda temp_args+1
  sta slide_target_lo,x
  lda temp_args+2
  sta slide_target_hi,x
  
  ldy _inst_offset
  lda instrument_table+0,y     // PL
  sta base_pw_lo,x
  lda instrument_table+1,y     // PH
  sta base_pw_hi,x

  // Note: effect_type is intentionally NOT cleared here. Slide (portamento)
  // relies on the active effect persisting across consecutive NoteOns so the
  // next note glides from this one. Other effects also stay armed; clear
  // them explicitly with AE Off when no longer wanted.

  ldx _note_voice
  lda #02                      // simple note ownership
  sta voice_owner,x
  clc
  rts
_note_error:
  sec
  rts
_note_voice:   .byte 0
_note_inst:    .byte 0
_voice_offset: .byte 0
_inst_offset:  .byte 0
_note_glide:   .byte 0

// --- soundbridge_note_off (AO) ---
// Releases the gate bit on an active SoundBridge-owned note.
soundbridge_note_off:
  lda temp_args+0
  cmp #3
  bcs _off_error
  sta _off_voice
  
  jsr check_voice_allowed
  bcs _off_error
  
  ldx _off_voice
  lda voice_offsets,x
  tax                         // X is voice offset (0, 7, 14)
  
  lda sid_shadow+4,x
  and #$fe                    // Clear Gate
  sta sid_shadow+4,x
  sta $d400+4,x
  
  ldx _off_voice
  lda voice_owner,x
  cmp #02                     // simple note
  bne !+
  lda #0
  sta voice_owner,x
!:
  clc
  rts
_off_error:
  sec
  rts
_off_voice: .byte 0

// --- soundbridge_full_voice_setup (AF) ---
// Low-level write of all 7 parameters for a voice.
soundbridge_full_voice_setup:
  lda temp_args+0
  cmp #3
  bcc !+
  jmp _af_error
!:
  sta _af_voice
  jsr check_voice_allowed
  bcc !+
  jmp _af_error
!:
  
  ldx _af_voice
  lda voice_offsets,x
  tax
  
  lda temp_args+1              // FL
  sta $d400+0,x
  sta sid_shadow+0,x
  lda temp_args+2              // FH
  sta $d400+1,x
  sta sid_shadow+1,x
  lda temp_args+3              // PL
  sta $d400+2,x
  sta sid_shadow+2,x
  lda temp_args+4              // PH
  sta $d400+3,x
  sta sid_shadow+3,x
  lda temp_args+5              // AD
  sta $d400+5,x
  sta sid_shadow+5,x
  lda temp_args+6              // SR
  sta $d400+6,x
  sta sid_shadow+6,x
  lda temp_args+7              // CT
  sta $d400+4,x
  sta sid_shadow+4,x
  
  // Anchor base frequency and pulse width
  ldx _af_voice
  lda temp_args+1              // FL
  sta base_freq_lo,x
  lda temp_args+2              // FH
  sta base_freq_hi,x
  // Keep slide target in sync with this hard pitch set
  lda temp_args+1
  sta slide_target_lo,x
  lda temp_args+2
  sta slide_target_hi,x
  lda temp_args+3              // PL
  sta base_pw_lo,x
  lda temp_args+4              // PH
  sta base_pw_hi,x
  
  // Reset active effect for this voice upon FullVoice Setup
  lda #0
  sta effect_type,x
  
  ldx _af_voice
  lda #04                      // Direct owner
  sta voice_owner,x
  clc
  rts
_af_error:
  sec
  rts
_af_voice: .byte 0

// --- soundbridge_set_frequency (AQ) ---
soundbridge_set_frequency:
  lda temp_args+0
  cmp #3
  bcs _aq_error
  sta _aq_voice
  jsr check_voice_allowed
  bcs _aq_error
  
  ldx _aq_voice
  lda voice_offsets,x
  tax
  
  lda temp_args+1              // FL
  sta $d400+0,x
  sta sid_shadow+0,x
  lda temp_args+2              // FH
  sta $d400+1,x
  sta sid_shadow+1,x
  
  // Anchor base frequency
  ldx _aq_voice
  lda temp_args+1              // FL
  sta base_freq_lo,x
  lda temp_args+2              // FH
  sta base_freq_hi,x
  // Keep slide target in sync so AQ is a hard pitch set, not a glide
  lda temp_args+1
  sta slide_target_lo,x
  lda temp_args+2
  sta slide_target_hi,x
  
  clc
  rts
_aq_error:
  sec
  rts
_aq_voice: .byte 0

// --- soundbridge_set_adsr (AD) ---
soundbridge_set_adsr:
  lda temp_args+0
  cmp #3
  bcs _ad_error
  sta _ad_voice
  jsr check_voice_allowed
  bcs _ad_error
  
  ldx _ad_voice
  lda voice_offsets,x
  tax
  
  lda temp_args+1              // AD
  sta $d400+5,x
  sta sid_shadow+5,x
  lda temp_args+2              // SR
  sta $d400+6,x
  sta sid_shadow+6,x
  clc
  rts
_ad_error:
  sec
  rts
_ad_voice: .byte 0

// --- soundbridge_set_control (AW) ---
soundbridge_set_control:
  lda temp_args+0
  cmp #3
  bcs _aw_error
  sta _aw_voice
  jsr check_voice_allowed
  bcs _aw_error
  
  ldx _aw_voice
  lda voice_offsets,x
  tax
  
  lda temp_args+1              // CT
  sta $d400+4,x
  sta sid_shadow+4,x
  clc
  rts
_aw_error:
  sec
  rts
_aw_voice: .byte 0

// --- soundbridge_set_pulse_width (AP) ---
soundbridge_set_pulse_width:
  lda temp_args+0
  cmp #3
  bcs _ap_error
  sta _ap_voice
  jsr check_voice_allowed
  bcs _ap_error
  
  ldx _ap_voice
  lda voice_offsets,x
  tax
  
  lda temp_args+1              // PL
  sta $d400+2,x
  sta sid_shadow+2,x
  lda temp_args+2              // PH
  sta $d400+3,x
  sta sid_shadow+3,x
  
  // Anchor base pulse width
  ldx _ap_voice
  lda temp_args+1              // PL
  sta base_pw_lo,x
  lda temp_args+2              // PH
  sta base_pw_hi,x
  
  clc
  rts
_ap_error:
  sec
  rts
_ap_voice: .byte 0

// --- soundbridge_set_effect (AE) ---
soundbridge_set_effect:
  lda temp_args+0
  cmp #3
  bcc !+
  rts                           // Validate Voice index < 3
!:
  tax
  jsr check_voice_allowed       // Verify voice is owned by SoundBridge in this mode
  bcs !+
  
  ldx temp_args+0
  lda temp_args+1
  sta effect_type,x
  lda temp_args+2
  sta effect_speed,x
  lda temp_args+3
  sta effect_depth,x
  lda #0
  sta effect_phase,x            // Reset phase accumulator
  sta arp_step,x                // Reset arpeggio to root tone
  // Note: slide_target is intentionally NOT touched here. It is owned by
  // note_on (synced to the note on a hard NoteOn, set to the new pitch on a
  // gliding NoteOn). Resetting it here would clobber an in-progress glide
  // when the host re-applies AE after a NoteOn.
!:
  rts

// --- soundbridge_sfx_play (AS) ---
// Plays a custom bytecode sound effect using Voice index 2.
soundbridge_sfx_play:
  lda temp_args+0
  cmp #16
  bcs _play_error
  sta _play_id
  
  lda temp_args+1
  sta _play_priority
  
  lda sfx_active
  beq _start_sfx
  
  // Replace current SFX if priority is >= active SFX priority
  lda _play_priority
  cmp sfx_priority
  bcc _play_ignored           // If priority too low, fail silently (carry clear)
  
_start_sfx:
  lda _play_id
  sta sfx_id
  lda _play_priority
  sta sfx_priority
  lda #1
  sta sfx_active
  lda #0
  sta sfx_wait
  
  // Set pointer to SFX Slot address: (sfx_base_hi<<8) + ID * 64
  // Base is page-aligned (low byte $00), so the slot low byte passes
  // through directly and any carry rolls into the runtime base page.
  ldx _play_id
  lda sfx_slot_lo,x
  sta sfx_ptr_lo
  lda sfx_slot_hi,x
  clc
  adc sfx_base_hi
  sta sfx_ptr_hi
  
  // Own Voice index 2 as SFX
  lda #03                    // sfx ownership ID
  sta voice_owner+2
  lda _play_priority
  sta voice_priority+2
  clc
  rts
_play_ignored:
  clc
  rts
_play_error:
  sec
  rts
_play_id:       .byte 0
_play_priority: .byte 0

// --- soundbridge_sfx_stop (AX) ---
// Silences active sound effect on Voice index 2.
soundbridge_sfx_stop:
  lda #0
  sta sfx_active
  sta sfx_wait
  sta sfx_priority
  sta voice_owner+2
  
  ldx #14                     // Voice index 2 offset
  lda sid_shadow+4,x
  and #$fe                    // Gate Off
  sta sid_shadow+4,x
  sta $d400+4,x
  rts

// --- soundbridge_sound_stop_all (AZ) ---
// Releases all SoundBridge manual notes and halts sound effects.
soundbridge_sound_stop_all:
  lda #0
  sta sfx_active
  sta sfx_wait
  sta sfx_priority
  
  ldx #0
_stop_loop:
  lda voice_offsets,x
  tay
  lda sid_shadow+4,y
  and #$fe
  sta sid_shadow+4,y
  sta $d400+4,y
  
  lda voice_owner,x
  cmp #02                     // simple note
  beq _clear_owner
  cmp #03                     // sfx
  beq _clear_owner
  jmp _next_voice
  
_clear_owner:
  lda #0
  sta voice_owner,x
  sta voice_priority,x
  
_next_voice:
  inx
  cpx #3
  bne _stop_loop
  rts

// ============================================================================
// SFX Bytecode interpreter
// ============================================================================

// --- read_sfx_byte ---
// Reads next script byte, increments ptr.
read_sfx_byte:
  ldy #0
  lda (sfx_ptr_lo),y
  inc sfx_ptr_lo
  bne !+
  inc sfx_ptr_hi
!:
  rts

// --- sfx_update ---
// Execution engine triggered once per frame inside KERNAL jiffy IRQ.
sfx_update:
  lda sfx_active
  bne !+
  rts
!:
  lda sfx_wait
  beq _interpreter_loop
  dec sfx_wait
  rts

_interpreter_loop:
  jsr read_sfx_byte           // Command in A
  
  cmp #00                     // 00 = END
  bne !+
  sta sfx_active              // Silence and terminate
  ldx #14
  lda sid_shadow+4,x
  and #$fe
  sta sid_shadow+4,x
  sta $d400+4,x
  sta voice_owner+2
  rts

!:
  cmp #01                     // 01 = WAIT ticks
  bne !+
  jsr read_sfx_byte
  sta sfx_wait
  rts

!:
  cmp #02                     // 02 = SET_FULL FL FH PL PH AD SR CT
  bne !+
  ldx #14
  
  jsr read_sfx_byte           // FL
  sta $d400+0,x
  sta sid_shadow+0,x
  
  jsr read_sfx_byte           // FH
  sta $d400+1,x
  sta sid_shadow+1,x
  
  jsr read_sfx_byte           // PL
  sta $d400+2,x
  sta sid_shadow+2,x
  
  jsr read_sfx_byte           // PH
  sta $d400+3,x
  sta sid_shadow+3,x
  
  jsr read_sfx_byte           // AD
  sta $d400+5,x
  sta sid_shadow+5,x
  
  jsr read_sfx_byte           // SR
  sta $d400+6,x
  sta sid_shadow+6,x
  
  jsr read_sfx_byte           // CT
  sta $d400+4,x
  sta sid_shadow+4,x
  
  jmp _interpreter_loop

!:
  cmp #03                     // 03 = SET_FREQ FL FH
  bne !+
  ldx #14
  jsr read_sfx_byte
  sta $d400+0,x
  sta sid_shadow+0,x
  jsr read_sfx_byte
  sta $d400+1,x
  sta sid_shadow+1,x
  jmp _interpreter_loop

!:
  cmp #04                     // 04 = SET_CTRL CT
  bne !+
  ldx #14
  jsr read_sfx_byte
  sta $d400+4,x
  sta sid_shadow+4,x
  jmp _interpreter_loop

!:
  cmp #05                     // 05 = SET_ADSR AD SR
  bne !+
  ldx #14
  jsr read_sfx_byte
  sta $d400+5,x
  sta sid_shadow+5,x
  jsr read_sfx_byte
  sta $d400+6,x
  sta sid_shadow+6,x
  jmp _interpreter_loop

!:
  cmp #06                     // 06 = SET_PULSE PL PH
  bne !+
  ldx #14
  jsr read_sfx_byte
  sta $d400+2,x
  sta sid_shadow+2,x
  jsr read_sfx_byte
  sta $d400+3,x
  sta sid_shadow+3,x
  jmp _interpreter_loop

!:
  cmp #07                     // 07 = GATE_OFF
  bne !+
  ldx #14
  lda sid_shadow+4,x
  and #$fe
  sta sid_shadow+4,x
  sta $d400+4,x
  jmp _interpreter_loop

!:
  // Safe Fallback: End script on invalid bytecodes
  lda #0
  sta sfx_active
  rts

// ============================================================================
// soundbridge_effects_update
// Ticks local note modulation effects once per frame inside KERNAL jiffy IRQ.
// ============================================================================
soundbridge_effects_update:
  lda #0
  sta _effects_voice
_voice_loop:
  lda _effects_voice
  jsr check_voice_allowed
  bcs _fx_next_voice             // Skip if voice not allowed in this mode
  
  ldx _effects_voice
  lda effect_type,x
  beq _fx_next_voice             // Skip if no effect on this voice
  
  cmp #01
  bne !+
  jsr _update_vibrato
  jmp _fx_next_voice
!:
  cmp #02
  bne !+
  jsr _update_slide
  jmp _fx_next_voice
!:
  cmp #03
  bne !+
  jsr _update_pwm
  jmp _fx_next_voice
!:
  cmp #04
  bne _fx_next_voice
  jsr _update_arp

_fx_next_voice:
  inc _effects_voice
  lda _effects_voice
  cmp #3
  bcc _voice_loop
  rts

// --- Local Vibrato Update ---
_update_vibrato:
  ldx _effects_voice
  lda effect_phase,x
  clc
  adc effect_speed,x
  sta effect_phase,x
  
  lsr
  lsr
  lsr
  lsr
  and #$0f
  tay
  lda vibrato_table,y
  sta _offset_raw
  
  lda #0
  sta _freq_delta_lo
  sta _freq_delta_hi
  
  lda _offset_raw
  bne !+
  jmp _vibrato_done_calc
!:
  
  bpl _vibrato_positive
  eor #$ff
  clc
  adc #1
_vibrato_positive:
  sta _temp_abs
  
  lda effect_depth,x
  sta _temp_depth_lo
  lda #0
  sta _temp_depth_hi
  
  lda _temp_abs
  cmp #1
  bne !+
  lda _temp_depth_lo
  sta _freq_delta_lo
  lda _temp_depth_hi
  sta _freq_delta_hi
  jmp _vibrato_apply_sign
!:
  cmp #2
  bne !+
  lda _temp_depth_lo
  asl
  sta _freq_delta_lo
  lda _temp_depth_hi
  rol
  sta _freq_delta_hi
  jmp _vibrato_apply_sign
!:
  cmp #3
  bne !+
  lda _temp_depth_lo
  asl
  sta _freq_delta_lo
  lda _temp_depth_hi
  rol
  sta _freq_delta_hi
  
  lda _freq_delta_lo
  clc
  adc _temp_depth_lo
  sta _freq_delta_lo
  lda _freq_delta_hi
  adc _temp_depth_hi
  sta _freq_delta_hi
  jmp _vibrato_apply_sign
!:
  // Must be 4
  lda _temp_depth_lo
  asl
  sta _freq_delta_lo
  lda _temp_depth_hi
  rol
  sta _freq_delta_hi
  
  asl _freq_delta_lo
  rol _freq_delta_hi

_vibrato_apply_sign:
  lda _offset_raw
  bpl _vibrato_done_calc
  
  // Negate 16-bit
  lda #0
  sec
  sbc _freq_delta_lo
  sta _freq_delta_lo
  lda #0
  sbc _freq_delta_hi
  sta _freq_delta_hi

_vibrato_done_calc:
  lda base_freq_lo,x
  clc
  adc _freq_delta_lo
  sta _current_freq_lo
  lda base_freq_hi,x
  adc _freq_delta_hi
  sta _current_freq_hi
  
  ldy voice_offsets,x
  lda _current_freq_lo
  cmp sid_shadow+0,y
  bne _write_vibrato
  lda _current_freq_hi
  cmp sid_shadow+1,y
  beq _vibrato_done
_write_vibrato:
  lda _current_freq_lo
  sta $d400+0,y
  sta sid_shadow+0,y
  lda _current_freq_hi
  sta $d400+1,y
  sta sid_shadow+1,y
_vibrato_done:
  rts

// --- Local Pitch Slide Update (Portamento) ---
// Glides base_freq toward slide_target by `effect_depth` SID units per gated
// frame. effect_speed gates the step rate: every frame phase += speed and we
// step only on carry-out, so larger speed = more frequent steps (speed=$FF
// steps almost every frame; speed=$00 never carries, freezing the glide).
// Direction (up vs down) and reaching the target are handled automatically
// based on the sign of (target - base). When base_freq == slide_target the
// slide is idle and writes nothing, but stays armed for the next NoteOn.
_update_slide:
  ldx _effects_voice
  lda effect_phase,x
  clc
  adc effect_speed,x
  sta effect_phase,x
  bcs !+
  jmp _slide_done                // No step this frame
!:
  
  // Compute delta = slide_target - base_freq (16-bit signed sense)
  lda slide_target_lo,x
  sec
  sbc base_freq_lo,x
  sta _slide_lo                  // |delta| LSB if positive
  lda slide_target_hi,x
  sbc base_freq_hi,x
  sta _slide_hi                  // |delta| MSB if positive (carry==1 means up)
  bcs _slide_up
  
  // Target is below base_freq -> slide down. Take absolute of negative delta
  // by two's-complement negation: (~delta)+1.
  lda _slide_lo
  eor #$ff
  clc
  adc #1
  sta _slide_lo
  lda _slide_hi
  eor #$ff
  adc #0
  sta _slide_hi
  
  // Compare |delta| against effect_depth: if |delta| <= depth, snap to target.
  lda _slide_hi
  bne _slide_down_step           // |delta| >= 256 -> definitely > depth
  lda _slide_lo
  cmp effect_depth,x
  beq _slide_snap_target         // |delta| == depth -> exactly reach target
  bcc _slide_snap_target         // |delta| < depth  -> overshoot guard
_slide_down_step:
  lda base_freq_lo,x
  sec
  sbc effect_depth,x
  sta base_freq_lo,x
  lda base_freq_hi,x
  sbc #0
  sta base_freq_hi,x
  jmp _slide_write

_slide_up:
  // |delta| <= depth check (overshoot guard).
  lda _slide_hi
  bne _slide_up_step
  lda _slide_lo
  cmp effect_depth,x
  beq _slide_snap_target
  bcc _slide_snap_target
_slide_up_step:
  lda base_freq_lo,x
  clc
  adc effect_depth,x
  sta base_freq_lo,x
  lda base_freq_hi,x
  adc #0
  sta base_freq_hi,x
  jmp _slide_write

_slide_snap_target:
  lda slide_target_lo,x
  sta base_freq_lo,x
  lda slide_target_hi,x
  sta base_freq_hi,x

_slide_write:
  ldy voice_offsets,x
  lda base_freq_lo,x
  cmp sid_shadow+0,y
  bne _write_slide
  lda base_freq_hi,x
  cmp sid_shadow+1,y
  beq _slide_done
_write_slide:
  lda base_freq_lo,x
  sta $d400+0,y
  sta sid_shadow+0,y
  lda base_freq_hi,x
  sta $d400+1,y
  sta sid_shadow+1,y
_slide_done:
  rts

// --- Local Pulse-Width Modulation Update ---
_update_pwm:
  ldx _effects_voice
  lda effect_phase,x
  clc
  adc effect_speed,x
  sta effect_phase,x
  
  lsr
  lsr
  lsr
  lsr
  and #$0f
  tay
  lda vibrato_table,y
  sta _offset_raw
  
  lda #0
  sta _pw_delta_lo
  sta _pw_delta_hi
  
  lda _offset_raw
  bne !+
  jmp _pwm_done_calc
!:
  
  bpl _pwm_positive
  eor #$ff
  clc
  adc #1
_pwm_positive:
  sta _temp_abs
  
  lda effect_depth,x
  sta _temp_depth_lo
  lda #0
  sta _temp_depth_hi
  
  lda _temp_abs
  cmp #1
  bne !+
  lda _temp_depth_lo
  sta _pw_delta_lo
  lda _temp_depth_hi
  sta _pw_delta_hi
  jmp _pwm_apply_sign
!:
  cmp #2
  bne !+
  lda _temp_depth_lo
  asl
  sta _pw_delta_lo
  lda _temp_depth_hi
  rol
  sta _pw_delta_hi
  jmp _pwm_apply_sign
!:
  cmp #3
  bne !+
  lda _temp_depth_lo
  asl
  sta _pw_delta_lo
  lda _temp_depth_hi
  rol
  sta _pw_delta_hi
  
  lda _pw_delta_lo
  clc
  adc _temp_depth_lo
  sta _pw_delta_lo
  lda _pw_delta_hi
  adc _temp_depth_hi
  sta _pw_delta_hi
  jmp _pwm_apply_sign
!:
  // Must be 4
  lda _temp_depth_lo
  asl
  sta _pw_delta_lo
  lda _temp_depth_hi
  rol
  sta _pw_delta_hi
  
  asl _pw_delta_lo
  rol _pw_delta_hi

_pwm_apply_sign:
  lda _offset_raw
  bpl _pwm_done_calc
  
  // Negate 16-bit
  lda #0
  sec
  sbc _pw_delta_lo
  sta _pw_delta_lo
  lda #0
  sbc _pw_delta_hi
  sta _pw_delta_hi

_pwm_done_calc:
  lda base_pw_lo,x
  clc
  adc _pw_delta_lo
  sta _current_pw_lo
  lda base_pw_hi,x
  adc _pw_delta_hi
  sta _current_pw_hi
  
  // Underflow check (< $0080)
  lda _current_pw_hi
  bmi _clamp_low               // Negative is < $0080
  bne !+                       // If high byte is not 0, it is >= $0100, so check if >= $0080 is true
  lda _current_pw_lo
  cmp #$80
  bcc _clamp_low
!:
  // Overflow check (> $0F80)
  lda _current_pw_hi
  cmp #$10
  bcs _clamp_high              // If >= $1000
  cmp #$0f
  bcc _pw_clamped              // If < $0f00, it's fine
  lda _current_pw_lo
  cmp #$81
  bcc _pw_clamped              // If <= $80 when high byte is $0f
_clamp_high:
  lda #$80
  sta _current_pw_lo
  lda #$0f
  sta _current_pw_hi
  jmp _pw_clamped
_clamp_low:
  lda #$80
  sta _current_pw_lo
  lda #$00
  sta _current_pw_hi
_pw_clamped:
  ldy voice_offsets,x
  lda _current_pw_lo
  cmp sid_shadow+2,y
  bne _write_pw
  lda _current_pw_hi
  cmp sid_shadow+3,y
  beq _pwm_done
_write_pw:
  lda _current_pw_lo
  sta $d400+2,y
  sta sid_shadow+2,y
  lda _current_pw_hi
  sta $d400+3,y
  sta sid_shadow+3,y
_pwm_done:
  rts

// ----------------------------------------------------------------------------
// _update_arp  (effect type 04)
// Classic SID "chord" arpeggio: rapidly cycles the voice through root -> third
// -> fifth, one tone per step, so the ear fuses them into a chord while only
// consuming a single SID voice.
//
//   effect_speed = hold frames per tone (0 = change every frame = fast buzz)
//   effect_depth = chord quality: 0 = MAJOR (0,+4,+7), 1 = MINOR (0,+3,+7)
//   effect_phase = per-voice hold countdown (reused)
//   arp_step     = current tone index (0=root, 1=third, 2=fifth)
//
// The root pitch is the voice's anchored base_freq (set by NoteOn/SetFreq).
// Third/fifth are derived as base_freq * ratio using an 8.8 fixed-point
// fractional multiply: result = base_freq + (base_freq * frac) >> 8, where
//   minor 3rd frac=$30 (x1.1875), major 3rd frac=$42 (x1.2578), 5th frac=$80 (x1.5)
// ----------------------------------------------------------------------------
_update_arp:
  ldx _effects_voice
  lda effect_phase,x
  beq _arp_do_step             // Countdown elapsed -> advance tone
  dec effect_phase,x
  rts                          // Still holding current tone

_arp_do_step:
  lda effect_speed,x
  sta effect_phase,x           // Reload hold countdown

  ldy arp_step,x
  cpy #0
  bne _arp_not_root
  // Root tone: write anchored base frequency directly
  lda base_freq_lo,x
  sta _arp_freq_lo
  lda base_freq_hi,x
  sta _arp_freq_hi
  jmp _arp_write

_arp_not_root:
  cpy #2
  beq _arp_fifth
  // Third tone: major or minor based on effect_depth
  lda effect_depth,x
  bne _arp_minor
  lda #$42                     // Major third fraction
  jmp _arp_mul
_arp_minor:
  lda #$30                     // Minor third fraction
  jmp _arp_mul
_arp_fifth:
  lda #$80                     // Perfect fifth fraction (x1.5)
_arp_mul:
  sta _arp_frac
  lda base_freq_lo,x
  sta _arp_mul_lo
  lda base_freq_hi,x
  sta _arp_mul_hi
  jsr _arp_mul16x8             // _arp_p2:_arp_p1 = (base_freq * frac) >> 8

  ldx _effects_voice
  lda base_freq_lo,x
  clc
  adc _arp_p1
  sta _arp_freq_lo
  lda base_freq_hi,x
  adc _arp_p2
  sta _arp_freq_hi

_arp_write:
  ldx _effects_voice
  ldy voice_offsets,x
  lda _arp_freq_lo
  sta $d400+0,y
  sta sid_shadow+0,y
  lda _arp_freq_hi
  sta $d400+1,y
  sta sid_shadow+1,y

  // Advance tone index (wrap 0..2)
  ldx _effects_voice
  inc arp_step,x
  lda arp_step,x
  cmp #3
  bcc _arp_done
  lda #0
  sta arp_step,x
_arp_done:
  rts

// 16x8 -> 24-bit multiply: (_arp_mul_hi:_arp_mul_lo) * _arp_frac
// Result product in _arp_p2:_arp_p1:_arp_p0. Caller uses _arp_p2:_arp_p1 (>>8).
// Destroys A, X, and _arp_frac.
_arp_mul16x8:
  lda #0
  sta _arp_p0
  sta _arp_p1
  sta _arp_p2
  ldx #8
_arp_mul_loop:
  asl _arp_p0
  rol _arp_p1
  rol _arp_p2
  asl _arp_frac
  bcc _arp_mul_skip
  clc
  lda _arp_p0
  adc _arp_mul_lo
  sta _arp_p0
  lda _arp_p1
  adc _arp_mul_hi
  sta _arp_p1
  lda _arp_p2
  adc #0
  sta _arp_p2
_arp_mul_skip:
  dex
  bne _arp_mul_loop
  rts

// --- Local Effects Variables ---
_effects_voice:   .byte 0
_offset_raw:      .byte 0
_temp_abs:        .byte 0
_temp_depth_lo:   .byte 0
_temp_depth_hi:   .byte 0

_freq_delta_lo:   .byte 0
_freq_delta_hi:   .byte 0
_current_freq_lo: .byte 0
_current_freq_hi: .byte 0

_slide_lo:        .byte 0
_slide_hi:        .byte 0
_temp_freq_lo:    .byte 0
_temp_freq_hi:    .byte 0

_pw_delta_lo:     .byte 0
_pw_delta_hi:     .byte 0
_current_pw_lo:   .byte 0
_current_pw_hi:   .byte 0

_arp_frac:        .byte 0
_arp_mul_lo:      .byte 0
_arp_mul_hi:      .byte 0
_arp_p0:          .byte 0
_arp_p1:          .byte 0
_arp_p2:          .byte 0
_arp_freq_lo:     .byte 0
_arp_freq_hi:     .byte 0
