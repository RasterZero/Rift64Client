// ============================================================================
// tracker.asm -- AudioBridge pattern sequencer (local + remote tracker)
// ============================================================================
//
// One row decoder, two feeds:
//   LOCAL  (state 1): song data compiled by the server SDK, uploaded into
//          the $4000+ zone with the checked memory store, bound with A5 and
//          played with A1. Sequenced entirely client-side from the jiffy
//          IRQ -- immune to network jitter, zero bandwidth while playing.
//   REMOTE (state 3): rows streamed live by the server (AU) into a small
//          ring buffer, consumed at row rate by the same decoder. If the
//          ring runs dry the engine holds (sustaining voices keep ringing,
//          nothing retriggers) and counts an underrun observable via AY.
//
// Rows drive the SoundBridge synth (soundbridge_note_on / _note_off /
// _sfx_play), so tracker notes get instruments, effects and drums through
// exactly the same paths the host's direct commands use.
//
// Song binary format (all offsets from the bound base address):
//   +0   speed          frames per row (1..31)
//   +1   orderCount     number of orderlist entries (1..64)
//   +2   loopOrder      order index to restart at after the last entry
//   +3   rowsPerPattern fixed for the whole song (e.g. 16, 32 or 64)
//   +4   orderlist      64 bytes: pattern indices (0..31)
//   +68  patternPtrLo   32 bytes: pattern start addresses, ABSOLUTE,
//   +100 patternPtrHi   32 bytes:   baked by the SDK song compiler
//   +132 pattern data   rowsPerPattern rows of 6 bytes each per pattern
//
// Row format (6 bytes): v0 note, v0 inst, v1 note, v1 inst, v2 note, v2 inst
//   note: $00 = no event; $01..$5F = note index (see freq tables below);
//         $60 = note off. When inst bit 7 is set the note byte is instead
//         an SFX trigger: $01..$10 = drum/SFX slot 0..15 on this voice.
//   inst: bits 0-4 = instrument id 1..16, 0 = reuse the voice's previous
//         instrument; bit 7 = SFX trigger; bits 5-6 reserved.

// --- ZP (range freed by the removed MiniPlayer2, which owned $20-$36) ---
.const trk_row_ptr = $20      // current row address during local playback
.const trk_tmp_ptr = $22      // transient song-header pointer

.const TRK_RING_FRAMES = 32   // remote ring capacity in 6-byte row frames

// --- State ---
tracker_state:      .byte 0   // 0=stopped, 1=playing local, 3=remote
trk_paused:         .byte 0
trk_bound:          .byte 0
trk_song_lo:        .byte 0
trk_song_hi:        .byte 0
trk_speed:          .byte 6
trk_tick:           .byte 1
trk_order:          .byte 0
trk_row:            .byte 0   // also counts streamed rows in remote mode
trk_order_count:    .byte 0
trk_loop_order:     .byte 0
trk_rows_per_patt:  .byte 0
trk_jump_pending:   .byte 0
trk_jump_target:    .byte 0
trk_pending:        .byte 0   // a prefetched row sits in trk_row_buf
trk_last_inst:      .byte 0, 0, 0

// Remote ring. trk_ring_count is the only cross-context variable: the
// foreground feed bumps it with inc (after the frame bytes are in place)
// and the IRQ consumer drops it with dec -- both atomic on the 6502.
trk_ring_head:      .byte 0
trk_ring_tail:      .byte 0
trk_ring_count:     .byte 0
trk_underruns:      .byte 0   // clamped at 15 (AY packs both in one byte)
trk_overruns:       .byte 0   // clamped at 15

// Per-instrument auto effects (AC command): 16 x [type, speed, depth],
// re-applied by the decoder on every note-on with that instrument.
trk_inst_fx:        .fill 48, 0

trk_row_buf:        .fill 6, 0
trk_args_save:      .fill 8, 0
trk_ring:           .fill TRK_RING_FRAMES * 6, 0

// ============================================================================
// Transport (called from the audio.asm protocol handlers; carry = error)
// ============================================================================

tracker_stop:
  lda #0
  sta tracker_state
  sta trk_paused
  sta trk_jump_pending
  sta trk_pending
  sta trk_ring_head
  sta trk_ring_tail
  sta trk_ring_count
  jmp soundbridge_sound_stop_all

tracker_pause:
  lda #1
  sta trk_paused
  rts

tracker_resume:
  lda tracker_state
  beq _trkres_err
  lda #0
  sta trk_paused
  clc
  rts
_trkres_err:
  sec
  rts

// temp_args+0 = frames per row (1..31)
tracker_set_speed:
  lda temp_args+0
  beq _trksp_err
  cmp #32
  bcs _trksp_err
  sta trk_speed
  clc
  rts
_trksp_err:
  sec
  rts

// temp_args+0/1 = song base lo/hi. Stops playback and caches the header.
tracker_bind:
  lda temp_args+1
  cmp #$40
  bcc _trkbd_err              // must live in the server upload zone
  jsr tracker_stop
  lda #0
  sta trk_bound               // invalid until the header reads clean
  lda temp_args+0
  sta trk_song_lo
  sta trk_tmp_ptr
  lda temp_args+1
  sta trk_song_hi
  sta trk_tmp_ptr+1
  ldy #0
  lda (trk_tmp_ptr),y         // +0 speed
  bne !+
  lda #6                      // tolerate 0: default speed
!:
  cmp #32
  bcc !+
  lda #31
!:
  sta trk_speed
  iny
  lda (trk_tmp_ptr),y         // +1 orderCount
  beq _trkbd_err
  sta trk_order_count
  iny
  lda (trk_tmp_ptr),y         // +2 loopOrder
  sta trk_loop_order
  iny
  lda (trk_tmp_ptr),y         // +3 rowsPerPattern
  beq _trkbd_err
  sta trk_rows_per_patt
  lda #1
  sta trk_bound
  clc
  rts
_trkbd_err:
  sec
  rts

// temp_args+0 = orderlist start index (0-based)
tracker_play:
  lda trk_bound
  beq _trkpl_err
  lda temp_args+0
  cmp trk_order_count
  bcs _trkpl_err
  pha
  lda #0
  sta tracker_state           // halt the IRQ consumer while repositioning
  sta trk_paused
  sta trk_jump_pending
  sta trk_pending
  pla
  sta trk_order
  jsr trk_load_order
  lda #1
  sta trk_tick                // first row fires on the next jiffy
  sta tracker_state
  clc
  rts
_trkpl_err:
  sec
  rts

// temp_args+0 = orderlist index; takes effect at the next row boundary
tracker_jump:
  lda tracker_state
  cmp #1
  bne _trkj_err
  lda temp_args+0
  cmp trk_order_count
  bcs _trkj_err
  sta trk_jump_target
  lda #1
  sta trk_jump_pending
  clc
  rts
_trkj_err:
  sec
  rts

// temp_args+0: 1 = enter remote (streamed-row) mode, 0 = exit (full stop)
tracker_remote_mode:
  lda temp_args+0
  beq _trkrm_exit
  cmp #1
  bne _trkrm_err
  lda #0
  sta tracker_state           // halt consumption while the ring resets
  sta trk_paused
  sta trk_pending
  sta trk_ring_head
  sta trk_ring_tail
  sta trk_ring_count
  sta trk_underruns
  sta trk_overruns
  sta trk_order
  sta trk_row
  lda #1
  sta trk_tick
  lda #3
  sta tracker_state
  clc
  rts
_trkrm_exit:
  jsr tracker_stop
  clc
  rts
_trkrm_err:
  sec
  rts

// Returns the wire state byte in A: 0 stopped, 1 playing, 2 paused, 3 remote.
tracker_query_state:
  lda trk_paused
  beq !+
  lda #2
  rts
!:
  lda tracker_state
  rts

// temp_args: instrument id (1..16), effect type (0..4), speed, depth
tracker_set_inst_effect:
  lda temp_args+0
  beq _tie_err
  cmp #17
  bcs _tie_err
  lda temp_args+1
  cmp #6                      // types 0-5 (5 = legato slide)
  bcs _tie_err
  lda temp_args+0
  sec
  sbc #1
  sta _tie_t
  asl
  clc
  adc _tie_t                  // (id-1) * 3
  tay
  lda temp_args+1
  sta trk_inst_fx,y
  lda temp_args+2
  sta trk_inst_fx+1,y
  lda temp_args+3
  sta trk_inst_fx+2,y
  clc
  rts
_tie_err:
  sec
  rts
_tie_t: .byte 0

// Foreground feed: append the 6-byte frame in temp_args+0..5 to the ring.
// A full ring drops the frame and counts an overrun (the server is pacing
// itself wrong; AY exposes the counter so it can tell).
tracker_ring_push:
  lda trk_ring_count
  cmp #TRK_RING_FRAMES
  bcc _trpush_store
  lda trk_overruns
  cmp #15
  bcs _trpush_done
  inc trk_overruns
_trpush_done:
  rts
_trpush_store:
  lda trk_ring_head
  asl
  sta _trpush_off
  asl
  clc
  adc _trpush_off             // head * 6 (max 186, no carries)
  tax
  ldy #0
!:
  lda temp_args,y
  sta trk_ring,x
  inx
  iny
  cpy #6
  bne !-
  lda trk_ring_head
  clc
  adc #1
  and #(TRK_RING_FRAMES-1)
  sta trk_ring_head
  inc trk_ring_count          // last: the IRQ only ever sees complete frames
  rts
_trpush_off: .byte 0

// ============================================================================
// Jiffy tick (called from audio_irq)
// ============================================================================

tracker_update:
  lda tracker_state
  bne !+
  rts
!:
  lda trk_paused
  beq !+
  rts
!:
  dec trk_tick
  beq _trku_fire
  lda trk_tick
  cmp #2
  beq _trku_prefetch
  rts

  // --- 2 frames before the row fires: prefetch it and hard-restart the
  // voices that are about to get a note-on, so the SID envelope counters
  // reset and every attack lands clean and identical. Speeds 1-2 have no
  // room for this and take the direct path at fire time instead.
_trku_prefetch:
  lda trk_pending
  beq !+
  rts                         // already buffered (defensive)
!:
  jsr trk_save_args
  jsr trk_fetch_row
  bcs _trku_restore           // nothing available (remote ring dry): retry at fire
  lda #1
  sta trk_pending
  jsr trk_hard_restart
  jmp _trku_restore

_trku_fire:
  lda trk_speed
  sta trk_tick
  jsr trk_save_args
  lda trk_pending
  bne _trku_play_pending
  jsr trk_fetch_row           // direct path: speeds 1-2, first row, prefetch miss
  bcc _trku_play
  // Remote underrun at row time: hold (sustains keep ringing) and count it
  lda tracker_state
  cmp #3
  bne _trku_restore
  lda trk_underruns
  cmp #15
  bcs _trku_restore
  inc trk_underruns
  jmp _trku_restore
_trku_play_pending:
  lda #0
  sta trk_pending
_trku_play:
  jsr trk_decode_row
_trku_restore:
  ldx #7
!:
  lda trk_args_save,x
  sta temp_args,x
  dex
  bpl !-
  rts

// Row work passes args to the soundbridge entry points through temp_args,
// which a foreground protocol handler may be mid-filling when the IRQ
// fires -- saved here, restored at _trku_restore.
trk_save_args:
  ldx #7
!:
  lda temp_args,x
  sta trk_args_save,x
  dex
  bpl !-
  rts

// --- Fetch the next row into trk_row_buf and advance the song position.
// Carry set = no row available (remote ring empty); local never fails. ---
trk_fetch_row:
  lda tracker_state
  cmp #3
  beq _tfr_remote

  // A pending AJ jump replaces the position at this row boundary
  lda trk_jump_pending
  beq !+
  lda #0
  sta trk_jump_pending
  lda trk_jump_target
  sta trk_order
  jsr trk_load_order
!:
  ldy #5
!:
  lda (trk_row_ptr),y
  sta trk_row_buf,y
  dey
  bpl !-

  lda trk_row_ptr
  clc
  adc #6
  sta trk_row_ptr
  bcc !+
  inc trk_row_ptr+1
!:
  inc trk_row
  lda trk_row
  cmp trk_rows_per_patt
  bcc _tfr_ok
  inc trk_order               // pattern done: next order
  lda trk_order
  cmp trk_order_count
  bcc !+
  lda trk_loop_order          // orderlist done: restart at the loop point
  sta trk_order
!:
  jsr trk_load_order
_tfr_ok:
  clc
  rts

_tfr_remote:
  lda trk_ring_count
  beq _tfr_empty
  lda trk_ring_tail
  asl
  sta _trkrr_off
  asl
  clc
  adc _trkrr_off              // tail * 6
  tax
  ldy #0
!:
  lda trk_ring,x
  sta trk_row_buf,y
  inx
  iny
  cpy #6
  bne !-
  lda trk_ring_tail
  clc
  adc #1
  and #(TRK_RING_FRAMES-1)
  sta trk_ring_tail
  dec trk_ring_count
  inc trk_row                 // streamed-row counter for AY (wraps)
  clc
  rts
_tfr_empty:
  sec
  rts
_trkrr_off: .byte 0

// --- Hard restart: kill the envelope (ADSR=0, gate off) on every voice
// the buffered row is about to strike. Skipped for drum cells (their
// script programs the voice) and voices with a slide armed (glides and
// legato must keep their envelope running). ---
trk_hard_restart:
  ldx #0
_thr_loop:
  txa
  asl
  tay
  lda trk_row_buf,y           // note byte
  beq _thr_next               // no event
  cmp #$60
  bcs _thr_next               // note-off / invalid: nothing to restart
  lda trk_row_buf+1,y
  bmi _thr_next               // drum trigger
  lda effect_type,x
  cmp #2
  beq _thr_next               // slide armed
  lda voice_offsets,x
  tay
  lda #0
  sta $d400+5,y
  sta sid_shadow+5,y
  sta $d400+6,y
  sta sid_shadow+6,y
  lda sid_shadow+4,y
  and #$fe
  sta sid_shadow+4,y
  sta $d400+4,y
_thr_next:
  inx
  cpx #3
  bne _thr_loop
  rts

// Point trk_row_ptr at row 0 of the pattern named by orderlist[trk_order].
trk_load_order:
  lda trk_song_lo
  sta trk_tmp_ptr
  lda trk_song_hi
  sta trk_tmp_ptr+1
  lda trk_order
  clc
  adc #4                      // orderlist at +4
  tay
  lda (trk_tmp_ptr),y         // pattern index 0..31
  clc
  adc #68                     // pattern ptr lo table at +68
  tay
  lda (trk_tmp_ptr),y
  sta trk_row_ptr
  tya
  clc
  adc #32                     // hi table at +100
  tay
  lda (trk_tmp_ptr),y
  sta trk_row_ptr+1
  lda #0
  sta trk_row
  rts

// ============================================================================
// Shared row decoder -- the "tracker and remote tracker in one" core.
// Decodes the 6-byte row in trk_row_buf, driving the SoundBridge synth.
// ============================================================================
trk_decode_row:
  lda #0
  sta _tdr_voice
_tdr_loop:
  lda _tdr_voice
  asl
  tay
  lda trk_row_buf,y           // note byte
  bne !+
  jmp _tdr_next               // $00 = no event
!:
  sta _tdr_note
  lda trk_row_buf+1,y         // inst byte
  sta _tdr_inst
  bpl !+
  jmp _tdr_drum               // bit 7 = SFX/drum trigger
!:

  lda _tdr_note
  cmp #$60
  beq _tdr_noteoff
  bcs _tdr_next_far           // $61..$7F: not a note, ignore

  // --- note on (by note index, so the engine tracks semitones) ---
  lda _tdr_inst
  and #$1f
  bne !+
  ldx _tdr_voice
  lda trk_last_inst,x         // inst 0 = reuse the previous instrument
!:
  sta _tdr_res
  bne !+
  jmp _tdr_next               // no instrument ever set on this voice
!:
  ldx _tdr_voice
  sta trk_last_inst,x

  // 1) Arm the instrument's auto effect BEFORE the note so the glide
  // decision in note_on reflects THIS instrument, not the previous one
  // (a slide must not leak onto the next instrument's notes). Type 0
  // clears leftovers; a PWM auto effect must clear the pitch slot too,
  // since AE type 3 alone deliberately leaves it untouched.
  sec
  sbc #1
  sta _tdr_t
  asl
  clc
  adc _tdr_t                  // (inst-1) * 3
  tay
  lda _tdr_voice
  sta temp_args+0
  lda trk_inst_fx,y
  sta temp_args+1
  cmp #3
  bne !+
  ldx _tdr_voice
  lda #0
  sta effect_type,x
  sta slide_legato,x
!:
  lda trk_inst_fx+1,y
  sta temp_args+2
  lda trk_inst_fx+2,y
  sta temp_args+3
  jsr soundbridge_set_effect

  // 2) The note itself
  lda _tdr_voice
  sta temp_args+0
  lda _tdr_note
  sta temp_args+1
  lda _tdr_res
  sta temp_args+2
  jsr soundbridge_note_on_by_index
  jmp _tdr_next

_tdr_next_far:
  jmp _tdr_next

_tdr_noteoff:
  lda _tdr_voice
  sta temp_args+0
  jsr soundbridge_note_off
  jmp _tdr_next

_tdr_drum:
  ldx _tdr_note               // note byte $01..$10 = SFX slot 0..15
  dex
  cpx #16
  bcs _tdr_next
  stx temp_args+0
  lda #$40
  sta temp_args+1             // fixed tracker-drum priority
  lda _tdr_voice
  sta temp_args+2
  jsr soundbridge_sfx_play

_tdr_next:
  inc _tdr_voice
  lda _tdr_voice
  cmp #3
  bcs !+
  jmp _tdr_loop
!:
  rts
_tdr_voice: .byte 0
_tdr_note:  .byte 0
_tdr_inst:  .byte 0
_tdr_res:   .byte 0
_tdr_t:     .byte 0

// ============================================================================
// PAL note frequency tables
// Index 1..95 = C-0..B-7 (index 0 unused); A-4 (index 58) = 440 Hz.
// SID value = f * 2^24 / 985248 for the PAL clock.
// ============================================================================
note_freq_lo: .fill 96, round(440.0*pow(2,(i-58.0)/12.0)*16777216.0/985248.0) & $ff
note_freq_hi: .fill 96, (round(440.0*pow(2,(i-58.0)/12.0)*16777216.0/985248.0) >> 8) & $ff
