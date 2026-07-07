// animator.asm -- RIFT64 local block-copy animator.
//
// One unified primitive drives all client-side animation. Each of 16 slots,
// once started, performs ONE operation per Animator tick:
//
//     copy blockLen bytes from a running source pointer to a fixed target
//     sourcePtr += blockLen          (wrap to sourceBase on each loop)
//
// blockLen selects the behaviour:
//   1  -> single-byte write: colour/register/SID cycling, or SPRITE POINTER
//         animation (target = $xxF8+id, source = a table of sprite blocks).
//         Sprites animate by pointer only -- no per-frame bitmap copy.
//   8  -> character glyph copy: target = charsetBase + code*8, source frames
//         may live ANYWHERE in the 64K map (even outside the VIC bank), which
//         is what lets one glyph stream through more frames than the bank holds.
//   64 -> sprite-frame copy (only when frames exceed what fits resident).
//
// Tick source: hung off the audio jiffy IRQ (audio_irq), already retuned to a
// true 50 Hz PAL / 60 Hz NTSC frame rate by audio_install. No per-slot timers.
//
// Protocol command '#' (35) with three subcommands (mirrors the 'A' family):
//   #C  Configure : slot, loops, tgtLo, tgtHi, srcLo, srcHi, blockLen,
//                   totalFrames, frameDelay   (9 hex bytes) -> ACK/NAK
//   #A  Action    : action, slotMaskLo, slotMaskHi          (3 hex bytes) -> ACK
//                   Action 2 (Goto) appends a 4th hex byte: the target frame.
//   #Z  Stop-all  : (no args)                                              -> ACK
// Actions: 0 Stop, 1 Start, 2 Goto(frame), 3 Pause, 4 Resume.
//   Goto seeks the masked slots to the given frame (clamped to the last
//   frame), draws it once, and leaves them STOPPED (RUNNING+PAUSED clear,
//   CONFIGURED kept) -- the "settle on a rest pose" primitive that Start
//   (which resets to frame 0 and runs) can't express.
//
// All addresses are little-endian on the wire (low byte first), matching the
// newer D/A commands.

// --- State flags (one byte per slot) ---
.const ANIM_CONFIGURED = %00000001
.const ANIM_RUNNING    = %00000010
.const ANIM_PAUSED     = %00000100

// =====================================================================
// Protocol entry: command '#'
// =====================================================================
protocol_animator:
  jsr protocol_read_byte
  and #$7f
  cmp #'C'
  bne anim_disp_not_c
  jmp anim_cmd_configure
anim_disp_not_c:
  cmp #'A'
  bne anim_disp_not_a
  jmp anim_cmd_action
anim_disp_not_a:
  cmp #'Z'
  bne anim_disp_not_z
  jmp anim_cmd_stop_all
anim_disp_not_z:
  jmp protocol_nak              // unknown subcommand

// ---------------------------------------------------------------------
// #C Configure: read 9 hex bytes into staging, validate, then commit into
// the slot's SoA entry. Leaves the slot CONFIGURED but STOPPED; emits no
// frame until started. temp_args holds only 8 bytes, so we stage locally --
// which also gives a clean build-then-commit: the slot's RUNNING bit is
// cleared first (single store), so the IRQ tick ignores it while we write.
// ---------------------------------------------------------------------
anim_cmd_configure:
  jsr protocol_read_hex_byte
  sta anim_cfg_slot
  jsr protocol_read_hex_byte
  sta anim_cfg_loops
  jsr protocol_read_hex_byte
  sta anim_cfg_tlo
  jsr protocol_read_hex_byte
  sta anim_cfg_thi
  jsr protocol_read_hex_byte
  sta anim_cfg_slo
  jsr protocol_read_hex_byte
  sta anim_cfg_shi
  jsr protocol_read_hex_byte
  sta anim_cfg_blk
  jsr protocol_read_hex_byte
  sta anim_cfg_total
  jsr protocol_read_hex_byte
  sta anim_cfg_delay

  // --- Validate (branch-over-jmp: the reject target is out of branch range) ---
  lda anim_cfg_slot
  cmp #16
  bcc anim_cfg_slot_ok          // slot <= 15
  jmp anim_cfg_reject
anim_cfg_slot_ok:
  lda anim_cfg_blk
  bne anim_cfg_blk_ok           // blockLen != 0
  jmp anim_cfg_reject
anim_cfg_blk_ok:
  lda anim_cfg_total
  bne anim_cfg_total_ok         // totalFrames != 0
  jmp anim_cfg_reject
anim_cfg_total_ok:
  lda anim_cfg_delay
  bne anim_cfg_delay_ok         // frameDelay != 0
  jmp anim_cfg_reject
anim_cfg_delay_ok:

  // Source range: last byte = srcBase + totalFrames*blockLen - 1 must be
  // <= $FFFF, i.e. (srcBase + totalFrames*blockLen) <= $10000.
  // product = totalFrames * blockLen  (16-bit; max 255*255 = 65025).
  lda anim_cfg_total
  sta anim_mul_tmp
  lda #0
  sta anim_prod_lo
  sta anim_prod_hi
  ldx #8
anim_mul_loop:
  asl anim_prod_lo
  rol anim_prod_hi
  asl anim_mul_tmp              // multiplier MSB -> C
  bcc anim_mul_skip
  clc
  lda anim_prod_lo
  adc anim_cfg_blk
  sta anim_prod_lo
  lda anim_prod_hi
  adc #0
  sta anim_prod_hi
anim_mul_skip:
  dex
  bne anim_mul_loop

  // sum = srcBase + product (17-bit). Carry out = bit16.
  clc
  lda anim_cfg_slo
  adc anim_prod_lo
  sta anim_sum_lo
  lda anim_cfg_shi
  adc anim_prod_hi
  sta anim_sum_hi
  bcc anim_cfg_commit           // sum <= $FFFF -> in range
  // carry set: only valid if sum == exactly $10000 (low 16 bits == 0)
  lda anim_sum_lo
  ora anim_sum_hi
  beq anim_cfg_commit           // sum == $10000 -> last byte = $FFFF, in range
  jmp anim_cfg_reject           // sum > $10000 -> out of range

anim_cfg_commit:
  ldx anim_cfg_slot
  lda #0
  sta anim_flags,x              // clear (stop) first -- IRQ now ignores slot
  lda anim_cfg_tlo
  sta anim_target_lo,x
  lda anim_cfg_thi
  sta anim_target_hi,x
  lda anim_cfg_slo
  sta anim_src_base_lo,x
  sta anim_src_ptr_lo,x         // running pointer starts at base
  lda anim_cfg_shi
  sta anim_src_base_hi,x
  sta anim_src_ptr_hi,x
  lda anim_cfg_blk
  sta anim_blocklen,x
  lda anim_cfg_total
  sta anim_total,x
  lda anim_cfg_loops
  sta anim_loops,x
  lda anim_cfg_delay
  sta anim_delay,x
  lda #0
  sta anim_curframe,x
  sta anim_delayctr,x
  sta anim_loopdone,x
  lda #ANIM_CONFIGURED          // single store: configured + stopped
  sta anim_flags,x
  jmp protocol_ack

anim_cfg_reject:
  jmp protocol_nak

// ---------------------------------------------------------------------
// #A Action: apply one action to every slot whose mask bit is set.
// ---------------------------------------------------------------------
anim_cmd_action:
  jsr protocol_read_hex_byte
  sta anim_act_action
  jsr protocol_read_hex_byte
  sta anim_act_work_lo          // mask low
  jsr protocol_read_hex_byte
  sta anim_act_work_hi          // mask high
  // Goto (action 2) carries a trailing target-frame argument; every other
  // action stops at the mask, keeping the historic 3-byte wire format.
  lda anim_act_action
  cmp #2
  bne anim_act_have_args
  jsr protocol_read_hex_byte
  sta anim_act_frame
anim_act_have_args:
  ldx #0
anim_act_loop:
  lsr anim_act_work_hi          // shift 16-bit mask right; LSB (slot X) -> C
  ror anim_act_work_lo
  bcc anim_act_next
  jsr anim_apply_action         // X = slot
anim_act_next:
  inx
  cpx #16
  bne anim_act_loop
  jmp protocol_ack

// Apply anim_act_action to slot X.
anim_apply_action:
  lda anim_act_action
  beq anim_act_stop             // 0 = Stop
  cmp #1
  beq anim_act_start            // 1 = Start
  cmp #2
  beq anim_act_goto             // 2 = Goto: seek to frame, emit once, stay stopped
  cmp #3
  beq anim_act_pause            // 3 = Pause
  cmp #4
  beq anim_act_resume           // 4 = Resume
  rts                           // 5..255 reserved -> ignore

anim_act_stop:
  lda anim_flags,x
  and #%11111001                // clear RUNNING + PAUSED, keep CONFIGURED
  sta anim_flags,x
  rts

anim_act_start:
  lda anim_flags,x
  and #ANIM_CONFIGURED
  beq anim_act_start_done       // not configured -> ignore
  // Reset and emit frame 0 immediately. Guard against the IRQ tick: both
  // paths call anim_emit_slot (shared self-modified copy), so briefly mask
  // IRQ across the emit + flag commit. This is a few hundred cycles at most.
  sei
  lda #0
  sta anim_curframe,x
  sta anim_delayctr,x
  sta anim_loopdone,x
  lda anim_src_base_lo,x
  sta anim_src_ptr_lo,x
  lda anim_src_base_hi,x
  sta anim_src_ptr_hi,x
  jsr anim_emit_slot
  lda anim_flags,x
  and #%11111011                // clear PAUSED
  ora #ANIM_RUNNING             // set RUNNING
  sta anim_flags,x
  cli
anim_act_start_done:
  rts

anim_act_pause:
  lda anim_flags,x
  and #ANIM_RUNNING
  beq anim_act_pause_done       // not running -> nothing to pause
  lda anim_flags,x
  and #%11111101                // clear RUNNING
  ora #ANIM_PAUSED              // set PAUSED
  sta anim_flags,x
anim_act_pause_done:
  rts

anim_act_resume:
  lda anim_flags,x
  and #ANIM_PAUSED
  beq anim_act_resume_done      // not paused -> nothing to resume
  lda anim_flags,x
  and #%11111011                // clear PAUSED
  ora #ANIM_RUNNING             // set RUNNING
  sta anim_flags,x
anim_act_resume_done:
  rts

// Seek slot X to anim_act_frame, draw that frame once, leave it stopped.
// Requires the slot to be CONFIGURED (ignored otherwise, like Start). The
// running source pointer is repositioned to srcBase + frame*blockLen so a
// later Start/Resume is coherent, then anim_emit_slot paints the frame. The
// multiply uses Y as the bit counter so X stays = slot throughout; the emit
// shares self-modified copy code with the IRQ tick, so it runs under sei.
anim_act_goto:
  lda anim_flags,x
  and #ANIM_CONFIGURED
  bne anim_act_goto_ok
  rts                           // not configured -> ignore
anim_act_goto_ok:
  // Clamp requested frame to [0, total-1].
  lda anim_act_frame
  cmp anim_total,x
  bcc anim_act_goto_frame_ok
  lda anim_total,x
  sec
  sbc #1
anim_act_goto_frame_ok:
  sta anim_curframe,x           // land on this frame
  sta anim_mul_tmp              // multiplier copy (destroyed by the loop)
  lda #0
  sta anim_prod_lo
  sta anim_prod_hi
  ldy #8
anim_act_goto_mul:
  asl anim_prod_lo
  rol anim_prod_hi
  asl anim_mul_tmp              // multiplier MSB -> C
  bcc anim_act_goto_mul_skip
  clc
  lda anim_prod_lo
  adc anim_blocklen,x
  sta anim_prod_lo
  lda anim_prod_hi
  adc #0
  sta anim_prod_hi
anim_act_goto_mul_skip:
  dey
  bne anim_act_goto_mul
  // src_ptr = src_base + frame*blockLen (config validation keeps this <= $FFFF)
  clc
  lda anim_src_base_lo,x
  adc anim_prod_lo
  sta anim_src_ptr_lo,x
  lda anim_src_base_hi,x
  adc anim_prod_hi
  sta anim_src_ptr_hi,x
  lda #0
  sta anim_delayctr,x
  sta anim_loopdone,x
  sei
  jsr anim_emit_slot            // draw the frame (X preserved)
  lda anim_flags,x
  and #%11111001                // clear RUNNING + PAUSED, keep CONFIGURED
  sta anim_flags,x
  cli
  rts

// ---------------------------------------------------------------------
// #Z Stop-all: stop every slot, preserve visible output, keep configs.
// ---------------------------------------------------------------------
anim_cmd_stop_all:
  jsr animator_stop_all
  jmp protocol_ack

// =====================================================================
// animator_reset -- mark all slots inert. Call at boot (before the IRQ is
// hooked) and on every (re)connect so a stale running slot from a previous
// session cannot keep writing target memory.
// =====================================================================
animator_reset:
animator_stop_all_full:
  ldx #15
anim_reset_loop:
  lda #0
  sta anim_flags,x
  dex
  bpl anim_reset_loop
  rts

// animator_stop_all -- clear RUNNING/PAUSED on every slot but keep configs.
animator_stop_all:
  ldx #15
anim_stopall_loop:
  lda anim_flags,x
  and #%11111001                // clear RUNNING + PAUSED, keep CONFIGURED
  sta anim_flags,x
  dex
  bpl anim_stopall_loop
  rts

// =====================================================================
// animator_tick -- called once per frame from audio_irq (A/X/Y already
// saved by the KERNAL). Advances every running slot. Must not touch the
// socket, must return quickly, and uses no zero page (the emit copy is
// self-modifying, so it is safe against the main loop's ZP usage).
// =====================================================================
animator_tick:
  ldx #0
anim_tick_loop:
  lda anim_flags,x
  and #ANIM_RUNNING
  beq anim_tick_next            // stopped/paused/unconfigured -> skip

  inc anim_delayctr,x
  lda anim_delayctr,x
  cmp anim_delay,x
  bcc anim_tick_next            // delayCounter < frameDelay -> wait

  lda #0
  sta anim_delayctr,x
  inc anim_curframe,x
  lda anim_curframe,x
  cmp anim_total,x
  bcc anim_tick_advance         // currentFrame < totalFrames -> advance ptr

  // --- loop boundary ---
  lda anim_loops,x
  beq anim_tick_wrap            // loops == 0 -> infinite, wrap
  inc anim_loopdone,x
  lda anim_loopdone,x
  cmp anim_loops,x
  bcc anim_tick_wrap            // more loops to go -> wrap
  // all requested loops complete: stop, leave final frame visible (no emit)
  lda anim_total,x
  sec
  sbc #1
  sta anim_curframe,x           // pin to final frame (already on screen)
  lda anim_flags,x
  and #%11111101                // clear RUNNING
  sta anim_flags,x
  jmp anim_tick_next

anim_tick_wrap:
  lda #0
  sta anim_curframe,x
  lda anim_src_base_lo,x
  sta anim_src_ptr_lo,x
  lda anim_src_base_hi,x
  sta anim_src_ptr_hi,x
  jmp anim_tick_emit

anim_tick_advance:
  clc
  lda anim_src_ptr_lo,x
  adc anim_blocklen,x
  sta anim_src_ptr_lo,x
  bcc anim_tick_emit
  inc anim_src_ptr_hi,x

anim_tick_emit:
  jsr anim_emit_slot

anim_tick_next:
  inx
  cpx #16
  bne anim_tick_loop
  rts

// =====================================================================
// anim_emit_slot -- copy anim_blocklen[X] bytes from the slot's running
// source pointer to its target. Self-modifying absolute,Y addressing keeps
// it off the zero page so it is reentrancy-safe against the main loop (the
// only other caller, Start, masks IRQ around its call). X = slot, preserved.
// =====================================================================
anim_emit_slot:
  lda anim_src_ptr_lo,x
  sta anim_emit_src+1
  lda anim_src_ptr_hi,x
  sta anim_emit_src+2
  lda anim_target_lo,x
  sta anim_emit_dst+1
  lda anim_target_hi,x
  sta anim_emit_dst+2
  lda anim_blocklen,x
  sta anim_emit_len
  ldy #0
anim_emit_copy:
  cpy anim_emit_len
  bcs anim_emit_done
anim_emit_src:
  lda $ffff,y                   // operand patched above
anim_emit_dst:
  sta $ffff,y                   // operand patched above
  iny
  bne anim_emit_copy            // blockLen <= 255, so Y reaches len before wrap
anim_emit_done:
  rts

// =====================================================================
// State (structure-of-arrays, 16 slots) + configure staging.
// =====================================================================
anim_flags:       .fill 16, 0
anim_target_lo:   .fill 16, 0
anim_target_hi:   .fill 16, 0
anim_src_base_lo: .fill 16, 0
anim_src_base_hi: .fill 16, 0
anim_src_ptr_lo:  .fill 16, 0
anim_src_ptr_hi:  .fill 16, 0
anim_blocklen:    .fill 16, 0
anim_total:       .fill 16, 0
anim_curframe:    .fill 16, 0
anim_delay:       .fill 16, 0
anim_delayctr:    .fill 16, 0
anim_loops:       .fill 16, 0
anim_loopdone:    .fill 16, 0

anim_cfg_slot:   .byte 0
anim_cfg_loops:  .byte 0
anim_cfg_tlo:    .byte 0
anim_cfg_thi:    .byte 0
anim_cfg_slo:    .byte 0
anim_cfg_shi:    .byte 0
anim_cfg_blk:    .byte 0
anim_cfg_total:  .byte 0
anim_cfg_delay:  .byte 0

anim_mul_tmp:  .byte 0
anim_prod_lo:  .byte 0
anim_prod_hi:  .byte 0
anim_sum_lo:   .byte 0
anim_sum_hi:   .byte 0

anim_act_action:  .byte 0
anim_act_work_lo: .byte 0
anim_act_work_hi: .byte 0
anim_act_frame:   .byte 0

anim_emit_len: .byte 0
