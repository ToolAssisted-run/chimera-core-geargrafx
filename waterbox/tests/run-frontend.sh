#!/bin/bash
# The frontend test script: the Geargrafx package in Chimera's window, run
# headless (no display), through projects made with chimera-run
# --new-project, as a person's games are. Each machine is booted from this
# repository's own test programs (tests/pce-test/make-pce-test.py) and its
# Work RAM must be byte-identical to the native reference's after the same
# frames:
#   pce:frontend      the PC Engine, nothing pressed
#   input:frontend    P1 Right and P1 Run held by a Lua script through TAStudio
#   settings:powerOn  a project setting (powerOn=zero) reaches the machine
#   sgx:frontend      the SuperGrafx machine
#   pcecd:frontend    the PC Engine CD, with the stand-in System Card given as
#                     the project's firmware
#   chd:frontend      the same disc as one .chd file
#   keybinds          the package's key bindings are the window's when nobody
#                     changed them
#
# Usage: ./run-frontend.sh [--chimera-root <path>] [--frames N]
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
frames=300
chimera_root=""
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera-root) chimera_root="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) break ;;
	esac
	shift
done

if [ -z "$chimera_root" ] && [ -d "$root/../chimera" ]; then
	chimera_root="$root/../chimera"
fi
[ -n "$chimera_root" ] && [ -d "$chimera_root" ] || {
	echo "chimera checkout not found; pass --chimera-root <path>" >&2; exit 1; }
chimera_root="$(cd "$chimera_root" && pwd)"

chimera_exe="$chimera_root/build/meson-linux/source/ui/chimera"
crun="$chimera_root/build/dll/chimera-run"
package="$chimera_root/build/Cores/geargrafx.chimeraCore"
rn="$root/build/meson-native/run-native"
[ -x "$chimera_exe" ] || { echo "Chimera not built: $chimera_exe" >&2; exit 1; }
[ -x "$crun" ] || { echo "chimera-run not built: $crun" >&2; exit 1; }
[ -f "$package" ] || { echo "package not installed: $package (run ../build-package.sh)" >&2; exit 1; }
[ -x "$rn" ] || { echo "native reference not built" >&2; exit 1; }

work="$here/work"
rm -rf "$work"
mkdir -p "$work/roms"
python3 "$root/tests/pce-test/make-pce-test.py" "$work/roms" || exit 1

# Chimera's window, run headless: the cores installed in the checkout, its
# settings, cache and recovery files the run's own, and nothing carried over
# from a Chimera installed on this machine
export ALSOFT_DRIVERS=null CHIMERA_CORES_DIR="$chimera_root/build/Cores" CHIMERA_QT_CACHE="$work/qt-cache" CHIMERA_QT_RECOVERY="$work/qt-recovery" \
	CHIMERA_QT_HASHES="$work/qt-file-hashes.txt" CHIMERA_QT_CHIMERA_SETTINGS="$work/no-chimera-config.ini"

ok=0
failed=0
report() { printf "%-28s %-9s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-28s %-9s %s\n" "Check" "Result" "Detail"
printf "%-28s %-9s %s\n" "-----" "------" "------"

# make_project <tag> <settings JSON> <slot>=<file> [firmware id=file]
# A game runs only in a project (Chimera, 2026-10-26): one made with
# chimera-run --new-project, as a person's are.
make_project() {
	local tag="$1" settings="$2" file="$3" fw="${4:-}"
	local dir="$work/project.$tag"
	rm -rf "$dir" && mkdir -p "$dir"
	# the game beside the project, where the window looks for it
	local game="${file#*=}"
	cp "$work/roms/$game" "$dir/"
	[ "${game##*.}" = cue ] && cp "$work/roms/${game%.cue}.iso" "$dir/"
	local args=(--new-project "$dir/$tag.chimeraProject" "$package" --settings "$settings" --file "${file%%=*}=$dir/$game")
	[ -n "$fw" ] && args+=(--firmware "${fw%%=*}=$work/roms/${fw#*=}")
	"$crun" "${args[@]}" > "$dir/make.log" 2>&1 && echo "$dir/$tag.chimeraProject"
}

# run_frontend <tag> <project> <window settings file> <system id> [held buttons]
run_frontend() {
	local tag="$1" project="$2" cfg="$3" system="$4" hold="${5:-}"
	local job="$work/job.$tag.txt"
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\nhold=%s\nsystem=%s\n' "$frames" "$work/$tag.ram.bin" "$work/$tag.meta.txt" "$hold" "$system" > "$job"
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$cfg" "--core=$package" \
		"--lua=$here/frontend-ram.lua" "--project=$project" ) > "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}

# native_ram <tag> <slot> <file> <settings JSON> [hold] [firmware file]
# the native reference over the same files, settings and frames
native_ram() {
	local tag="$1" slot="$2" file="$3" settings="$4" hold="${5:-}" fw="${6:-}"
	local wd="$work/native.$tag"
	rm -rf "$wd" && mkdir -p "$wd"
	cp "$work/roms/$file" "$wd/"
	[ "${file##*.}" = cue ] && cp "$work/roms/${file%.cue}.iso" "$wd/"
	[ -n "$fw" ] && cp "$work/roms/$fw" "$wd/syscard"
	printf '{"%s":["%s"]}' "$slot" "$file" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	local extra=(--frames "$frames")
	[ -n "$hold" ] && extra+=(--hold "$hold")
	"$rn" "$wd" "${extra[@]}" --dump-domain "Work RAM" "$work/native.$tag.ram.bin" > "$work/native.$tag.txt" 2>&1
}

# frontend_leg <name> <tag> <machine settings> <slot> <file> <system> [lua hold] [wire hold] [firmware file]
frontend_leg() {
	local name="$1" tag="$2" settings="$3" slot="$4" file="$5" system="$6" luahold="${7:-}" wirehold="${8:-}" fw="${9:-}"
	local project cfg="$work/settings.$tag.json"
	if [ -n "$fw" ]; then
		python3 "$here/settings-config.py" "$cfg" '{}' "{\"syscard\": \"$work/roms/$fw\"}"
	else
		python3 "$here/settings-config.py" "$cfg" '{}'
	fi
	if ! native_ram "$tag" "$slot" "$file" "$settings" "$wirehold" "$fw"; then
		report "$name" FAIL "native runner error (see tests/work/native.$tag.txt)"; return 1
	fi
	if ! project="$(make_project "$tag" "$settings" "$slot=$file" "${fw:+syscard=$fw}")"; then
		report "$name" FAIL "no project made (see tests/work/project.$tag/make.log)"; return 1
	fi
	if ! run_frontend "$tag" "$project" "$cfg" "$system" "$luahold"; then
		report "$name" FAIL "the window did not report OK (see tests/work/$tag.log)"; return 1
	fi
	if ! cmp -s "$work/native.$tag.ram.bin" "$work/$tag.ram.bin"; then
		report "$name" FAIL "Work RAM differs from the native reference"; return 1
	fi
	return 0
}

if frontend_leg "pce:frontend" base '{"machine":"pce"}' card pce-test.pce PCE; then
	report "pce:frontend" PASS "$frames frames, Work RAM identical to the native reference"
fi

# held through TAStudio by the Lua script; the native twin holds wire 4 (P1
# Right) and 8 (P1 Run)
if frontend_leg "input:frontend" hold '{"machine":"pce"}' card pce-test.pce PCE "P1 Right,P1 Run" "4,8"; then
	if cmp -s "$work/hold.ram.bin" "$work/base.ram.bin"; then
		report "input:frontend" FAIL "holding the buttons changed nothing"
	else
		report "input:frontend" PASS "P1 Right and P1 Run through the window match the native twin"
	fi
fi

if frontend_leg "settings:powerOn" zero '{"machine":"pce","powerOn":"zero"}' card pce-test.pce PCE; then
	if cmp -s "$work/zero.ram.bin" "$work/base.ram.bin"; then
		report "settings:powerOn" FAIL "powerOn=zero built the same machine as the default"
	else
		report "settings:powerOn" PASS "the project's powerOn=zero reached the machine, which matches its native reference"
	fi
fi

if frontend_leg "sgx:frontend" sgx '{"machine":"sgx"}' card sgx-test.sgx SGX; then
	report "sgx:frontend" PASS "$frames frames of the SuperGrafx, Work RAM identical to the native reference"
fi

if frontend_leg "pcecd:frontend" cd '{"machine":"pcecd"}' disc cd-test.cue PCECD "" "" cd-card.pce; then
	if python3 -c "import sys; r=open(sys.argv[1],'rb').read(); sys.exit(0 if r[0x200:0x203]==b'GGT' else 1)" "$work/cd.ram.bin"; then
		report "pcecd:frontend" PASS "$frames frames of the CD machine with the stand-in card; the disc was read; Work RAM identical to the native reference"
	else
		report "pcecd:frontend" FAIL "the same as the native reference, but no sector of the disc was read"
	fi
fi

if [ -f "$work/roms/cd-test.chd" ]; then
	if frontend_leg "chd:frontend" chd '{"machine":"pcecd"}' disc cd-test.chd PCECD "" "" cd-card.pce; then
		if cmp -s "$work/chd.ram.bin" "$work/cd.ram.bin"; then
			report "chd:frontend" PASS "the same disc as one .chd file: Work RAM identical to the native reference and to the .cue run"
		else
			report "chd:frontend" FAIL "the same as its native reference, but not the machine the .cue disc made"
		fi
	fi
else
	report "chd:frontend" FAIL "no chdman (install mame-tools) to make the .chd"
fi

# --- the bindings the package ships are the machine's when nobody changed them ---
python3 "$here/settings-config.py" "$work/settings.keys.json" '{}'
job="$work/job.keys.txt"
printf 'out=%s/keys.controls.json\nmeta=%s/keys.meta.txt\n' "$work" "$work" > "$job"
if project="$(make_project keys '{"machine":"pce"}' card=pce-test.pce)" && \
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout -s KILL 900 "$chimera_exe" --headless \
		"--config=$work/settings.keys.json" "--core=$package" \
		"--lua=$here/dump-controls.lua" "--project=$project" ) > "$work/keys.log" 2>&1 && \
	grep -q "^status=OK" "$work/keys.meta.txt" 2>/dev/null; then
	if python3 "$here/check-keybinds.py" "$work/keys.controls.json" \
		"$wb/default_keybinds.json" "PC Engine Controller" > "$work/keys.txt" 2>&1; then
		report "keybinds" PASS "$(cat "$work/keys.txt")"
	else
		report "keybinds" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "keybinds" FAIL "run did not report OK (see tests/work/keys.log)"
fi

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
