// ============================================================================
// soundbridge.asm -- SoundBridge Sound Engine, Synthesizer & SFX Interpreter
// ============================================================================

// --- SoundBridge Variables ---
// 01=ENGINE (tracker/SFX/effects tick each jiffy), 03=DIRECT (host owns SID).
// Legacy mode values 00/02 (PlayerOnly/Mixed) map to ENGINE on the wire.
audio_mode:         .byte 1
voice_owner:        .byte 0, 0, 0     // 0=None, 2=Note, 3=SFX, 4=Direct (1 was Player, retired)
voice_priority:     .byte 0, 0, 0     // Priorities for voice stealing / play rules
voice_note_idx:     .byte 0, 0, 0     // Note-table index (1..95) of the voice's last
                                      // note-on; lets arpeggios run in true semitones.
                                      // 0 = unknown (raw-frequency pitch set).
voice_released:     .byte 0, 0, 0     // 1 after a note-off: the phrase ended, so an
                                      // armed slide plays the next note hard instead
                                      // of gliding from the released pitch.

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

// Per-voice SFX contexts: any of the 3 voices can run its own bytecode
// script concurrently (drums on any voice + a laser on another, etc.).
// ZP sfx_ptr_lo/hi holds the pointer of the context currently being
// sliced; sfx_ptr_lo_v/hi_v are the parked per-voice pointers.
sfx_active:         .byte 0, 0, 0
sfx_priority:       .byte 0, 0, 0
sfx_wait:           .byte 0, 0, 0
sfx_ptr_lo_v:       .byte 0, 0, 0
sfx_ptr_hi_v:       .byte 0, 0, 0
sfx_start_lo_v:     .byte 0, 0, 0     // slot start, for the RESTART ($0A) opcode
sfx_start_hi_v:     .byte 0, 0, 0
sfx_slide_on:       .byte 0, 0, 0     // PITCH_SLIDE ($08) active during wait
sfx_slide_dlo:      .byte 0, 0, 0     // signed 16-bit per-frame freq delta
sfx_slide_dhi:      .byte 0, 0, 0
sfx_cur_voice:      .byte 0           // voice index of the context being run
sfx_cur_off:        .byte 0           // its SID register offset (0/7/14)

// Global argument buffer for parsing
temp_args:          .fill 8, 0

// Per-voice PITCH modulation state (3 voices). Slot holds one pitch effect:
// 01=Vibrato, 02=Slide (incl. legato, see slide_legato), 04=Arpeggio.
// Type 03 (pulse LFO) lives in its own pwm_* slot below so pulse-width
// modulation can run concurrently with any pitch effect.
effect_type:     .byte 0, 0, 0
effect_speed:    .byte 0, 0, 0     // Rate of modulation
effect_depth:    .byte 0, 0, 0     // Scale of modulation / arp semitone nibbles
effect_phase:    .byte 0, 0, 0     // LFO phase / slide gate / arp hold countdown
arp_step:        .byte 0, 0, 0     // Arpeggio tone index (0=root, 1=second, 2=third)
slide_legato:    .byte 0, 0, 0     // 1 = glides retarget without envelope retrigger

// Per-voice pulse LFO (effect type 03), orthogonal to the pitch slot
pwm_speed:       .byte 0, 0, 0
pwm_depth:       .byte 0, 0, 0     // 0 speed AND 0 depth = off
pwm_phase:       .byte 0, 0, 0

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
// Stops the tracker, silences all SID registers, clears shadow registers,
// stops SFX, zeroes ownership.
soundbridge_reset:
  sei
  jsr tracker_stop
  lda #0
  ldx #2
!:
  sta sfx_active,x
  sta sfx_wait,x
  sta sfx_priority,x
  sta sfx_slide_on,x
  sta voice_owner,x
  sta voice_priority,x
  dex
  bpl !-

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
  sta slide_legato,x
  sta pwm_speed,x
  sta pwm_depth,x
  sta pwm_phase,x
  sta voice_note_idx,x
  sta voice_released,x
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
// Wire-compatible mode set. 3 = DIRECT (host owns the SID registers, no
// background updates); anything else (legacy 0/1/2) = ENGINE. Both
// transitions stop the tracker and any running SFX scripts.
soundbridge_set_mode:
  lda temp_args+0
  cmp #4
  bcs _mode_error
  cmp #3
  beq _mode_direct

  // ENGINE: silence and reclaim everything for a clean slate.
  lda #1
  sta audio_mode
  jsr tracker_stop
  jsr soundbridge_sfx_stop

  // Clear SID and shadow registers $D400-$D417, leaving $D418 volume intact
  ldx #23
  lda #0
!:
  sta $d400,x
  sta sid_shadow,x
  dex
  bpl !-

  ldx #2
!:
  sta voice_owner,x
  sta voice_priority,x
  dex
  bpl !-
  clc
  rts

_mode_direct:
  sta audio_mode
  jsr tracker_stop
  jsr soundbridge_sfx_stop
  clc
  rts

_mode_error:
  sec
  rts

// --- soundbridge_set_filter (AG) ---
// Programs the SID filter: cutoff (11 bits split as low 3 / high 8),
// resonance + voice routing ($D417), and the filter mode bits (high
// nibble of $D418, master volume nibble preserved).
// temp_args: cutLo (0-7), cutHi, resRoute, mode
soundbridge_set_filter:
  lda temp_args+0
  and #$07
  sta $d415
  sta sid_shadow+21
  lda temp_args+1
  sta $d416
  sta sid_shadow+22
  lda temp_args+2
  sta $d417
  sta sid_shadow+23
  lda temp_args+3
  and #$f0
  sta _filt_tmp
  lda sid_shadow+24
  and #$0f
  ora _filt_tmp
  sta $d418
  sta sid_shadow+24
  clc
  rts
_filt_tmp: .byte 0

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
  lda voice_released,x
  bne _ng_decided               // Phrase ended with a note-off -> hard note
  lda #1
  sta _note_glide
_ng_decided:

  // Legato glide: the envelope keeps running and the instrument stays as-is;
  // the note only becomes the new slide target. Only valid while the voice
  // is actually sounding (gate on) -- after a hard restart or note-off the
  // tie falls through to a normal retriggered glide instead.
  ldx _note_voice
  lda _note_glide
  beq !+
  lda slide_legato,x
  beq !+
  ldy voice_offsets,x
  lda sid_shadow+4,y
  and #$01
  beq !+
  jmp _legato_retarget
!:

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

  // Track the note index so arpeggios can run in true semitones. Raw AN
  // callers get the nearest table entry (first >= the commanded frequency);
  // index-aware callers (AK, the tracker) overwrite with the exact index
  // afterwards and set _no_skip_idx so this search is skipped in the IRQ.
  lda _no_skip_idx
  bne _idx_done
  ldy #1
_idx_loop:
  lda note_freq_hi,y
  cmp temp_args+2
  bcc _idx_next
  bne _idx_found
  lda note_freq_lo,y
  cmp temp_args+1
  bcs _idx_found
_idx_next:
  iny
  cpy #96
  bne _idx_loop
  ldy #95
_idx_found:
  ldx _note_voice
  tya
  sta voice_note_idx,x
_idx_done:

  ldx _note_voice
  lda #0
  sta voice_released,x
  lda #02                      // simple note ownership
  sta voice_owner,x
  clc
  rts

_legato_retarget:
  ldx _note_voice
  lda temp_args+1
  sta slide_target_lo,x
  lda temp_args+2
  sta slide_target_hi,x
  lda #0
  sta voice_released,x
  lda #02
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
_no_skip_idx:  .byte 0

// --- soundbridge_note_on_by_index (AK / tracker rows) ---
// temp_args: voice (0..2), note index (1..95), instrument id (1..16).
// Looks the frequency up in the note table, plays through the normal
// note-on path, then records the exact index for semitone-aware effects.
soundbridge_note_on_by_index:
  lda temp_args+1
  beq _noi_error
  cmp #96
  bcs _noi_error
  sta _noi_idx
  lda temp_args+2              // shift inst into the AN argument layout
  sta temp_args+3
  ldy _noi_idx
  lda note_freq_lo,y
  sta temp_args+1
  lda note_freq_hi,y
  sta temp_args+2
  lda #1
  sta _no_skip_idx
  jsr soundbridge_note_on
  lda #0
  sta _no_skip_idx             // lda leaves carry (the result) intact
  bcs _noi_error
  ldx temp_args+0
  lda _noi_idx
  sta voice_note_idx,x
  clc
  rts
_noi_error:
  sec
  rts
_noi_idx: .byte 0

// --- soundbridge_note_off (AO) ---
// Releases the gate bit on an active SoundBridge-owned note.
soundbridge_note_off:
  lda temp_args+0
  cmp #3
  bcs _off_error
  sta _off_voice

  ldx _off_voice
  lda voice_offsets,x
  tax                         // X is voice offset (0, 7, 14)
  
  lda sid_shadow+4,x
  and #$fe                    // Clear Gate
  sta sid_shadow+4,x
  sta $d400+4,x

  // A note-off ends the phrase: the next note on this voice plays hard
  // instead of gliding from the released pitch. base_freq is deliberately
  // kept so vibrato/slide keep modulating the REAL pitch through the
  // release tail (zeroing it makes the LFO wrap below 0 to max frequency).
  ldx _off_voice
  lda #1
  sta voice_released,x

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

  ldx _af_voice
  lda voice_offsets,x
  sta _af_base                // voice base (0/7/14)

  // Write all 7 SID registers via a table mapping argument order -> SID
  // register offset, in the same FL,FH,PL,PH,AD,SR,CT order as the old unrolled
  // block (control/gate is written LAST so the envelope attacks at the final
  // pitch). X = voice base + register offset; mirrored into the shadow.
  ldy #0
_af_wloop:
  lda af_sid_off,y
  clc
  adc _af_base
  tax
  lda temp_args+1,y
  sta $d400,x
  sta sid_shadow,x
  iny
  cpy #7
  bne _af_wloop
  
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
_af_base:  .byte 0
// Argument index (temp_args+1..7) -> SID register offset, FL,FH,PL,PH,AD,SR,CT.
af_sid_off: .byte 0, 1, 2, 3, 5, 6, 4

// --- soundbridge_set_frequency (AQ) ---
soundbridge_set_frequency:
  lda temp_args+0
  cmp #3
  bcs _aq_error
  sta _aq_voice

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
// temp_args: voice, type, speed, depth.
//   type 0          clears the pitch effect AND the pulse LFO
//   type 1/2/4/5    sets the pitch slot (and clears the pulse LFO, so a
//                   single AE keeps the voice deterministic); 5 = legato
//                   slide (glides retarget without retriggering)
//   type 3          sets the pulse LFO only -- send it AFTER a pitch
//                   effect to run both concurrently
//   type 4 depth    $xy = semitone offsets for the 2nd/3rd chord tones;
//                   legacy values $00 -> $47 (major), $01 -> $37 (minor)
soundbridge_set_effect:
  lda temp_args+0
  cmp #3
  bcs _ae_done                  // Validate voice index < 3
  tax

  lda temp_args+1
  beq _ae_clear_all
  cmp #3
  beq _ae_pulse_lfo
  cmp #6
  bcs _ae_done                  // Unknown type: ignore

  // Pitch family (1 vibrato, 2 slide, 4 arpeggio, 5 legato slide)
  pha                           // keep the type
  lda #0
  sta pwm_speed,x
  sta pwm_depth,x
  sta slide_legato,x
  pla
  cmp #5
  bne !+
  lda #1
  sta slide_legato,x
  lda #2                        // legato is stored as slide + flag
!:
  sta effect_type,x
  lda temp_args+2
  sta effect_speed,x

  lda effect_type,x
  cmp #4
  bne _ae_store_depth
  lda temp_args+3
  cmp #2
  bcs _ae_store_depth           // >= 2: literal semitone nibbles
  tay                           // legacy 0 = major, 1 = minor
  lda _ae_arp_legacy,y
  sta temp_args+3
_ae_store_depth:
  lda temp_args+3
  sta effect_depth,x
  lda #0
  sta effect_phase,x            // Reset phase accumulator
  sta arp_step,x                // Reset arpeggio to root tone
  // Note: slide_target is intentionally NOT touched here. It is owned by
  // note_on (synced to the note on a hard NoteOn, set to the new pitch on a
  // gliding NoteOn). Resetting it here would clobber an in-progress glide
  // when the host re-applies AE after a NoteOn.
  rts

_ae_pulse_lfo:
  lda temp_args+2
  sta pwm_speed,x
  lda temp_args+3
  sta pwm_depth,x
  lda #0
  sta pwm_phase,x
  rts

_ae_clear_all:
  lda #0
  sta effect_type,x
  sta slide_legato,x
  sta pwm_speed,x
  sta pwm_depth,x
_ae_done:
  rts
_ae_arp_legacy: .byte $47, $37

// --- soundbridge_sfx_play (AS) ---
// Plays a custom bytecode sound effect: args = slot id, priority, voice.
// Voice arg >= 3 targets Voice index 2 (legacy callers sent a "flags"
// byte here, and the old engine was hardwired to voice 2 -- but $00 from
// legacy callers now lands on voice 0, which is the documented new default).
soundbridge_sfx_play:
  lda temp_args+0
  cmp #16
  bcs _play_error
  sta _play_id

  lda temp_args+1
  sta _play_priority

  lda temp_args+2
  cmp #3
  bcc !+
  lda #2
!:
  sta _play_voice
  tax

  lda sfx_active,x
  beq _start_sfx

  // Replace current SFX if priority is >= active SFX priority
  lda _play_priority
  cmp sfx_priority,x
  bcc _play_ignored           // If priority too low, fail silently (carry clear)

_start_sfx:
  ldx _play_voice
  lda _play_priority
  sta sfx_priority,x
  lda #0
  sta sfx_wait,x
  sta sfx_slide_on,x

  // Set pointer to SFX Slot address: (sfx_base_hi<<8) + ID * 64
  // Base is page-aligned (low byte $00), so the slot low byte passes
  // through directly and any carry rolls into the runtime base page.
  // The slot start is kept for the RESTART ($0A) loop opcode.
  ldy _play_id
  lda sfx_slot_lo,y
  sta sfx_ptr_lo_v,x
  sta sfx_start_lo_v,x
  lda sfx_slot_hi,y
  clc
  adc sfx_base_hi
  sta sfx_ptr_hi_v,x
  sta sfx_start_hi_v,x

  // Own the voice as SFX. Activate last so an IRQ slicing in mid-setup
  // never runs a half-initialized context.
  lda #03                    // sfx ownership ID
  sta voice_owner,x
  lda _play_priority
  sta voice_priority,x
  lda #1
  sta sfx_active,x
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
_play_voice:    .byte 0

// --- soundbridge_sfx_stop (AX) ---
// Silences active sound effects on all voices. Voices not running an SFX
// are left alone (a sustaining note keeps ringing).
soundbridge_sfx_stop:
  ldx #2
_sfxstop_loop:
  lda sfx_active,x
  beq _sfxstop_next
  lda #0
  sta sfx_active,x
  sta sfx_wait,x
  sta sfx_priority,x
  sta sfx_slide_on,x
  sta voice_owner,x
  sta voice_priority,x
  ldy voice_offsets,x
  lda sid_shadow+4,y
  and #$fe                    // Gate Off
  sta sid_shadow+4,y
  sta $d400+4,y
_sfxstop_next:
  dex
  bpl _sfxstop_loop
  rts

// --- soundbridge_sound_stop_all (AZ) ---
// Releases all SoundBridge manual notes and halts sound effects.
soundbridge_sound_stop_all:
  lda #0
  ldx #2
!:
  sta sfx_active,x
  sta sfx_wait,x
  sta sfx_priority,x
  sta sfx_slide_on,x
  dex
  bpl !-

  ldx #0
_stop_loop:
  lda voice_offsets,x
  tay
  lda sid_shadow+4,y
  and #$fe
  sta sid_shadow+4,y
  sta $d400+4,y

  lda #1
  sta voice_released,x        // next note plays hard, no glide from here

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
// Time-slices the 3 per-voice script contexts: each active context either
// counts down its wait (applying a PITCH_SLIDE delta while it does) or has
// its parked pointer loaded into ZP and its script run until the next
// WAIT/END, then the pointer is parked again.
sfx_update:
  lda #0
  sta sfx_cur_voice
_sfx_ctx_loop:
  ldx sfx_cur_voice
  lda sfx_active,x
  beq _sfx_ctx_next

  lda sfx_wait,x
  beq _sfx_ctx_run

  // Waiting: apply an active pitch slide, then count down.
  lda sfx_slide_on,x
  beq _sfx_wait_dec
  ldy voice_offsets,x
  lda sid_shadow+0,y
  clc
  adc sfx_slide_dlo,x
  sta sid_shadow+0,y
  sta $d400+0,y
  lda sid_shadow+1,y
  adc sfx_slide_dhi,x
  sta sid_shadow+1,y
  sta $d400+1,y
_sfx_wait_dec:
  dec sfx_wait,x
  bne _sfx_ctx_next
  lda #0
  sta sfx_slide_on,x          // Slide spans exactly its frame count
  jmp _sfx_ctx_next

_sfx_ctx_run:
  lda voice_offsets,x
  sta sfx_cur_off
  lda sfx_ptr_lo_v,x
  sta sfx_ptr_lo
  lda sfx_ptr_hi_v,x
  sta sfx_ptr_hi
  jsr _sfx_run_script
  ldx sfx_cur_voice
  lda sfx_ptr_lo
  sta sfx_ptr_lo_v,x
  lda sfx_ptr_hi
  sta sfx_ptr_hi_v,x

_sfx_ctx_next:
  inc sfx_cur_voice
  lda sfx_cur_voice
  cmp #3
  bcc _sfx_ctx_loop
  rts

// Runs the current context's script until WAIT/END/invalid. sfx_cur_voice
// and sfx_cur_off identify the context; ZP sfx_ptr is its script pointer.
_sfx_run_script:
_interpreter_loop:
  jsr read_sfx_byte           // Command in A

  cmp #00                     // 00 = END
  bne !+
  ldx sfx_cur_voice
  sta sfx_active,x            // Silence and terminate (A = 0)
  sta sfx_slide_on,x
  sta voice_owner,x
  sta voice_priority,x
  ldx sfx_cur_off
  lda sid_shadow+4,x
  and #$fe
  sta sid_shadow+4,x
  sta $d400+4,x
  rts

!:
  cmp #01                     // 01 = WAIT ticks
  bne !+
  jsr read_sfx_byte
  ldx sfx_cur_voice
  sta sfx_wait,x
  lda #0
  sta sfx_slide_on,x          // Plain wait holds pitch
  rts

!:
  cmp #02                     // 02 = SET_FULL FL FH PL PH AD SR CT
  bne !+
  ldx sfx_cur_off

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
  ldx sfx_cur_off
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
  ldx sfx_cur_off
  jsr read_sfx_byte
  sta $d400+4,x
  sta sid_shadow+4,x
  jmp _interpreter_loop

!:
  cmp #05                     // 05 = SET_ADSR AD SR
  bne !+
  ldx sfx_cur_off
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
  ldx sfx_cur_off
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
  ldx sfx_cur_off
  lda sid_shadow+4,x
  and #$fe
  sta sid_shadow+4,x
  sta $d400+4,x
  jmp _interpreter_loop

!:
  cmp #08                     // 08 = PITCH_SLIDE frames(>=1) deltaLo deltaHi
  bne !+
  jsr read_sfx_byte           // frames; doubles as the wait counter
  ldx sfx_cur_voice
  sta sfx_wait,x
  jsr read_sfx_byte           // signed 16-bit per-frame frequency delta
  sta sfx_slide_dlo,x
  jsr read_sfx_byte
  sta sfx_slide_dhi,x
  lda #1
  sta sfx_slide_on,x
  rts

!:
  cmp #09                     // 09 = SET_FILTER cutHi resRoute mode
  bne !+
  jsr read_sfx_byte           // cutoff high 8 bits ($D416)
  sta $d416
  sta sid_shadow+22
  jsr read_sfx_byte           // resonance + voice routing ($D417)
  sta $d417
  sta sid_shadow+23
  jsr read_sfx_byte           // filter mode bits; volume nibble preserved
  and #$f0
  sta _sfx_filt_tmp
  lda sid_shadow+24
  and #$0f
  ora _sfx_filt_tmp
  sta $d418
  sta sid_shadow+24
  jmp _interpreter_loop

!:
  cmp #10                     // 0A = RESTART: loop to the slot start.
  bne !+
  ldx sfx_cur_voice           // Implies a 1-frame wait so a script can
  lda #1                      // never wedge the IRQ in a tight loop.
  sta sfx_wait,x
  lda sfx_start_lo_v,x
  sta sfx_ptr_lo
  lda sfx_start_hi_v,x
  sta sfx_ptr_hi
  rts

!:
  // Safe Fallback: End script on invalid bytecodes
  lda #0
  ldx sfx_cur_voice
  sta sfx_active,x
  sta sfx_slide_on,x
  rts
_sfx_filt_tmp: .byte 0

// ============================================================================
// soundbridge_effects_update
// Ticks local note modulation effects once per frame inside KERNAL jiffy IRQ.
// ============================================================================
soundbridge_effects_update:
  lda #0
  sta _effects_voice
_voice_loop:
  ldx _effects_voice

  // Pulse LFO runs in its own slot, concurrently with any pitch effect
  lda pwm_speed,x
  ora pwm_depth,x
  beq !+
  jsr _update_pwm
  ldx _effects_voice
!:

  lda effect_type,x
  beq _fx_next_voice             // No pitch effect on this voice

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
  cmp #04
  bne _fx_next_voice
  jsr _update_arp

_fx_next_voice:
  inc _effects_voice
  lda _effects_voice
  cmp #3
  bcc _voice_loop
  rts

// --- Shared triangle-LFO core ---
// In: _lfo_phase/_lfo_speed/_lfo_depth. Advances the phase and returns the
// signed 16-bit excursion (depth scaled 1x-4x by the triangle table) in
// _lfo_dlo/_lfo_dhi; caller stores the phase back and applies the delta.
_lfo_step:
  lda _lfo_phase
  clc
  adc _lfo_speed
  sta _lfo_phase
  lsr
  lsr
  lsr
  lsr
  tay
  lda vibrato_table,y
  sta _offset_raw

  lda #0
  sta _lfo_dlo
  sta _lfo_dhi

  lda _offset_raw
  beq _lfo_done
  bpl !+
  eor #$ff
  clc
  adc #1
!:
  tay                            // |table| = 1..4: delta = depth * |table|
_lfo_scale:
  lda _lfo_dlo
  clc
  adc _lfo_depth
  sta _lfo_dlo
  bcc !+
  inc _lfo_dhi
!:
  dey
  bne _lfo_scale

  lda _offset_raw
  bpl _lfo_done
  lda #0                         // Negate 16-bit for the falling half
  sec
  sbc _lfo_dlo
  sta _lfo_dlo
  lda #0
  sbc _lfo_dhi
  sta _lfo_dhi
_lfo_done:
  rts

// --- Local Vibrato Update (pitch LFO around base_freq) ---
_update_vibrato:
  ldx _effects_voice
  lda effect_phase,x
  sta _lfo_phase
  lda effect_speed,x
  sta _lfo_speed
  lda effect_depth,x
  sta _lfo_depth
  jsr _lfo_step
  lda _lfo_phase
  sta effect_phase,x

  lda base_freq_lo,x
  clc
  adc _lfo_dlo
  sta _current_freq_lo
  lda base_freq_hi,x
  adc _lfo_dhi
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

// --- Local Pulse-Width Modulation Update (pulse LFO around base_pw) ---
// Runs from its own pwm_* slot so it can layer under any pitch effect.
// The sweep clamps to the audible $0080-$0F80 duty range.
_update_pwm:
  ldx _effects_voice
  lda pwm_phase,x
  sta _lfo_phase
  lda pwm_speed,x
  sta _lfo_speed
  lda pwm_depth,x
  sta _lfo_depth
  jsr _lfo_step
  lda _lfo_phase
  sta pwm_phase,x

  lda base_pw_lo,x
  clc
  adc _lfo_dlo
  sta _current_pw_lo
  lda base_pw_hi,x
  adc _lfo_dhi
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
// Classic SID "chord" arpeggio: rapidly cycles the voice through three chord
// tones, one per step, so the ear fuses them into a chord on one voice.
//
//   effect_speed = hold frames per tone (0 = change every frame = fast buzz)
//   effect_depth = $xy semitone offsets: tone 2 = root + x, tone 3 = root + y
//                  (set_effect maps legacy 0 -> $47 major, 1 -> $37 minor)
//   effect_phase = per-voice hold countdown (reused)
//   arp_step     = current tone index (0 = root)
//
// Tones come straight from the note table via the voice's tracked note index,
// so every chord tone is in perfect equal temperament. Offsets that would run
// past B-7 drop an octave. If the voice's pitch was set by raw frequency and
// no index is known, the arp degrades to re-striking the root.
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

  lda voice_note_idx,x
  beq _arp_no_index
  sta _arp_root

  ldy arp_step,x
  lda #0                       // tone 0: offset 0 (root)
  cpy #0
  beq _arp_off_ready
  lda effect_depth,x
  cpy #2
  beq !+
  lsr                          // tone 1: high nibble
  lsr
  lsr
  lsr
  jmp _arp_off_ready
!:
  and #$0f                     // tone 2: low nibble
_arp_off_ready:
  clc
  adc _arp_root
  cmp #96
  bcc !+
  sec
  sbc #12                      // past B-7: drop the tone an octave
!:
  tay
  lda note_freq_lo,y
  sta _arp_freq_lo
  lda note_freq_hi,y
  sta _arp_freq_hi
  jmp _arp_write

_arp_no_index:
  lda base_freq_lo,x
  sta _arp_freq_lo
  lda base_freq_hi,x
  sta _arp_freq_hi

_arp_write:
  ldy voice_offsets,x
  lda _arp_freq_lo
  sta $d400+0,y
  sta sid_shadow+0,y
  lda _arp_freq_hi
  sta $d400+1,y
  sta sid_shadow+1,y

  // Advance tone index (wrap 0..2)
  inc arp_step,x
  lda arp_step,x
  cmp #3
  bcc _arp_done
  lda #0
  sta arp_step,x
_arp_done:
  rts
_arp_root: .byte 0

// --- Local Effects Variables ---
_effects_voice:   .byte 0
_offset_raw:      .byte 0

_lfo_phase:       .byte 0
_lfo_speed:       .byte 0
_lfo_depth:       .byte 0
_lfo_dlo:         .byte 0
_lfo_dhi:         .byte 0

_current_freq_lo: .byte 0
_current_freq_hi: .byte 0

_slide_lo:        .byte 0
_slide_hi:        .byte 0

_current_pw_lo:   .byte 0
_current_pw_hi:   .byte 0

_arp_freq_lo:     .byte 0
_arp_freq_hi:     .byte 0
