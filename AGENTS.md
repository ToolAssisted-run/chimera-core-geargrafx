# AGENTS.md - Geargrafx core for Chimera

This repository builds upstream Geargrafx as a sandboxed guest for Chimera,
a frontend for tool-assisted speedruns. It produces one file,
`geargrafx.chimeraCore`: a zip of `core.wbx` (the emulator built for the
miniBox sandbox), `waterbox.config`, `file_slots.json`,
`default_keybinds.json`, `languages/`, `build.json` and the licence texts.
`docs/BUILDING.md` is the full build; `docs/PLAN.md` is the design log.

## Layout

- `extern/geargrafx/` - upstream, a submodule pinned to release 1.8.7, never
  edited in place.
- `patches/0001-chimera-hooks.patch` - every change to upstream, all under
  `GG_CHIMERA`: the power-on seed from a setting, the controller-read hook,
  the PC Engine machine never a SuperGrafx, and bounded disc caches.
- `meson.build` - one build, two flavours: native (`run-native`, `run-wbx`)
  and guest (`core.wbx`). The source list is upstream's libretro core's
  without `libretro.cpp`.
- `waterbox/cinterface.cpp` - the adapter: Geargrafx behind Chimera's guest
  ABI, compiled unchanged into both flavours.
- `waterbox/run-native.c`, `run-wbx.c`, `gate-harness.h`,
  `native-shim/emulibc.h` - the reference driver, the sandbox driver, and
  the loop they share.
- `waterbox/waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json`, `languages/*.json` - what the package declares.
- `waterbox/apply-patches.sh`, `setup-guest.sh`, `build-package.sh` - build
  scripts.
- `waterbox/run-gate.sh` - the core test script. `waterbox/tests/` - the
  frontend test script (`run-frontend.sh` and its Lua and Python helpers)
  and the local games script (`run-local.sh`).
- `tests/pce-test/make-pce-test.py` - builds the test programs at test time.
- `tests/roms-local/` - games and firmware for `run-local.sh`; gitignored.
- `build/` - every output; gitignored.

## Commands, in order

```
MB=<chimera>/extern/chimera-common-minibox
meson setup $MB/build/meson-cpp $MB -Dguest_cpp=true && meson compile -C $MB/build/meson-cpp
meson setup build/meson-native -Dminibox_dir=$MB && ninja -C build/meson-native
sh waterbox/setup-guest.sh -m $MB && ninja -C build/meson-guest core.wbx
./waterbox/build-package.sh -m $MB -r <chimera>
CHIMERA_ROOT=<chimera> ./waterbox/run-gate.sh              # 44 ok, 0 failed
env -u DISPLAY ./waterbox/tests/run-frontend.sh --chimera-root <chimera>   # 6 ok
./waterbox/tests/run-local.sh                              # SKIPs what is not in tests/roms-local
```

Rebuild both flavours before a test script: they compare whatever is built.

## Rules of this repository

- Upstream is a pinned submodule. A change to it is a numbered patch in
  `patches/`, under `GG_CHIMERA`. After changing `patches/`, run
  `git -C extern/geargrafx checkout .` before the next configure.
- Determinism is the product: nothing may read a host clock, host randomness
  or anything else that differs between runs, and a savestate must round
  trip. The core test script checks it.
- A new test is broken on purpose once and seen to fail; say so in the
  commit.
- Every text a person reads is a key of `waterbox/languages/*.json`, in all
  26 languages, in the same commit. Check with Chimera's
  `tools/check-core-texts.py <this checkout>`.
- No game, BIOS or firmware is committed or uploaded. Test content that may
  not be passed on stays in `tests/roms-local/`, copied, never linked.
- No network code.
- Do not write `version` or `versionDate` into `waterbox.config`:
  `build-package.sh` stamps them.
- Prose is plain ASCII and plain language. Commits: `type(scope): what
  changed`, a short body with what was tested and the numbers.
- Shell scripts stay executable (mode 100755).
