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
  SPIR-V). Divergence between machines is the cost to measure. MarI/O-scale semantic discovery experiments are the reason (section 12).

## 11. Build

- Version skew: PSC lowers against the pwsh runtime's CoreLib (rc.3); the pinned ILC and runtime pack are
  preview.6. Pinning matching rc.3 packages needs a download.
- The native image still links `ucrt.lib`.
- ELF output for Linux and Android, from the Pwsh project's `New-ElfCodeLibrary` and kokoro-hexagon's linker work.

## 12. Developmental semantic discovery and alternate realizations

### Objective

PSNES is an emulator in its own right and a developmental environment for Student. Its distinguishing objective is to discover the semantics of a game from execution and to realize those semantics in forms other than the original framebuffer. Compete with the authored-profile approach of 3dSen by acquiring reusable knowledge from evidence rather than requiring someone to hand-author every game's geometry and behavior.

The first flagship is Super Mario Bros. (NES): a complete, continuous start-to-finish adventure, including an uninterrupted traversal of the original world's successive areas, and an optional genuinely navigable 3D realization with Mario 64-style movement and camera behavior. These are alternate experiences, not claims that the original NES simulation contains a hidden three-dimensional world.

Keep the original emulator, discovered semantics and alternate realizations independently testable. Faithful emulation remains available regardless of how much Student learns or how an alternate world is realized. The following milestones are planned, not completed features.

### 12.1. Emulator as an experimental substrate

- Establish frame-exact observations and reproducible snapshots of CPU state, RAM, cartridge state, PPU memory, OAM, palette, scroll, controller state and, when available, APU events. Distinguish a hardware observation from an interpretation.
- Import BizHawk input movies (initially supported BK2 profiles); validate ROM identity, initial state, controller mapping, reset events and timing before accepting a replay as evidence. Do not assume BizHawk save states are portable. Reconstruct checkpoints by replaying from an admitted initial state or use a separately validated state translation.
- Replay headlessly, fork from retained checkpoints and execute independent trials. Preserve the player's live machine from experimental changes. Retain input histories and reproducibility witnesses; allow a discovery to be independently challenged.
- Use triple-buffered presentation as an independent consumer of completed frame epochs; observation and replay collection must not depend on displayed frames, skipped presentation frames or rendering speed. Validate buffer ownership and publication rather than using throughput alone as evidence of smooth gameplay.
- Reuse the existing emulator core in interactive, headless and batch modes. Establish CPU-parallel trials and measure scaling before introducing a GPU backend.

### 12.2. Evolve the discoverer, not a game-playing agent

The owner's earlier Mario.lua/MarI/O experiments used NEAT, multi-objective fitness, multiple savestates, enriched sensory inputs and retained replays. The new purpose is not to evolve a better Mario controller. Evolve Student's ability to discover, compose, test and revise semantic relationships from replays. Controller policies and human/TAS movies are sources of developmental experience; game progress is not the principal fitness objective.

Reuse PSC's DiscoveryMechanisms and Student's existing typed observation, referent and retention mechanisms. Do not create a second unrelated semantic framework in the emulator. Retain evolutionary search, replay visualization and experimental scheduling ideas from Mario.lua; do not inherit its game-specific RAM addresses as the required perceptual interface. Known addresses may serve as withheld verification or explicitly identified seeds.

- **Within a developmental lifetime:** acquire observations, propose relationships, test predictions, compose discoveries, retain evidence and withdraw contradicted relationships.
- **Across generations:** vary discovery operators, attention, temporal association, candidate relationship composition, experiment selection, retention and revision policies. Select for the quality and efficiency of discoveries, not the fitness of a game-playing network.
- **Evaluation:** use held-out trajectories, unseen areas, altered starting states and ultimately unfamiliar games. Score predictive consistency, invariance, evidence coverage, useful abstraction, acquisition cost and transfer; penalize unsupported assertions, overfitting, gratuitous complexity and failure to revise. Record a vector of results before choosing any scalar selection policy.
- **Controls:** separate training observations from independent verification, compare against a fixed non-evolved discoverer, and test evolved discovery policies with fresh knowledge stores. Distinguish inherited discovery capability from previously acquired game knowledge.
- **Interventions:** branch a replay where observational evidence is ambiguous, vary a controller action or an admitted experimental state, and test competing explanations. Mark interventions separately from ordinary game observations.

A successful Student should recover relationships such as world-relative position and velocity, camera transformation, sprite grouping, animation, collision, enemy activation, collectible interactions, doors/pipes, transitions and decorative layers. Unknown or underdetermined semantics remain unknown. A two-dimensional trace cannot uniquely establish three-dimensional geometry.

### 12.3. Scripting and inspection as a first-class emulator capability

Extend section 7 by porting the reusable PowerShell child-session and terminal interaction from Notepad, rather than embedding a separate Lua interpreter. Inspect the actual Notepad implementation at integration time; distinguish a working terminal from an emulator object interface.

Expose the emulator's own typed objects and operations through the same admitted application boundary in interactive and automated modes: observation, frame stepping, controller input, checkpoints, replay, independent instances, semantic inquiries, experimental branches and visualization. Hosted scripts may hold live typed objects; the native player must expose explicit synchronized state and control capabilities rather than assuming child-process object identity.

Use the existing proposed COM/NT shared-state design where it remains appropriate; reuse PSC facilities for identity, acquisition and lifetime as they mature. A console is an interaction surface, not the transport for large machine-state or frame payloads. Do not block the emulation or presentation thread on a script. Make the semantic viewer, experiments and replay controls accessible from the same interface users can script.

The emulator's native discovery integration must not require that a script console be open. Eventually the same interface should admit PSC's independent reflective runspace; this is not a dependency for the first release.

### 12.4. Persistent world knowledge and widescreen

Extend the per-ROM `.psnes` artifact with typed retained semantic knowledge, source/replay identity, provenance, world coordinates, relationships and confidence/refusal evidence, separate from player save states and preferences. Version discoveries and realizations; invalidate or revalidate them when the ROM or relevant observation profile changes.

- Stitch observed terrain and map area-relative coordinates into a persistent world. Associate entities with semantic identities rather than recycled OAM slots.
- Learn spawn origins, activation windows, despawn/reappearance behavior, trajectories and interaction constraints from replays and experiments.
- Realize known entities outside the original 256-pixel viewport before the game instantiates their sprites. Continue presentation-only entities when the original game drops them. Reconcile with authoritative game state on activation, avoiding duplicate entities, abrupt position corrections and visible pop-in where evidence permits.
- Evaluate offscreen position and activation predictions on held-out replays, including reversals, deaths and alternate routes. Do not silently inject simulated actors into the original machine. Where knowledge is insufficient, retain uncertainty or fall back to faithful presentation.
- Generate background scenery, parallax, lighting and atmospheric effects from discovered spatial and decorative roles, using NES assets as seeds. Keep observed geometry distinct from generated extensions. The existing presentation-only restriction in section 9 applies to faithful/enhanced emulation; alternate gameplay is a separately selected realization.

### 12.5. Alternate world realization

Treat the semantic world as independently representable, analogous to the separation of semantics and realization elsewhere in PSC. The same learned game can have several explicit realizations:

| Mode | Authority | Intended experience |
| --- | --- | --- |
| Original | NES machine | Faithful framebuffer and controls |
| Extended 2D | NES machine | Persistent terrain, wide view, coherent offscreen presentation |
| 3D presentation | NES machine | Depth, geometry, parallax and camera freedom without altering game rules |
| Alternate 3D gameplay | Alternate world simulation | Free spatial movement, 3D collision, camera and interaction inspired by the original game |
| Continuous adventure | Selected realization | Seamlessly connected areas and transitions across a complete game |

The alternate 3D mode is not restricted to extruding the original playfield or retaining the original two-dimensional movement model. Support analog movement in a genuine three-dimensional world, a chase camera, jumping, geometry-aware collisions and spatially realized enemies, collectibles and transitions. Preserve the discovered identity and meaningful relationships of the original assets while explicitly defining newly introduced depth, physics and controls. The alternate simulation owns these new gameplay semantics; no claim of exact NES behavioral equivalence is made.

Use procedural 3D realizations of NES assets: tiles, sprites, palette and animation evidence become inputs to typed geometry and material primitives. Geometry may be extruded, composed, generated or realized as billboards as appropriate to the discovered role. Reuse the owner's Windows graphics primitives and OS-provided acceleration where they express the desired operation. Do not make direct GPU programming or a new shader compiler a prerequisite; measure limitations first. A world and its assets must not be defined in terms of a particular rendering backend.

Support loading alternate world/asset realizations against retained semantic referents. Permit replacement of the representation without replacing the underlying knowledge. Keep game-specific hand-authored additions optional and distinguish them from discovered relationships and generated content.

### 12.6. Flagship: Super Mario Bros. as one continuous adventure

The intended experience is a playable journey from the beginning of World 1-1 through the final castle of World 8-4, without visible loading screens or mandatory between-area interstitials. Use the original game's assets and discovered semantics, not a collection of unrelated generated levels.

- Acquire the full area and transition graph from valid replays and experimental branches: overworlds, underground and underwater areas, castles, pipe connections, warp destinations and end-of-level progression.
- Preserve meaningful connections and progression conditions. Distinguish the normal sequential route from optional warp routes; verify the full sequential playthrough, including all 32 main stages, rather than using warps to bypass coverage.
- Compose connected spatial areas with continuous transitions; prepare upcoming assets, geometry and entities before crossing a boundary. A pipe, doorway, flagpole, castle exit or other discovered transition may become a traversable connection or short in-world transition instead of a loading screen.
- Carry player progression and relevant persistent state across boundaries under the chosen realization. Where the original uses resets, timers or distinct local coordinate spaces, preserve their meaning in faithful mode and explicitly define the alternate-mode mapping. Do not require all areas to reside in memory at once.
- In faithful/enhanced mode, preserve original machine transitions and timing even when presentation conceals them; seamless continuous control and reauthored traversal belong to the alternate simulation when the ROM cannot supply them.
- First prove continuity between two adjacent areas including a return or branch; expand to all areas and demonstrate a recorded end-to-end run. Measure transition stalls, frame pacing, missing geometry, entity pop-in and progression consistency. The final demonstration is continuous *play*, not a prerecorded cinematic.

### 12.7. Milestones and acceptance

| Milestone | Exit evidence |
| --- | --- |
| E0: trustworthy core | Reproducible state, input and replay witnesses; original emulator regressions preserved; mapper/PPU/APU work tracked under section 1 |
| E1: scriptable experiments | Notepad-derived terminal plus typed emulator operations, independently forked machine states and synchronized observation; no script-dependent frame pacing |
| E2: evolved discovery | Fixed-policy baseline versus evolved discoverer on held-out replays; recover meaningful relationships without mandatory Mario-specific address annotations |
| E3: persistent world | Terrain and entity identity survive scrolling and slot reuse; measured reduction of widescreen pop-in without corrupting authoritative execution |
| E4: procedural 3D | Load a new realization of the same semantic world; 3D presentation and procedural scenery using the existing graphics primitives |
| E5: alternate gameplay | Mario 64-style movement, camera, 3D collision and interactions in a world realized from NES assets; explicitly separate alternate simulation |
| E6: uninterrupted adventure | Complete non-warp Super Mario Bros. run, coherent transitions, no visible loading screens, reproducible progression and measured presentation continuity |
| E7: transfer | Apply the discoverer and realization machinery to a second game; report what transferred, what was newly acquired and what required explicit authoring |

These are dependency-informed milestones, not a requirement to complete every mapper or unrelated emulator feature before prototyping. Preserve the existing fidelity and build acceptance evidence. Keep performance claims tied to their actual profile; the historical headless benchmark does not establish the cost of Student, full APU/PPU accuracy or 3D rendering.

Distribute PSNES and its own code independently of commercial ROMs. User-supplied authorized ROMs provide the source assets; verify rights before publishing ROM-derived asset packs or replay artifacts containing protected material.

## Capabilities PSNES needs from PSC

Window, COM (client and reverse, with type info), persistence, audio, indexed surface and compositing, `[ref]`
lowered to CLR by-ref parameters, and a GPU backend.

## Open decisions

- Integer promotion rule for mixed operands in PSC (currently the C# rule).
- GPU shaders: accept compiled shader bytecode as a pinned input, or wait for PSC to produce it.
- Pinning rc.3 ILC and runtime packages.
