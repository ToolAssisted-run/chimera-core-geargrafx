# chimera-core-geargrafx: Geargrafx (PC Engine / TurboGrafx-16, SuperGrafx,
# CD-ROM2, LaserActive) in miniBox's sandbox, as a Chimera core.
#
# Native reference build (run-native, and run-wbx, which links miniBox's host
# library out of the same meson-cpp build dir):
#     meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
# Guest (core.wbx) build through the cross file waterbox/setup-guest.sh writes
# (needs miniBox's C++ guest toolchain, build/meson-cpp):
#     sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest core.wbx
#
# The source list is upstream's libretro core's (platforms/libretro/
# Makefile.common) without the libretro frontend itself (libretro.cpp): the
# emulator and the libraries it reads discs with. Nothing of the desktop
# program (SDL, ImGui, the debugger, the MCP server) is built.
# Both flavors compile the SAME waterbox/cinterface.cpp; only emulibc.h differs.
project('chimera-core-geargrafx', ['c', 'cpp'],
  default_options: ['c_std=gnu99', 'cpp_std=c++17', 'optimization=2', 'debug=false', 'warning_level=0'])

gg = 'extern/geargrafx'
src = gg / 'src'
deps = gg / 'platforms/shared/dependencies'

# the submodule is unmodified upstream; meson applies patches/ at configure
run_command(files('waterbox/apply-patches.sh'), check: true)

mb = get_option('minibox_dir')
if mb == ''
  mb_candidate = meson.current_source_dir() / '../chimera/extern/chimera-common-minibox'
  if import('fs').is_dir(mb_candidate)
    mb = mb_candidate
  else
    error('pass -Dminibox_dir=<miniBox checkout> (or keep one at ../chimera/extern/chimera-common-minibox)')
  endif
endif

# What upstream's libretro build defines (platforms/libretro/Makefile), and:
# GG_CHIMERA turns on patches/0001's hooks; GG_DISABLE_MMI_THREADS makes the
# LaserActive's video decoder run on the one thread; MINIZ_NO_TIME keeps
# miniz from reading the clock. GG_ENABLE_CDROM_CUEBIN_READAHEAD (a reader
# thread) and GG_ENABLE_PHYSICAL_CDROM (a real drive) stay off.
defs = [
  '-DNDEBUG',
  '-D__LIBRETRO__',
  '-DGG_CHIMERA',
  '-DGG_DISABLE_DISASSEMBLER',
  '-DGG_DISABLE_VGMRECORDER',
  '-DGG_DISABLE_MMI_THREADS',
  '-DZ7_ST',
  '-DZSTD_DISABLE_ASM',
  '-DMINIZ_NO_TIME',
  '-DEMULATOR_BUILD="1.8.7"',
]
add_project_arguments(defs + ['-fno-strict-aliasing', '-w'], language: ['c', 'cpp'])
# On aarch64 GCC fuses a multiply and an add into one instruction unless told
# not to, which rounds once where the guest (built with -ffp-contract=off)
# rounds twice. Both keep them apart; x86-64 is unchanged.
if not meson.is_cross_build() and host_machine.cpu_family() == 'aarch64'
  add_project_arguments('-ffp-contract=off', language: ['c', 'cpp'])
endif

inc = include_directories(
  'waterbox',
  src,
  gg / 'platforms/libretro',
  deps / 'minivorbis',
  deps / 'miniz',
  deps / 'json',
  deps / 'qon',
  deps / 'libchdr/include',
  deps / 'zstd',
  deps / 'lzma/include',
)

core_sources = files(
  deps / 'miniz/miniz.c',
  deps / 'libchdr/src/libchdr_bitstream.c',
  deps / 'libchdr/src/libchdr_cdrom.c',
  deps / 'libchdr/src/libchdr_chd.c',
  deps / 'libchdr/src/libchdr_flac.c',
  deps / 'libchdr/src/libchdr_huffman.c',
  deps / 'lzma/src/LzFind.c',
  deps / 'lzma/src/LzmaEnc.c',
  deps / 'lzma/src/LzmaDec.c',
  deps / 'lzma/src/CpuArch.c',
  deps / 'minivorbis/minivorbis.c',
  deps / 'qon/qon.cpp',
  src / 'geargrafx_core.cpp',
  src / 'adpcm.cpp',
  src / 'audio.cpp',
  src / 'arcade_card_mapper.cpp',
  src / 'cdrom_audio.cpp',
  src / 'cdrom_chd_file_adapter.cpp',
  src / 'cdrom_chd_image.cpp',
  src / 'cdrom_cuebin_image.cpp',
  src / 'cdrom_mmi_image.cpp',
  src / 'media_file.cpp',
  src / 'media_file_libretro.cpp',
  gg / 'platforms/libretro/libretro_vfs_file.cpp',
  src / 'media_file_native.cpp',
  src / 'media_file_slice.cpp',
  src / 'mmi_archive.cpp',
  src / 'ogg_vorbis_decoder.cpp',
  src / 'cdrom_image.cpp',
  src / 'cdrom_media.cpp',
  src / 'cdrom.cpp',
  src / 'huc6202.cpp',
  src / 'huc6260.cpp',
  src / 'huc6270.cpp',
  src / 'huc6280.cpp',
  src / 'huc6280_functors.cpp',
  src / 'huc6280_opcodes.cpp',
  src / 'huc6280_psg.cpp',
  src / 'input.cpp',
  src / 'laseractive.cpp',
  src / 'load_detector.cpp',
  src / 'mapper.cpp',
  src / 'mb128.cpp',
  src / 'media.cpp',
  src / 'memory.cpp',
  src / 'scsi_controller.cpp',
  src / 'sf2_mapper.cpp',
  src / 'trace_logger.cpp',
  src / 'profiler.cpp',
  src / 'turbolink.cpp',
  src / 'vgm_recorder.cpp',
  'waterbox/cinterface.cpp',
)

if meson.is_cross_build()
  # ---- the guest: core.wbx --------------------------------------------------
  # miniBox's musl/libstdc++ toolchain arrives through the cross file; the
  # link recipe is the C++ guest kit's (cxxglue for the unwinder, weak
  # pthread pulls for libgcc_eh), as chimera-core-snes9x links.
  mbdir = meson.get_external_property('minibox_dir')
  mbuild = meson.get_external_property('minibox_build')
  sr = meson.get_external_property('guest_sysroot')

  executable('core', core_sources,
    name_suffix: 'wbx',
    include_directories: inc,
    link_args: [
      '-static', '-no-pie',
      '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax', '-Wl,-z,stack-size=8388608',
      '-T', mbdir / 'source/guest/linkscript.T',
      '-Wl,-u,pthread_once', '-Wl,-u,pthread_cond_wait',
      '-Wl,-u,pthread_cond_broadcast', '-Wl,-u,pthread_key_create',
      mbuild / 'source/guest/cxxglue.c.o',
      mbuild / 'source/guest/emulibc.c.o',
      '-L' + sr / 'lib', '-lstdc++', '-lgcc', '-lgcc_eh', '-lc'])
else
  # ---- the native reference -------------------------------------------------
  m = meson.get_compiler('c').find_library('m', required: false)
  executable('run-native', core_sources + files('waterbox/run-native.c'),
    include_directories: [include_directories('waterbox/native-shim'), inc],
    c_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    cpp_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    dependencies: [m])

  # The host library comes from the SAME miniBox build dir the guest toolchain
  # does (meson-cpp, the C++ kit).
  mbhost = mb / 'build/meson-cpp/source/host'
  executable('run-wbx', files('waterbox/run-wbx.c'),
    c_args: ['-I' + mb / 'source/host'],
    link_args: [mbhost / 'libminiboxhost.so', '-Wl,-rpath,' + mbhost])
endif
