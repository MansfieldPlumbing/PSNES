# PSNES

A typed PowerShell implementation of a NES emulator in one source file, [PSNES.ps1](PSNES.ps1). It includes the CPU, PPU, cartridge memory, input, a Windows presentation path, a built-in conformance suite and a separate headless benchmark entry point.

## Run and verify

With PowerShell 7 installed, run the built-in conformance suite or open an iNES mapper-0 ROM you are authorized to use:

```powershell
pwsh -NoProfile -File ./PSNES.ps1 -Conformance
pwsh -NoProfile -File ./PSNES.ps1 -Rom ./game.nes -Scaling Fit
```

The window uses Win32; the headless core and conformance path are separate. The scaling options are Fit, Stretch and Blur.

## Retained compiler evidence

The [roadmap](ROADMAP.md#where-it-stands) records the prior PSC-managed and NativeAOT benchmark results: 3,600 frames in 3,452 ms for lowered JIT execution and 3,693 ms for the 1.17 MB native headless executable. It records agreement of RAM checksums for the measured runs and agreement of the interpreted and lowered nestest traces over 9,087 instructions. These are historical results, not newly reproduced benchmarks or full emulator conformance.

`PsnesBench.Main(string[])` takes a ROM path and frame count and reports elapsed time and a RAM checksum. It is a distinct entry point, not a switch on the interactive application.

Mapper-aware CPU and PPU buses are implemented for mappers 0 (NROM), 1 (MMC1), 2 (UxROM), 3 (CNROM) and 7 (AxROM). NES 2.0 and other mappers are rejected. Commercial cartridge compatibility across all board variants, APU emulation and cycle-accurate mid-frame PPU rendering remain open.

## Upstream PSC integration

The [PSC integration roadmap](https://github.com/MansfieldPlumbing/PSC#integration-roadmap) identifies PSNES as an application-level validation target (A1/L3), not an emulator to embed in the compiler. Preserve instruction traces, frame and state comparisons, benchmark scope and application-owned semantics when acquiring shared native interop, input, presentation and numerical mechanisms. Verify full source and artifacts against the selected PSC revision before declaring reconvergence.

See [ROADMAP.md](ROADMAP.md) for emulator-specific priorities and existing evidence.
