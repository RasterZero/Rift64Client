// 256-byte memory staging buffer and copy helper.
//
// Intended protocol shape:
//   M AAAA LL <payload>
//
// AAAA is the destination address in hex, high byte first.
// LL is the payload length in hex. A length of 00 means 256 bytes.
// The protocol reader fills MemoryStoreBuffer, then calls memory_store_copy.

.const MEMORY_STORE_PTR = $fb

MemoryStoreDestLo:
  .byte 0
MemoryStoreDestHi:
  .byte 0
MemoryStoreLength:
  .byte 0
MemoryStoreReadRemaining:
  .byte 0
MemoryStoreBuffer:
  .fill 256, 0

memory_store_copy:
  lda MemoryStoreDestLo
  sta MEMORY_STORE_PTR
  lda MemoryStoreDestHi
  sta MEMORY_STORE_PTR+1
  ldy #0
  lda MemoryStoreLength
  beq memory_store_copy_256
  sta MemoryStoreReadRemaining
memory_store_copy_loop:
  lda MemoryStoreBuffer,y
  sta (MEMORY_STORE_PTR),y
  iny
  dec MemoryStoreReadRemaining
  bne memory_store_copy_loop
  rts

memory_store_copy_256:
  lda MemoryStoreBuffer,y
  sta (MEMORY_STORE_PTR),y
  iny
  bne memory_store_copy_256
  rts
