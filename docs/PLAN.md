# chimera-core-geargrafx: plan and design log

Geargrafx (https://github.com/drhelius/Geargrafx) as a Chimera core: the PC
Engine / TurboGrafx-16, the SuperGrafx, the PC Engine CD (CD-ROM2, Super
CD-ROM2, Arcade CD-ROM2) and the LaserActive's PC Engine pack (LD-ROM2), in
one package. Requested in ToolAssisted-run/chimera#581; the owner approved
building it on 2026-11-14 with every system the emulator supports.

Geargrafx is one of six emulators by Ignacio Sanchez (drhelius) that became
Chimera cores at the same time (gearboy, gearsystem, gearcoleco, geargrafx,
gearlynx, geartowns). Each has the same shape: the emulator in `src/`, a
libretro core in `platforms/libretro/`, and a desktop program (SDL, ImGui, a
debugger, an MCP server) in `platforms/`. This core builds what the libretro
core builds and nothing of the desktop program.

## 1. Before any code (docs/new-core.md section 1), 2026-11-14

**A new core?** Yes. No core here runs Geargrafx. Mesen and ares already run
the PC Engine, SuperGrafx and PC Engine CD; Geargrafx adds the LaserActive's
LD-ROM2, the MB128 backup unit, the Avenue Pad 3 and the PC Engine mouse, and
is a third, separately written emulator of these machines.

**Licence.** GPL-3.0 at the pinned version, 1.8.7 (commit de35c477, the
`LICENSE` file of that commit), which allows a modified binary to be passed
on with its source. The libraries Geargrafx carries are MIT, BSD-3-Clause,
public domain and BSD-or-GPL-2.0 (`waterbox/package-licenses.json`), all of
which may go into a GPL-3.0 program.

**Compiled-in firmware.** None. The source was searched for byte tables:
the only ones are register masks, the PSG's volume table, the Super CD-ROM
signature (4 bytes) and the TurboLink's truth table. The System Cards, the
Games Express card and the LaserActive PAC BIOS are files the user brings:
Geargrafx only checks their size and looks their CRC-32 up in its list.

**One thread, one clock.** Two threads exist in upstream and both are off in
this build: the .cue reader's read-ahead thread is only built with
`GG_ENABLE_CDROM_CUEBIN_READAHEAD` (not defined), and the LaserActive's video
decoder runs on the one thread with `GG_DISABLE_MMI_THREADS` (defined), which
upstream provides for exactly this. A physical CD drive
(`GG_ENABLE_PHYSICAL_CDROM`) is not built. The only clock read that reaches
the machine is the power-on random seed, `time(NULL)` in
`GeargrafxCore::Init`; patch 0001 replaces it with a project setting. The
other `time(NULL)` dates a savestate file, which this core never writes.
The machine runs one frame per call (`RunToVBlank`), timed by its own master
clock.

**The picture.** The machine's own framebuffer: Geargrafx draws RGBA8888 into
a buffer the adapter gives it; the adapter swaps it to BGRA. No GPU.

**Recompiler.** None; the HuC6280 is interpreted.

**What the user brings.** For the PC Engine CD, one System Card: Super
CD-ROM2 3.0 (Japan) by default, or 3.0 (USA), 2.0 (Japan or USA), 1.0
(Japan), or the Games Express card, chosen by a setting and pinned by SHA-1
(the same SHA-1s the ares and Mesen cores pin). For the LaserActive, a PAC
BIOS: PAC-N1 or PCE-LP1 (Japan) or PAC-N10 (USA). HuCards need nothing.

**What CI can run.** This repository's own programs, built at test time by
`tests/pce-test/make-pce-test.py`: a HuCard program (also run as a
SuperGrafx .sgx), a variant for the six-button pad, and for the CD a 256 KiB
stand-in for the System Card with a 64-sector disc made beside it. The
stand-in is our own HuC6280 program, not NEC's: it selects the CD drive,
sends a SCSI READ through the CD interface ($1800-$1808) and keeps the
sector in RAM. So the CD machine, its drive and the .cue reader are tested
with no NEC firmware. What it does not stand in for: a real System Card's
own code (the BIOS calls games make, its boot screen, the ADPCM and CD audio
it drives), which only runs with the user's card and a real disc.

**Size.** Small: about 20 MiB of machine; `memoryLayoutMiB` is
[64, 4, 8, 4, 128]. A savestate of Bonk's Adventure at frame 900, taken
through chimera-run, is 0.9 MiB.

## 2. Decisions

### Machines (2026-11-14)

One `core.wbx`, four machines picked by the setting `machine`, with the
system ids the ares and Mesen cores already use where they exist:

| machine | system id | files | firmware |
|---|---|---|---|
| `pce` (default) | PCE | a HuCard, .pce | none |
| `sgx` | SGX | a HuCard, .sgx or .pce | none |
| `pcecd` | PCECD | a disc, .cue with its track files | `syscard` |
| `laseractive` | PCELD | a disc image, .mmi | `pacbios` |

Upstream decides "SuperGrafx or not" from the game: its game list marks the
SuperGrafx games, and a `.sgx` extension forces one. Here the machine is the
project's choice, so patch 0001 keeps a `pce` machine a PC Engine whatever
the game is (`gg_chimera_no_sgx`), and the `sgx` machine forces a SuperGrafx
(upstream's own `GG_CONSOLE_SGX`). A SuperGrafx-only game on the PC Engine
machine then does what it does on a real PC Engine.

`.chd` discs: see "2026-11-14: .hes and .chd" below; `.hes` music files are
not offered (same place).

### The controls (2026-11-14)

One controller declaration for all four machines: Power, then five players
(the TurboTap's) of Up Down Left Right I II Select Run III IV V VI each, then
the mouse's two buttons, and the mouse's movement on two axes. The mnemonics
and default keys are the Mesen core's, so a PC Engine movie column reads the
same in both. The settings `port1` (pad, Avenue Pad 3, Avenue Pad 6, mouse),
`turboTap` and `port2`..`port5` say what is plugged in. The mouse's buttons
are the console's II (left) and I (right), as upstream's libretro core maps
them. Upstream's per-button turbo is not offered: Chimera has its own
autofire.

### Disc images in a savestate (2026-11-14, patch 0001)

Upstream's .cue reader keeps every piece of the disc it has read, 75 KiB at a
time, for the whole session; its .chd reader keeps every hunk. Both live in
the machine's memory, so a long game would end up with the whole disc in
every savestate (the Mesen core met the same, 300 MiB, its patch 0011). Under
`GG_CHIMERA` the .cue reader keeps 8 pieces (upstream's own
`max_cached_chunks`) and the .chd reader 16 hunks (a ring added by the
patch). What is read is the same either way; only how much is kept changes.

### The power-on state (2026-11-14)

Upstream fills the CPU's registers, the memory map registers, the palette and
the CD drive's first read delay with random values at power on, seeded from
the clock. Here: `powerOn` = `random` (upstream's behaviour, from the seed in
`randomSeed`, default 0x12345678) or `zero` (upstream's "deterministic
netplay" values). Both are part of the machine.

### What else is a setting

`region` (auto, PC Engine, TurboGrafx-16: the console's region bit; upstream's
Auto answers as a TurboGrafx-16), `cdromType`, `systemCard`,
`laseractiveBios`, `mb128`, `backupRam` (upstream's default, on), `psg`,
`noSpriteLimit`, and three that change the picture only: `overscan`, `lines`
(240 or 224) and `palette`. Upstream's CPU overclock and CD read speed are
not offered: upstream itself calls them inaccurate.

### Saved games

Exported: the backup memory (`backup.brm`, 2 KiB) when the console has one,
and the MB128 (`mb128.bin`, 128 KiB) when it is plugged in. A project's
`savedata` slot takes either back, told apart by size.

## 3. Tests

`waterbox/run-gate.sh` (core), `waterbox/tests/run-frontend.sh` (Chimera's
window, headless), Chimera's contract tests, and `waterbox/tests/run-local.sh`
(games from `tests/roms-local`, by hand).

### 2026-11-14: first round

- `run-gate.sh`: 44 ok, 0 failed (with `CHIMERA_ROOT` set; 43 and one SKIP
  without). For each of pce, tap (five pads, pad 3 driven too), pad6, mouse,
  sgx, pcecd (stand-in card) and power (Power pressed at frame 300): 600
  frames native == sandbox on picture, sound, lag and every memory domain;
  the input changed the machine; turbo (half the frames undrawn) left the
  same machine and pictures; a savestate saved and loaded before every frame
  changed nothing. Then: each button is read by the program as itself (pce,
  tap, pad6, mouse); each setting under test makes another machine than its
  control (TurboTap off, a two-button pad, a pad instead of the mouse, a
  CD-ROM2 instead of the Super CD-ROM2); the SuperGrafx has its second video
  chip and the PC Engine given the same .sgx file has not; the stand-in card
  read 8 sectors of the disc; a disc with no System Card and a LaserActive
  with no PAC BIOS are refused with their errors; three seeds make three
  machines; the saved game given in the project comes out of the backup
  memory unchanged; and, through chimera-run, 3000 reads of the controllers
  in 300 frames reach Chimera's input-poll callback without moving the
  machine.
- Seen to fail, the adapter broken on purpose in five places at once and
  rebuilt: SetRenderingEnabled made a no-op (every `:turbo` test, 7),
  I and II swapped (`pce:buttons`, `tap:buttons`), the PC Engine machine
  allowed to become a SuperGrafx (`sgx:second-vdc`), the saved game not
  loaded (`savedata:export`), the input-poll callback not called
  (`engine:input-polls`): 32 ok, 12 failed. Then the seed put back on
  `time(NULL)`: every `:equivalence` test and `power-on:seed` failed (12).
  `mouse:buttons` did not fail with I and II swapped, rightly: the mouse's
  buttons are wired to II and I by name, not through the pad's columns.
- `run-frontend.sh`: 6 ok, 0 failed: the PC Engine, the SuperGrafx and the
  PC Engine CD (the stand-in card given as the project's firmware) each boot
  from a project in the window and end 300 frames with the native
  reference's Work RAM; buttons held by Lua through TAStudio and the
  `powerOn` setting arrive; the 14 key and 2 mouse bindings are the
  window's.
- Chimera's contract tests (`test-packages` on a folder holding only this
  package): 25 passed.

- `run-local.sh`, games copied from the owner's collection into
  `tests/roms-local` (SHA-1 in brackets, first 12 digits), 3000 frames of the
  pad exercise each, native == sandbox == a savestate before every frame, and
  the exercise changed the machine: Bonk's Adventure (U) [403c4fbdb617],
  Bomberman '93 (U) with the TurboTap and pad 2 driven too [709b47de6e0e],
  Street Fighter II' Champion Edition (J), the 2.5 MiB mapper, with the Avenue
  Pad 6 [f82e67301b85], Populous (J), which has RAM on the card
  [735e19d035bb], and on the SuperGrafx 1941 Counter Attack (J)
  [66873b0e0cc6] and Darius Plus (J) [bca32f878a41]: 6 passed. Bonk's title
  screen and 1941's (both video chips' layers) were looked at through
  chimera-run screenshots and are right. The two CD games entered (F1 Team
  Simulation Project F, Magical Dinosaur Tour) SKIP: no System Card was
  available yet (the owner's firmware folder was still being copied), so no
  real CD game was run.
- Not run: Windows (the frontend test scenario must be run there before the
  core is called done), aarch64 (only CI would build it; nothing was pushed),
  and a movie recorded in the window and replayed in a new process.

What the test programs do not stand in for: a real System Card's code, CD
audio and ADPCM driven by a game, a game's use of the mouse, the Avenue Pad 3
and the MB128 (each is only exercised through the port by our program), and
the LaserActive beyond its refusal without a PAC BIOS.

### 2026-11-14: .hes and .chd, and the LaserActive (user-decided, 2026-11-14)

The owner decided: offer `.hes` and `.chd`, each tested with a free file made
at test time; keep the LaserActive declared, but boot it with the owner's
PAC BIOS before the core is published, or drop it; run the two CD games when
the System Cards arrive.

- **.hes.** Geargrafx 1.8.7 has no player for HES files in the "HESM" format
  (a header, a load address and an init routine): it loads any .hes as a
  HuCard image and only marks it as music for its desktop program's
  visualiser. A HESM file made here loaded and ran none of its code. So what
  is offered, and tested, is what Geargrafx plays: a music ROM in HuCard form
  with the .hes extension (`hes-test.hes`, our HuCard program with a 16-note
  tune). The card slot takes `.hes`. A HESM rip will not play.
- **.chd.** `tests/pce-test/make-pce-test.py` makes `cd-test.chd` from the
  test disc with MAME's chdman (mame-tools, installed in the container and
  in CI; two runs make the same file, SHA-1 9779cfc8...). A .chd is one file,
  so the disc slot needs nothing Chimera does not have: `formats` gains
  `chd`. The test disc grew to 1024 sectors and the stand-in card reads
  every 8 frames across it, so both disc readers give pieces back (6 times
  each in 600 frames, counted once with a temporary print).
- **LaserActive and the CD games.** /home/jaffar/firmware did not exist yet
  on jaffanator01 and no .mmi disc is among /home/jaffar/roms, so the
  LaserActive was not booted and the CD games were not run. Both are still
  to do before publishing.

Tests after the change: `run-gate.sh` 54 ok, 0 failed (new: `hes:*`, 5;
`chd:*`, 5, among them `chd:same-as-cue`, the .chd machine frame for frame
the .cue one); `run-frontend.sh` 7 ok (new: `chd:frontend`, a .chd project
in the window, Work RAM as the native reference and as the .cue run);
contract tests 25 passed. Seen to fail: the .hes given to Geargrafx without
its name (`hes:detected`), and .chd refused by the adapter (`chd:equivalence`,
`chd:same-as-cue`, and in the window `chd:frontend`).

### 2026-11-14: .hes dropped (user-decided, 2026-11-14)

The owner asked for upstream's HES player to be brought into the core so
that real HESM rips play. There is none: neither release 1.8.7 nor
upstream's newest commit (7a2fe6b) reads the HESM format anywhere. The core
loads a .hes as a HuCard image, and the desktop program only draws the
sound chip's waveforms while one runs. So `.hes` is not offered: neither
Geargrafx's core nor this one has a HES music player, so a real rip would
load and play nothing. The card slot no longer takes `.hes`, the adapter
refuses one by name (`error.rejected`, test `hes:refused`), and the
HuCard-form music test file and its tests are gone. No .hes rip is among
/home/jaffar/roms. `.chd` stays.

Tests after the change: `run-gate.sh` 50 ok, 0 failed; `run-frontend.sh`
7 ok; contract tests 25 passed. Seen to fail: the adapter's refusal taken
out (`hes:refused`).

## 4. Open questions for the owner

- The LaserActive's PAC BIOS files are declared by size (512 KiB) and name
  only, with no SHA-1: none was at hand to hash. Geargrafx knows them by
  CRC-32 (PAC-N1 A8CB694C, PCE-LP1 76116A02, PAC-N10 01223DD5). Pin them
  when the files arrive. The LaserActive machine was never booted: no .mmi
  disc image and no PAC BIOS were available.
