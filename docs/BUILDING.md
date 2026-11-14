# Building the Geargrafx core

This repository builds Geargrafx as a sandboxed guest (`core.wbx`) and
packages it as one file, `geargrafx.chimeraCore`, which Chimera loads as a
PC Engine / TurboGrafx-16, a SuperGrafx or a PC Engine CD. The
steps are the ones `.github/workflows/chimera.yml` runs from a fresh clone.

Two placeholders are used throughout:

- `<chimera>` is the absolute path of a Chimera checkout
  (https://github.com/ToolAssisted-run/chimera).
- `<minibox>` is `<chimera>/extern/chimera-common-minibox`, Chimera's miniBox
  submodule: the sandbox host and the guest toolchain.

## Requirements

- Linux, x86_64 or aarch64 (a package is built on the CPU it is for). CI
  uses `ubuntu-24.04` and `ubuntu-24.04-arm`.
- git, and:

  ```
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends meson ninja-build build-essential python3 mame-tools
  ```

  mame-tools gives chdman, which makes the CHD test disc; without it the
  CHD tests SKIP (core) or fail (frontend).

  The guest is compiled by the same gcc and g++ through miniBox's musl specs
  file; there is no separate cross compiler.
- For the frontend test script only, Chimera built with its window: Chimera's
  `tools/ci-chimera.sh` installs Qt 6.12 (with aqt, into `~/qt`) and builds it.
- One download happens while miniBox's C++ guest toolchain is built: it
  fetches the GCC source matching the installed gcc (about 84 MB) to build
  libstdc++ for the sandbox. Nothing else downloads anything.

## Get the sources

```
git clone https://github.com/ToolAssisted-run/chimera-core-geargrafx.git
cd chimera-core-geargrafx
git submodule update --init
git clone https://github.com/ToolAssisted-run/chimera.git <chimera>
git -C <chimera> submodule update --init extern/chimera-common-minibox
```

`extern/geargrafx` is upstream Geargrafx, pinned to the release 1.8.7 and
unmodified. Every change to it is in `patches/`, which meson applies to the
submodule's working tree when a build folder is set up
(`waterbox/apply-patches.sh`; after it, `git status` shows the submodule as
modified, which is expected).

For the frontend test script, Chimera needs all its submodules
(`git -C <chimera> submodule update --init --recursive`).

## Build

```
# miniBox's host library and C++ guest toolchain
meson setup <minibox>/build/meson-cpp <minibox> -Dguest_cpp=true
meson compile -C <minibox>/build/meson-cpp

# the native reference (run-native) and the sandbox driver (run-wbx)
meson setup build/meson-native -Dminibox_dir=<minibox>
ninja -C build/meson-native

# the guest
sh waterbox/setup-guest.sh -m <minibox>
ninja -C build/meson-guest core.wbx

# the package, written to <chimera>/build/Cores/geargrafx.chimeraCore
./waterbox/build-package.sh -m <minibox> -r <chimera>
```

`build-package.sh` sets the guest build up if it is not, builds `core.wbx`,
checks it with miniBox's `check-wbx.sh` (and on aarch64 rewrites its thread
pointer reads with `wbx-tp-rewrite.py`), copies the declarations, the
language tables and the licence texts, stamps the version and the commit's
date, and zips the package the same way every time. A package built by hand
is stamped `<commit>+local`; CI sets `CORE_VERSION`.

## Test

Rebuild both flavours first: the scripts compare whatever binaries are there.

```
ninja -C build/meson-native && ninja -C build/meson-guest core.wbx

# native == sandbox == savestate every frame, over this repository's own test
# programs; the engine tests run too when CHIMERA_ROOT names a Chimera
# checkout with this package installed
CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh       # 54 ok, 0 failed

# the package in Chimera's window, headless
env -u DISPLAY ./waterbox/tests/run-frontend.sh --chimera-root <chimera>   # 7 ok

# Chimera's contract tests, on a folder holding only this package
mkdir -p build/pkgtest && cp <chimera>/build/Cores/geargrafx.chimeraCore build/pkgtest/
env -u DISPLAY <chimera>/build/meson-linux/source/ui/test-packages build/pkgtest

# games you have, from tests/roms-local (SKIP for each file not there)
./waterbox/tests/run-local.sh
```

The test programs are built at test time by `tests/pce-test/make-pce-test.py`
(see its header): nothing to download, nothing commercial. `.hes` music
files are not accepted (docs/PLAN.md says why).

`run-local.sh` names its games (see the list at its top). Copy them into
`tests/roms-local/` under those names; never link to a folder you do not own.
CD games also need the System Card there as `syscard3.pce`.

## What the user provides

- PC Engine CD: one System Card, chosen by the `systemCard` setting, pinned
  by SHA-1: `syscard3.pce` (Super CD-ROM2 3.0, Japan,
  79F5FF55DD10187C7FD7B8DAAB0B3FFBD1F56A2C), `syscard3u.pce`
  (D02611D99921986147C753DF14C7349B31D71950), `syscard2.pce`
  (88DA02E2503F7C32810F5D93A34849D470742B6D), `syscard2u.pce`
  (2BEA3DAC98F84B2F2F469FA77EA720B8770D598D), `syscard1.pce`
  (A39A66DA7DE6BA94AB84D04EEF7AFEEC7D4EE66A) or the Games Express card
  `gexpress.pce` (014881A959E045E00F4DB8F52955200865D40280).
- The games.

## Troubleshooting

- `extern/geargrafx is not checked out`: run `git submodule update --init`.
- A change to `patches/` is not picked up: put the submodule back with
  `git -C extern/geargrafx checkout .` and set the build folders up again
  (`apply-patches.sh` decides by one marker, `GG_CHIMERA` in `src/defines.h`).
- `miniBox C++ guest toolchain missing`: build `<minibox>/build/meson-cpp`
  as above.
- A step that fails in a fraction of a second with no output on a runner has
  usually failed on stdout: run it again with
  `env HOME=/tmp/empty ./waterbox/build-package.sh -m <minibox> -r <chimera> > /dev/null`.
