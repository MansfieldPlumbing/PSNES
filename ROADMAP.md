# PSNES roadmap

## Where it stands

- `PSNES.ps1` is one PowerShell file: the emulator core, a window, and a headless entry point (`PsnesBench`).
- Interpreted: about 1.8 frames per second.
- Lowered by PSC and run in pwsh: about 1,043 frames per second (3,600 frames in 3,452 ms).
- Native: PSC builds `psnes-bench.exe` (1.17 MB) through the pinned ILC and its own COFF linker, with no MSBuild,
  .NET SDK or `link.exe`. 3,600 frames in 3,693 ms. RAM checksums equal the interpreted run (20 frames) and the
  lowered JIT run (3,600 frames).
- The lowered core references only `System.Private.CoreLib` and `System.Console`.
- nestest: the lowered and interpreted cores give identical traces over 9,087 instructions, matching JSNES and
  FCEUX through instruction 8,991.
- Only mapper 0 (NROM) cartridges run. There is no APU: writes to `$4000`-`$4017` are dropped.

## 1. Core accuracy

1. **Mappers.** The largest gap: without them most of the library does not run.
   - Prerequisite: mapper-aware CPU and PPU buses. Today `Memory.Read` maps `$8000-$FFFF` straight into
     `Rom.PrgRom`, `Memory.Write` never reaches the cartridge, `Ppu.ReadVram` reads `Rom.ChrRom` directly and
     `RenderFrame` reads the CHR array itself. Both buses must route through the mapper: PRG/CHR banking, cartridge
     RAM, nametable mirroring and mapper timing.
   - Order: mapper-aware buses -> PPU fetches timed as the CPU runs -> MMC3's IRQ (clocked by PPU address line A12,
     not a scanline count) -> broad compatibility.
   - MMC1 (Zelda, Metroid), UxROM (Mega Man, Castlevania), CNROM, AxROM, MMC3 (SMB3).
   - NES 2.0 headers and submappers; configurable PRG/CHR RAM and battery NVRAM; board-specific bus conflicts.
   - Each mapper is a class with typed state, so save states and lowering cover it like the rest of the core.
2. **PPU rendered as the CPU runs** (by dot or by scanline). `RenderFrame` draws after the CPU's frame, and the
   sprite-0 scanline record, per-row scroll capture and `LineY` reuse all exist to work around that. A renderer
   that runs alongside the CPU removes them and restores the original sprite-0 conformance test.
3. **APU.** Two pulse channels, triangle, noise and DPCM, mixed and timed to the CPU. The reference for every
   sound feature below.
4. **Accuracy checks on every change.** The FCEUX and JSNES comparisons and the nestest trace run as tests; save
   states make any disagreement reproducible.

## 2. Machine control

- Pause and resume; soft reset (the RESET line: RAM survives); hard reset (power cycle).
- Frame advance, fast forward, slow motion.
- Rewind, from per-frame state differences.

## 3. Persistence: one `.psnes` file per game

- Named by the ROM's hash. Holds battery saves (cartridge SRAM), save state slots, input assignments, cheats, and
  the RAM knowledge from the smart RAM viewer.
- Built on a PSC persistence capability: typed readers and writers generated from class shapes, the same
  interpreted, lowered and native. Any appliance gets it.

## 4. Cheats

- Game Genie: decode 6- and 8-letter codes to address, value and optional compare; apply on cartridge reads.
- Cheat search over RAM between frames.
- Smart cheats proposed from the RAM viewer's labels ("freeze lives" without knowing the address).

## 5. Inspection

- Pattern tables (both banks, selectable palette), nametables (all four screens, scroll window outlined), OAM (64
  sprites with attributes), palette.
- **Smart RAM viewer.** Labels with evidence, discovered live: bytes that follow input, that drive sprite positions,
  that track scroll, that change on events (a death, a coin). Unknowns stay unknown. Builds on the Discovery work
  that found Mario's position and velocity unprompted.
- Memory viewer, CPU trace and breakpoints.

## 6. Window and input

- Depends on PSC's window capability: its own thread waiting on messages and the frame timer, handlers for tick,
  paint, keys and size, painting only the update region inside `WM_PAINT`. That removes today's screen healing,
  polled keyboard, per-frame `GetClientRect` and the emitted pump.
- Indexed surface: palette indices with a colour table, tile damage reported by the core, palette-only frames
  redrawing only the tiles using that entry, scrolls shifting existing content.
- Keyboard events and XInput controllers; input assignments stored in the `.psnes` file.
- Fullscreen (borderless), Fit, Stretch and Blur scaling, Mica/Acrylic/MicaAlt backdrops, rounded corners.
- Open a ROM by dialog or by dropping it on the window (IDropTarget, through PSC's COM capability).
- Screenshots.

## 7. Scripting from PowerShell

- **Hosted** (the scripting mode): pwsh loads the lowered core; scripts hold the real objects. API on `Nes`:
  `ReadRange`, `RunFrames` with inputs, save and load state, events per frame, on memory writes, on breakpoints.
  Parallel instances in runspaces.
- **Native** (the player mode): `psnes.exe` launches `pwsh -File script.ps1` and hands it its channel names.
  - Control: reverse COM, `IDispatch` published in the Running Object Table; `GetTypeInfo` so `Get-Member` and tab
    completion list the API.
  - State: RAM, OAM, VRAM, palette and registers in a named shared memory section with a frame fence.
  - Video: the frame in a D3D12 texture shared through an NT handle (the DirectPort technique), for viewers,
    recorders, filters and agents in other processes.
- What plain PowerShell adds over in-emulator Lua: attaching from any terminal, the pipeline over game state,
  Pester tests for games and TAS runs, CSV and JSON logs, remoting, many instances at once, agents driving play.

## 8. Sound

- Accurate APU output through WASAPI (PSC audio capability).
- Re-voicing: the APU's register writes are a score, so the instruments can be replaced exactly - Yamaha-style FM
  voices keyed to pitch, or bespoke procedural voices. Timing, notes and dynamics stay the game's own.

## 9. Presentation

1. **Backdrop layers with parallax.** Draw layers wherever the game shows the backdrop colour (`$3F00`, known per
   pixel), then the game's frame on top. Anchors without understanding the game:
   - camera: world X from the PPU's scroll changes, unwrapped;
   - ground: the first opaque background row per column;
   - character: the player's sprite cluster from OAM, for a slight Apple-style shift.
   A general compositing layer in the surface (mask, anchors, layers with depth), usable by any appliance.
2. **Persistent world and widescreen.** Keep nametables as the game scrolls; stitch them by scroll position; draw
   the real world beyond the 256-pixel edge where it has been seen.
3. **Parallax for the game's own art.** Learn which background tiles are decoration and which are terrain
   (collision and position evidence), and move decoration to slower layers. The HUD is found structurally (the
   sprite-0 split) and stays fixed.
4. **Generated fill** from the procedural student: unrevealed areas, beyond the level's ends, higher-resolution
   tiles. Presentation only, never fed back into the game, always marked generated.
5. **Filters:** written in PowerShell and lowered (scale2x, scanlines, CRT, palettes); GPU filters wait on the
   shader decision below.
6. **Automated profiles:** tile classes, entities and solidity learned from play, so any game gets the treatment,
   not a hand-made list.

## 10. Scale

- Data-oriented core: each machine's state in flat typed arrays indexed by instance; one lowered loop steps N
  machines. Faster on the CPU, trivial snapshots, batch training across all CPU threads.
- GPU: thousands of machines in lockstep, one thread each; the PPU per pixel. Needs a GPU backend in PSC (DXIL or
  SPIR-V). Divergence between machines is the cost to measure. MarI/O-scale training is the reason.

## 11. Build

- Version skew: PSC lowers against the pwsh runtime's CoreLib (rc.3); the pinned ILC and runtime pack are
  preview.6. Pinning matching rc.3 packages needs a download.
- The native image still links `ucrt.lib`.
- ELF output for Linux and Android, from the Pwsh project's `New-ElfCodeLibrary` and kokoro-hexagon's linker work.

## Capabilities PSNES needs from PSC

Window, COM (client and reverse, with type info), persistence, audio, indexed surface and compositing, `[ref]`
lowered to CLR by-ref parameters, and a GPU backend.

## Open decisions

- Integer promotion rule for mixed operands in PSC (currently the C# rule).
- GPU shaders: accept compiled shader bytecode as a pinned input, or wait for PSC to produce it.
- Pinning rc.3 ILC and runtime packages.
