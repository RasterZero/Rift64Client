// UI input routines.
//
// Keyboard draining, endpoint address display/editing, and the
// interactive input loop for the start page.

drain_keyboard:
  jsr GETIN
  bne drain_keyboard
  rts

load_default_endpoint:
  ldy #0
load_default_endpoint_loop:
  lda default_endpoint,y
  beq load_default_endpoint_done
  sta endpoint_buffer,y
  iny
  cpy #ENDPOINT_MAX
  bcc load_default_endpoint_loop
load_default_endpoint_done:
  sty endpoint_len
  rts

render_endpoint:
  lda #0
  sta cursor_x
  lda #11
  sta cursor_y
  ldx #<endpoint_label
  ldy #>endpoint_label
  jsr print_string
  jsr print_endpoint_buffer
  jsr clear_endpoint_tail
  jsr show_cursor
  rts

print_endpoint_buffer:
  ldy #0
print_endpoint_buffer_loop:
  cpy endpoint_len
  beq print_endpoint_buffer_done
  lda endpoint_buffer,y
  sty string_index
  jsr print_char
  ldy string_index
  iny
  jmp print_endpoint_buffer_loop
print_endpoint_buffer_done:
  rts

clear_endpoint_tail:
  lda cursor_x
  cmp #39
  bcs clear_endpoint_tail_done
  lda #32
  jsr print_char
  jmp clear_endpoint_tail
clear_endpoint_tail_done:
  rts

endpoint_input_loop:
  jsr GETIN
  beq endpoint_idle
  cmp #13
  beq endpoint_return_key
  cmp #20
  beq endpoint_backspace
  cmp #8
  beq endpoint_backspace
  cmp #32
  bcc endpoint_input_loop
  cmp #127
  bcs endpoint_input_loop
  ldx endpoint_len
  cpx #ENDPOINT_MAX
  bcs endpoint_input_loop
  ldy #1
  sty endpoint_accept_return
  sta endpoint_buffer,x
  inc endpoint_len
  jsr hide_cursor
  jsr render_endpoint
  jmp endpoint_input_loop
endpoint_backspace:
  ldy #1
  sty endpoint_accept_return
  lda endpoint_len
  beq endpoint_input_loop
  dec endpoint_len
  jsr hide_cursor
  jsr render_endpoint
  jmp endpoint_input_loop
endpoint_input_done:
  jsr hide_cursor
  rts
endpoint_return_key:
  lda endpoint_accept_return
  beq endpoint_input_loop
  lda endpoint_len
  beq endpoint_input_loop
  jmp endpoint_input_done
endpoint_idle:
  inc endpoint_idle_lo
  bne endpoint_input_loop
  inc endpoint_idle_hi
  lda endpoint_idle_hi
  cmp #4
  bcc endpoint_input_loop
  lda #1
  sta endpoint_accept_return
  jmp endpoint_input_loop
