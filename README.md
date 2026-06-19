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

## Footprint & Optimization

The resident client is built to fit entirely within **Bank 0** of the C64's memory map, leaving the upper VIC banks free for streamed graphics and audio. Reaching that target meant reclaiming a significant amount of space from the larger, pre-beta builds — work carried out with the help of <mark>**Claude Code**</mark>, Anthropic's agentic coding assistant, which was used to compress the client toward the smallest practical footprint.

Getting under the Bank 0 ceiling took two complementary efforts, and neither would have been enough on its own:

- **Removing features that no longer earned their space.** The MiniPlayer2 SID module player was retired in favour of the unified tracker/SoundBridge audio engine, and the 80-column bitmap support and standalone bitmap-drawing routines were dropped entirely.
- **Tightening the remaining code.** <mark>**Claude**</mark> identified redundant paths and more compact implementations throughout the assembly, recovering further bytes across the client.

Only the combination — the feature reductions together with the low-level optimizations — brought the entire client comfortably inside Bank 0.

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
