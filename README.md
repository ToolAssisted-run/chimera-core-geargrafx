# chimera-core-geargrafx

[Geargrafx](https://github.com/drhelius/Geargrafx), the PC Engine /
TurboGrafx-16 emulator by Ignacio Sanchez, as a core for
[Chimera](https://github.com/ToolAssisted-run/chimera), the frontend for
tool-assisted speedruns. Geargrafx runs in miniBox's sandbox, so a movie
plays the same on every machine.

Systems, one package:

- PC Engine / TurboGrafx-16 (HuCards)
- SuperGrafx
- PC Engine CD: CD-ROM2, Super CD-ROM2 and Arcade CD-ROM2 (.cue or .chd)

Controllers: the two-button pad, five of them through the TurboTap, the
Avenue Pad 3 and 6, the PC Engine mouse, and the MB128 backup unit.

## Using it in Chimera

Chimera ships no cores and downloads none. Put `geargrafx.chimeraCore` in the
cores folder beside Chimera's program (or the one Tools > Core Manager...
names). The same file works on Linux and Windows.

You provide the games, and for CD games a System Card (by default Super
CD-ROM2 System Card 3.0, `syscard3.pce`). Geargrafx's LaserActive (LD-ROM2)
support is not offered; `docs/PLAN.md` says why.
`docs/BUILDING.md` lists the files and their SHA-1s.

## Build and test

`docs/BUILDING.md` has every step from a fresh clone; `AGENTS.md` is the
short version. `docs/PLAN.md` says what was decided, why, and what was
tested.

## Licence

GPL-3.0, Geargrafx's licence. See `LICENSE`.
