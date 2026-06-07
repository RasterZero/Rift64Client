# Rift64 Client

Rift64 Client is a native Commodore 64 client application developed in 6502/6510 Assembly. It serves as the frontend interface for the Rift64 network system, bringing dynamic content and interactive applications to legacy hardware over low-bandwidth serial connections.

## Overview

The client establishes a serial connection using a virtual or physical modem over a SwiftLink, Turbo232, or compatible interface. Once connected, it processes stream commands from a Rift64-compatible server to render rich, real-time graphical and audio experiences directly on the Commodore 64.

## Key Features

- **High-Speed Serial Communication:** Full integration with SwiftLink and Turbo232 interfaces, supporting speeds up to 38400 baud.
- **Dynamic Asset Streaming:** Real-time rendering of metatiles, custom fonts, multicolor sprites, and bitmaps sent on-the-fly from remote servers.
- **Optimized Video Layouts:** Direct VIC-II chip control, including custom raster splits and hardware-driven scrolling capabilities.
- **Audio and Sound Effects:** Low-level integration with the SID chip, managing music and sound effects using dedicated script slots.
- **Robust Network Protocol:** Custom client-side handling of the lightweight RIFT64 transmission protocol.

## System Requirements

- **Platform:** Commodore 64 (NTSC or PAL)
- **Serial Interface:** SwiftLink, Turbo232, or compatible interface (I/O address default at $DE00)
- **Connection Speed:** 38400 baud (recommended)
- **Software Dependencies:** KickAssembler (for compilation)

## Compilation and Execution

To assemble the source code into a runnable C64 program, use KickAssembler:

```
java -jar KickAss.jar rift64.asm
```

Load and run the compiled program on a Commodore 64 or within the VICE emulator:

```
LOAD "RIFT64",8,1
RUN
```
