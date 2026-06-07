// MiniPlayer2 -- minimal feature-limited C64 SID music player v2
// Original by Cadaver (loorni@gmail.com) 9/2021, DASM source.
// Ported to KickAssembler for RIFT64 (2026).
//
// Config (hardcoded for RIFT64):
//   PLAYER_ZPBASE = $20   // 23 consecutive ZP bytes ($20..$36)
//   PLAYER_ZPOPT  = 1     // ZP optimization enabled (faster)
//   PLAYER_SFX    = 1     // Sound effect support enabled
//   PLAYER_MODULES= 1     // Module support enabled (SetMusicData)
//
// NOTE: $c0-$d6 conflicts with KERNAL keyboard scan (SCNKEY) which
//       overwrites $c5 (LSTX), $c6 (NDX), $cb (SHFLAG) every IRQ.
//       Using $20-$36 (BASIC workspace) avoids this since BASIC is off.
//
// Call PlayRoutine once per frame. Command byte at PlayRoutine+1:
//   $00       playback ongoing
//   $01..$7f  init subtune (value = subtune number)
//   $80..$ff  silence output (e.g. during loading or SetMusicData)

// ---- Configuration ----
.const PLAYER_ZPBASE = $20

// ---- Music format constants ----
.const MUSICHEADERSIZE = 7

.const SONGJUMP    = 0
.const TRANS       = $80

.const VIBRATO     = $00
.const SLIDE       = $90
.const WAVEDELAY   = $91

.const FIX_SONGS    = $00
.const FIX_PATT     = $04
.const FIX_INS      = $08
.const FIX_WAVE     = $0c
.const FIX_WAVEADSR = $10
.const FIX_PULSE    = $14
.const FIX_FILT     = $18
.const FIX_NOADD    = $80

.const FIX_SUB1     = $01
.const FIX_SUB80    = $02
.const FIX_SUB81    = $03

.const SFX_INIT       = $00
.const SFX_END        = $00
.const SFX_FREQ       = $82
.const SFX_FIRSTSLIDE = $e0
// SFX_SLIDE = $100 (not referenced directly here)

.const ENDPATT = 0
.const INS     = $ff           // -1
.const DUR     = $100

.const C0  = 1*2+1
.const CS0 = 2*2+1
.const D0  = 3*2+1
.const DS0 = 4*2+1
.const E0  = 5*2+1
.const F0  = 6*2+1
.const FS0 = 7*2+1
.const G0  = 8*2+1
.const GS0 = 9*2+1
.const A0  = 10*2+1
.const AS0 = 11*2+1
.const H0  = 12*2+1
.const C1  = 13*2+1
.const CS1 = 14*2+1
.const D1  = 15*2+1
.const DS1 = 16*2+1
.const E1  = 17*2+1
.const F1  = 18*2+1
.const FS1 = 19*2+1
.const G1  = 20*2+1
.const GS1 = 21*2+1
.const A1  = 22*2+1
.const AS1 = 23*2+1
.const H1  = 24*2+1
.const C2  = 25*2+1
.const CS2 = 26*2+1
.const D2  = 27*2+1
.const DS2 = 28*2+1
.const E2  = 29*2+1
.const F2  = 30*2+1
.const FS2 = 31*2+1
.const G2  = 32*2+1
.const GS2 = 33*2+1
.const A2  = 34*2+1
.const AS2 = 35*2+1
.const H2  = 36*2+1
.const C3  = 37*2+1
.const CS3 = 38*2+1
.const D3  = 39*2+1
.const DS3 = 40*2+1
.const E3  = 41*2+1
.const F3  = 42*2+1
.const FS3 = 43*2+1
.const G3  = 44*2+1
.const GS3 = 45*2+1
.const A3  = 46*2+1
.const AS3 = 47*2+1
.const H3  = 48*2+1
.const C4  = 49*2+1
.const CS4 = 50*2+1
.const D4  = 51*2+1
.const DS4 = 52*2+1
.const E4  = 53*2+1
.const F4  = 54*2+1
.const FS4 = 55*2+1
.const G4  = 56*2+1
.const GS4 = 57*2+1
.const A4  = 58*2+1
.const AS4 = 59*2+1
.const H4  = 60*2+1
.const REST    = $7a
.const WAVEPOS = $7b
.const SETWAVE = $7c
.const SETAD   = $7d
.const SETSR   = $7e

// ---- Zeropage variables (PLAYER_ZPBASE..PLAYER_ZPBASE+8) ----
.const pattPtrLo    = PLAYER_ZPBASE
.const pattPtrHi    = PLAYER_ZPBASE+1

// PLAYER_ZPOPT > 0: channel vars also in ZP (chnXxx,x with x=0/7/14)
.const zpChannelVars = PLAYER_ZPBASE+2
.const chnCounter   = zpChannelVars+0
.const chnPattPtrLo = zpChannelVars+1
.const chnPattPtrHi = zpChannelVars+2
.const chnSongPos   = zpChannelVars+3
.const chnDuration  = zpChannelVars+4
.const chnWavePos   = zpChannelVars+5
.const chnWaveTime  = zpChannelVars+6

// PLAYER_SFX > 0 aliases (share storage with wave vars during SFX)
.const chnSfxPtrLo  = chnWavePos
.const chnSfxTime   = chnWaveTime

// ---- SetMusicData -----------------------------------------------
// Set new music module to play. Address must be page-aligned.
// PlayRoutine should be disabled (negative value in PlayRoutine+1)
// during call.
// Params: A,X = address low,high
SetMusicData:
  sta SetMusicData_HeaderLda+1
  clc
  adc #MUSICHEADERSIZE
  sta chnPattPtrLo
  stx SetMusicData_HeaderLda+2
  txa
  adc #$00
  sta chnPattPtrHi
  ldx #$00
SetMusicData_FixupLoop:
  lda fixupDestHiTbl,x
  beq SetMusicData_FixupDone
  sta pattPtrHi
  lda fixupDestLoTbl,x
  sta pattPtrLo
  lda fixupTypeTbl,x
  pha
  bmi SetMusicData_AddDone        // FIX_NOADD set: skip header-byte add
  lsr
  lsr                              // type>>2 = module header index (0..6)
  tay
SetMusicData_HeaderLda:
  lda dummyData,y                  // operand patched to lda module_base,y
  clc
  adc chnPattPtrLo
  sta chnPattPtrLo
  bcc SetMusicData_AddDone
  inc chnPattPtrHi
SetMusicData_AddDone:
  pla
  and #$03                         // sub-index into fixupSubTbl
  tay
  lda chnPattPtrLo
  sec
  sbc fixupSubTbl,y
  ldy #$01
  sta (pattPtrLo),y                // patch operand low byte of destination LDA
  iny
  lda chnPattPtrHi
  sbc #$00
  sta (pattPtrLo),y                // patch operand high byte of destination LDA
  inx
  bne SetMusicData_FixupLoop
SetMusicData_FixupDone:
  sta pattPtrLo                    // A=0 (terminator); clear ZP base for (pattPtrLo),y
  rts

// ---- Play_SilenceSID ----
// Silence all three SID voices (writes $00 to $d404/$d40b/$d412).
Play_SilenceSID:
  lda #$00
  sta $d404
  sta $d404+7
  sta $d404+14
  rts

Play_InitOrStop:
  bmi Play_SilenceSID             // command byte $80..$ff -> silence
Play_DoInit:
  dex
  txa
  sta pattPtrHi
  asl
  asl
  adc pattPtrHi
  tay
Play_SongTblAccess1:
  lda songTbl,y                   // operand fixed up by SetMusicData
  iny
  sta Play_SongAccess1+1
  sta Play_SongAccess2+1
  sta Play_SongAccess3+1
  adc #$01
  sta Play_SongP1Access1+1
Play_SongTblAccess2:
  lda songTbl,y                   // operand fixed up by SetMusicData
  iny
  sta Play_SongAccess1+2
  sta Play_SongAccess2+2
  sta Play_SongAccess3+2
  adc #$00
  sta Play_SongP1Access1+2
  lda #$0f
  sta $d418
  ldx #$00
  stx PlayRoutine+1
  stx $d415
  stx $d417
  stx Play_FiltPos+1
  jsr Play_InitChn
  ldx #$07
  jsr Play_InitChn
  ldx #$0e
Play_InitChn:
  lda #$00
  cmp chnSfxPtrHi,x               // if sound ongoing, skip wave init
  bne Play_InitChnSkipWave
  sta $d406,x
  sta $d404,x                     // full HR for slow-attack notes
Play_InitChnSkipWave:
  sta chnWavePos,x
  sta chnPulsePos,x
  sta chnCounter,x
Play_SongTblAccess3:
  lda songTbl,y                   // operand fixed up by SetMusicData
  iny
  sta chnSongPos,x
  lda #<(PlayRoutine+1)           // a guaranteed-zero location
  sta chnPattPtrLo,x              // to trigger first pattern fetch
  lda #>(PlayRoutine+1)
  sta chnPattPtrHi,x
  rts

// ---- PlayRoutine ----
// Call once per frame. PlayRoutine+1 = command byte (see header).
PlayRoutine:
  ldx #$01                        // <- $a2 $01 ; $01 is the command byte
  bne Play_InitOrStop
Play_FiltPos:
  ldy #$00                        // immediate operand modified at runtime
  beq Play_FiltDone
  bmi Play_FiltInit
Play_FiltCutoff:
  lda #$00                        // immediate operand modified at runtime
Play_FiltLimitM1Access1:
  cmp filtLimitTbl-1,y            // operand fixed up by SetMusicData
  beq Play_FiltNext
  clc
Play_FiltSpdM1Access1:
  adc filtSpdTbl-1,y              // operand fixed up by SetMusicData
Play_StoreCutoff:
  sta Play_FiltCutoff+1
  sta $d416

Play_FiltDone:
  jsr Play_ChnExec
  ldx #$07
  jsr Play_ChnExec
  ldx #$0e
  jmp Play_ChnExec

Play_FiltSpdM81Access1:
Play_FiltInit:
  lda filtSpdTbl-$81,y            // operand fixed up by SetMusicData
  sta $d417
  and #$70
  ora #$0f
  sta $d418
Play_FiltNextM81Access1:
  lda filtNextTbl-$81,y           // operand fixed up by SetMusicData
  sta Play_FiltPos+1
Play_FiltLimitM81Access1:
  lda filtLimitTbl-$81,y          // operand fixed up by SetMusicData
  jmp Play_StoreCutoff

Play_FiltNextM1Access1:
Play_FiltNext:
  lda filtNextTbl-1,y             // operand fixed up by SetMusicData
  sta Play_FiltPos+1
  bcs Play_FiltDone               // C=1 here

Play_DoSequencer:
  ldy chnSongPos,x
Play_SongAccess1:
  lda songTbl,y                   // operand fixed up by SetMusicData
  bne Play_NoSongJump
Play_SongP1Access1:
  lda songTbl+1,y                 // operand fixed up by SetMusicData
  tay
Play_SongAccess2:
  lda songTbl,y                   // operand fixed up by SetMusicData
Play_NoSongJump:
  bpl Play_NoTrans
  asl
  sta chnTrans,x
  iny
Play_SongAccess3:
  lda songTbl,y                   // operand fixed up by SetMusicData
Play_NoTrans:
  iny
  sty chnSongPos,x
  tay
Play_PattTblLoM1Access1:
  lda pattTblLo-1,y               // operand fixed up by SetMusicData
  sta chnPattPtrLo,x
Play_PattTblHiM1Access1:
  lda pattTblHi-1,y               // operand fixed up by SetMusicData
  sta chnPattPtrHi,x
  lda chnSfxPtrHi,x
  bne Play_JumpToSfx
  jmp Play_WaveExec
Play_JumpToSfx:
  jmp Play_SfxExec

Play_SetWavePosCmd:
  lda (pattPtrLo),y
  iny
  sty chnPattPtrLo,x
  jmp Play_NewWavePosCommon

Play_Commands:
  beq Play_Rest
  cmp #WAVEPOS
  beq Play_SetWavePosCmd
Play_SetRegCmd:
  and #$07
  sta Play_SetRegSta+1
  lda chnNote,x                   // if SFX finished on channel, skip SID
  cmp #$01                        // register writes until next real note
  lda (pattPtrLo),y
  iny
  bcc Play_Rest
Play_SetRegSta:
  sta $d400,x
Play_Rest:
  sty chnPattPtrLo,x
  jmp Play_WaveExec

Play_JumpToNewNoteSfx:
  jmp Play_NewNoteSfxExec

Play_ChnExec:
  inc chnCounter,x
  bmi Play_NoNewNotes
Play_NewNotes:
  ldy chnPattPtrLo,x
  lda chnPattPtrHi,x
  sta pattPtrHi
  lda (pattPtrLo),y
  beq Play_DoSequencer
  bmi Play_NewDur
  lda chnDuration,x
  bmi Play_DurCommon
Play_NewDur:
  iny
  sta chnDuration,x
Play_DurCommon:
  sta chnCounter,x
  lda chnSfxPtrHi,x
  bne Play_JumpToNewNoteSfx
  lda (pattPtrLo),y
  iny
  cmp #REST
  bcs Play_Commands
  adc chnTrans,x
  lsr
  sta chnNote,x
  bcs Play_NoNewIns
  lda (pattPtrLo),y
  iny
  sta chnIns,x
Play_NoNewIns:
  sty chnPattPtrLo,x
  ldy chnIns,x
  bmi Play_LegatoNoteInit
Play_InsPulsePosAccess1:
  lda insPulsePos,y               // operand fixed up by SetMusicData
  beq Play_SkipPulseInit
  sta chnPulsePos,x
Play_SkipPulseInit:
Play_InsFiltPosAccess1:
  lda insFiltPos,y                // operand fixed up by SetMusicData
  beq Play_SkipFiltInit
  sta Play_FiltPos+1
Play_SkipFiltInit:
  lda #$0f
  sta $d406,x
  lda #$08
  sta $d404,x
Play_InsADAccess1:
  lda insAD,y                     // operand fixed up by SetMusicData
  sta $d405,x
Play_InsWavePosAccess1:
  lda insWavePos,y                // operand fixed up by SetMusicData
Play_NewWavePosCommon:
  sta chnWavePos,x
Play_NewWavePosCommon2:
  lda #$00
  sta chnWaveTime,x
Play_WaveDone:
  rts

Play_LegatoNoteInit:
Play_InsWavePosM80Access1:
  lda insWavePos-$80,y            // operand fixed up by SetMusicData
  bne Play_NewWavePosCommon

Play_NoNewNotesJumpToSfx:
  jmp Play_SfxExec

Play_NoNewNotes:
  lda chnSfxPtrHi,x
  bne Play_NoNewNotesJumpToSfx
Play_PulseExec:
  ldy chnPulsePos,x
  bmi Play_PulseInit
  beq Play_WaveExec
Play_PulseMod:
  lda chnPulse,x
Play_PulseLimitM1Access1:
  cmp pulseLimitTbl-1,y           // operand fixed up by SetMusicData
  beq Play_PulseNext
  clc
Play_PulseSpdM1Access1:
  adc pulseSpdTbl-1,y             // operand fixed up by SetMusicData
  adc #$00
Play_StorePulse:
  sta chnPulse,x
  sta $d402,x
  sta $d403,x
Play_WaveExec:
  ldy chnWavePos,x
  beq Play_WaveDone
Play_WaveM1Access1:
  lda waveTbl-1,y                 // operand fixed up by SetMusicData
  beq Play_Vibrato
  cmp #SLIDE
  bcs Play_SlideOrDelay
Play_WaveChange:
  sta $d404,x
Play_WaveSRM1Access1:
  lda waveSRTbl-1,y               // operand fixed up by SetMusicData
  beq Play_SkipADSR
  sta $d406,x
Play_SkipADSR:
Play_NoWaveChange:
Play_WaveNextM1Access1:
  lda waveNextTbl-1,y             // operand fixed up by SetMusicData
  sta chnWavePos,x
Play_NoteM1Access1:
  lda noteTbl-1,y                 // operand fixed up by SetMusicData
  bmi Play_WaveStepAbsNote
Play_WaveStepRelNote:
  clc
  adc chnNote,x
Play_WaveStepAbsNote:
  asl
  tay
  lda freqTbl-2,y
  sta chnFreqLo,x
  sta $d400,x
  lda freqTbl-1,y
Play_StoreFreqHi:
  sta chnFreqHi,x
  sta $d401,x
  rts

Play_PulseNextM81Access1:
Play_PulseInit:
  lda pulseNextTbl-$81,y          // operand fixed up by SetMusicData
  sta chnPulsePos,x
Play_PulseLimitM81Access1:
  lda pulseLimitTbl-$81,y         // operand fixed up by SetMusicData
  jmp Play_StorePulse

Play_PulseNextM1Access1:
Play_PulseNext:
  lda pulseNextTbl-1,y            // operand fixed up by SetMusicData
  sta chnPulsePos,x
  bcs Play_WaveExec

Play_SlideOrDelay:
  beq Play_Slide
Play_WaveDelay:
  adc chnWaveTime,x
  bne Play_WaveDelayNotOver
  sta chnWaveTime,x
  beq Play_NoWaveChange
Play_WaveDelayNotOver:
  inc chnWaveTime,x
Play_VibDone:
  rts

Play_Vibrato:
  lda chnWaveTime,x
  bpl Play_VibNoDir
Play_NoteM1Access2:
  cmp noteTbl-1,y                 // operand fixed up by SetMusicData
  bcs Play_VibNoDir2
  eor #$ff
Play_VibNoDir:
  sec
Play_VibNoDir2:
  sbc #$02
  sta chnWaveTime,x
  lsr
  lda chnFreqLo,x
  bcs Play_VibDown
Play_WaveNextM1Access2:
Play_VibUp:
  adc waveNextTbl-1,y             // operand fixed up by SetMusicData
  sta chnFreqLo,x
  sta $d400,x
  bcc Play_VibDone
  lda chnFreqHi,x
  adc #$00
  jmp Play_StoreFreqHi
Play_WaveNextM1Access3:
Play_VibDown:
  sbc waveNextTbl-1,y             // operand fixed up by SetMusicData
  sta chnFreqLo,x
  sta $d400,x
  bcs Play_VibDone
  lda chnFreqHi,x
  sbc #$00
  jmp Play_StoreFreqHi

Play_Slide:
  lda chnFreqLo,x
Play_NoteM1Access3:
  adc noteTbl-1,y                 // speed-1, since C=1 here
  sta chnFreqLo,x
  sta $d400,x
  lda chnFreqHi,x
Play_WaveNextM1Access4:
  adc waveNextTbl-1,y             // operand fixed up by SetMusicData
  jmp Play_StoreFreqHi

// ---- SFX ----
Play_NewNoteSfxExec:
  lda (pattPtrLo),y               // fetch notes/ins but don't change SID
  iny
  cmp #REST
  beq Play_NewNoteSfxRest
  bcs Play_NewNoteSfxCommand
  lsr
  bcs Play_NewNoteSfxRest
  lda (pattPtrLo),y
  sta chnIns,x
Play_NewNoteSfxCommand:
  iny
Play_NewNoteSfxRest:
  sty chnPattPtrLo,x
  lda chnSfxPtrHi,x
Play_SfxExec:
  sta pattPtrHi
  ldy chnSfxPtrLo,x
  lda (pattPtrLo),y
  beq Play_SfxEnd
  cmp #$10
  bcc Play_SfxInit
  cmp #SFX_FREQ
  bcs Play_SfxFreqOrSlide
  iny
  sta $d404,x
  lda chnSfxSR,x
  sta $d406,x
  lda (pattPtrLo),y
  cmp #SFX_FREQ
  bcc Play_SfxStepDone
  sty chnSfxPtrLo,x
Play_SfxFreqOrSlide:
  cmp #SFX_FIRSTSLIDE
  bcs Play_SfxSlide
Play_SfxFreq:
  iny
  sty chnSfxPtrLo,x
  sbc #SFX_FREQ-2
  jmp Play_WaveStepAbsNote
Play_SfxSlide:
  iny
  dec chnSfxTime,x
  sbc chnSfxTime,x
  bcc Play_SfxSlideNotDone
  sta chnSfxTime,x
  tya
  adc #$01-1                      // C=1, becomes 0
  sta chnSfxPtrLo,x
Play_SfxSlideNotDone:
  lda (pattPtrLo),y
  beq Play_SfxSlideNoOp
  tay
  lda chnFreqLo,x
  adc sfxSlideTblLo-1,y
  sta chnFreqLo,x
  sta $d400,x
  lda chnFreqHi,x
  adc sfxSlideTblHi-1,y
  jmp Play_StoreFreqHi

Play_SfxEnd:
  sta chnNote,x
  sta chnWavePos,x
  sta chnPulsePos,x
  sta chnSfxPtrHi,x
Play_SfxSlideNoOp:
  rts

Play_SfxInit:
  sta $d402,x
  sta $d403,x
  lda #$08
  sta $d404,x
  lda #$0f
  sta $d406,x
  iny
  lda (pattPtrLo),y
  iny
  sta $d405,x
  lda (pattPtrLo),y
  iny
  sta chnSfxSR,x
  lda #$00
  sta chnSfxTime,x
Play_SfxStepDone:
  sty chnSfxPtrLo,x
  rts

// ---- SetMusicData fixup tables ----
fixupSubTbl:
  .byte 0, 1, $80, $81

fixupDestLoTbl:
  .byte <Play_SongTblAccess1
  .byte <Play_SongTblAccess2
  .byte <Play_SongTblAccess3
  .byte <Play_PattTblLoM1Access1
  .byte <Play_PattTblHiM1Access1
  .byte <Play_InsADAccess1
  .byte <Play_InsWavePosAccess1
  .byte <Play_InsWavePosM80Access1
  .byte <Play_InsPulsePosAccess1
  .byte <Play_InsFiltPosAccess1
  .byte <Play_WaveM1Access1
  .byte <Play_NoteM1Access1
  .byte <Play_NoteM1Access2
  .byte <Play_NoteM1Access3
  .byte <Play_WaveNextM1Access1
  .byte <Play_WaveNextM1Access2
  .byte <Play_WaveNextM1Access3
  .byte <Play_WaveNextM1Access4
  .byte <Play_WaveSRM1Access1
  .byte <Play_PulseLimitM1Access1
  .byte <Play_PulseLimitM81Access1
  .byte <Play_PulseSpdM1Access1
  .byte <Play_PulseNextM1Access1
  .byte <Play_PulseNextM81Access1
  .byte <Play_FiltLimitM1Access1
  .byte <Play_FiltLimitM81Access1
  .byte <Play_FiltSpdM1Access1
  .byte <Play_FiltSpdM81Access1
  .byte <Play_FiltNextM1Access1
  .byte <Play_FiltNextM81Access1

fixupDestHiTbl:
  .byte >Play_SongTblAccess1
  .byte >Play_SongTblAccess2
  .byte >Play_SongTblAccess3
  .byte >Play_PattTblLoM1Access1
  .byte >Play_PattTblHiM1Access1
  .byte >Play_InsADAccess1
  .byte >Play_InsWavePosAccess1
  .byte >Play_InsWavePosM80Access1
  .byte >Play_InsPulsePosAccess1
  .byte >Play_InsFiltPosAccess1
  .byte >Play_WaveM1Access1
  .byte >Play_NoteM1Access1
  .byte >Play_NoteM1Access2
  .byte >Play_NoteM1Access3
  .byte >Play_WaveNextM1Access1
  .byte >Play_WaveNextM1Access2
  .byte >Play_WaveNextM1Access3
  .byte >Play_WaveNextM1Access4
  .byte >Play_WaveSRM1Access1
  .byte >Play_PulseLimitM1Access1
  .byte >Play_PulseLimitM81Access1
  .byte >Play_PulseSpdM1Access1
  .byte >Play_PulseNextM1Access1
  .byte >Play_PulseNextM81Access1
  .byte >Play_FiltLimitM1Access1
  .byte >Play_FiltLimitM81Access1
  .byte >Play_FiltSpdM1Access1
  .byte >Play_FiltSpdM81Access1
  .byte >Play_FiltNextM1Access1
  .byte >Play_FiltNextM81Access1
  .byte 0                          // terminator

fixupTypeTbl:
  .byte FIX_NOADD
  .byte FIX_NOADD
  .byte FIX_NOADD
  .byte FIX_SONGS    | FIX_SUB1
  .byte FIX_PATT     | FIX_SUB1
  .byte FIX_PATT
  .byte FIX_INS
  .byte FIX_NOADD    | FIX_SUB80
  .byte FIX_INS
  .byte FIX_INS
  .byte FIX_INS      | FIX_SUB1
  .byte FIX_WAVE     | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB1
  .byte FIX_WAVE     | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB1
  .byte FIX_WAVE     | FIX_SUB1
  .byte FIX_WAVEADSR | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB81
  .byte FIX_PULSE    | FIX_SUB1
  .byte FIX_PULSE    | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB81
  .byte FIX_PULSE    | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB81
  .byte FIX_FILT     | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB81
  .byte FIX_FILT     | FIX_SUB1
  .byte FIX_NOADD    | FIX_SUB81

// ---- Frequency table (PAL) ----
freqTbl:
  .word $022d,$024e,$0271,$0296,$02be,$02e8,$0314,$0343,$0374,$03a9,$03e1,$041c
  .word $045a,$049c,$04e2,$052d,$057c,$05cf,$0628,$0685,$06e8,$0752,$07c1,$0837
  .word $08b4,$0939,$09c5,$0a5a,$0af7,$0b9e,$0c4f,$0d0a,$0dd1,$0ea3,$0f82,$106e
  .word $1168,$1271,$138a,$14b3,$15ee,$173c,$189e,$1a15,$1ba2,$1d46,$1f04,$20dc
  .word $22d0,$24e2,$2714,$2967,$2bdd,$2e79,$313c,$3429,$3744,$3a8d,$3e08,$41b8
  .word $45a1,$49c5,$4e28,$52cd,$57ba,$5cf1,$6278,$6853,$6e87,$751a,$7c10,$8371
  .word $8b42,$9389,$9c4f,$a59b,$af74,$b9e2,$c4f0,$d0a6,$dd0e,$ea33,$f820,$ffff

// ---- Non-ZP variables (with 7-byte gaps for channel-2/3 ,x offsets) ----
// chnXxx,x where x=0,7,14 selects channels 1,2,3.
chnTrans:    .byte 0
chnIns:      .byte 0
chnNote:     .byte 0
chnFreqLo:   .byte 0
chnFreqHi:   .byte 0
chnPulsePos: .byte 0
chnPulse:    .byte 0
  .byte 0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0

chnSfxPtrHi: .byte 0
chnSfxSR:    .byte 0
  .byte 0,0,0,0,0
  .byte 0,0,0,0,0,0,0
  .byte 0,0,0,0,0,0,0

// ---- Module-data symbol aliases ----
// All operands referencing these get patched at runtime by SetMusicData.
// At assemble time they resolve to dummyData so the code is well-formed.
dummyData:
songTbl:
pattTblLo:
pattTblHi:
insAD:
insWavePos:
insPulsePos:
insFiltPos:
waveTbl:
noteTbl:
waveNextTbl:
waveSRTbl:
pulseLimitTbl:
pulseSpdTbl:
pulseNextTbl:
filtLimitTbl:
filtSpdTbl:
filtNextTbl:
sfxSlideTblLo:
sfxSlideTblHi:
  .byte 0
