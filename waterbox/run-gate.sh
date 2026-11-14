#!/bin/bash
# The core test script: the sandboxed core (core.wbx) must produce
# byte-identical video, audio, lag and memory digests to the native reference
# build (the same cinterface.cpp compiled for the host), must survive a
# whole-machine savestate saved and loaded around every frame, and must be
# the same machine with its drawing switched off (turbo).
#
# The programs it runs are this repository's own, built here from
# tests/pce-test/make-pce-test.py: a HuCard program for the PC Engine and the
# SuperGrafx, and a stand-in for the CD's System Card with a disc made here.
# No NEC firmware and no commercial game is needed; games from
# tests/roms-local run through waterbox/tests/run-local.sh.
#
# Usage: ./waterbox/run-gate.sh [-n <native build dir>] [-g <guest build dir>]
# With CHIMERA_ROOT set (a Chimera checkout with build/dll/chimera-run and this
# core's package in build/Cores), the tests through Chimera's engine run too.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
while getopts "n:g:" opt; do
	case "$opt" in
		n) nat="$OPTARG" ;;
		g) gst="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

[ -x "$nat/run-native" ] && [ -x "$nat/run-wbx" ] || {
	echo "native build missing: meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native" >&2; exit 1; }
[ -f "$gst/core.wbx" ] || {
	echo "guest build missing: sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
roms="$work/roms"
mkdir -p "$roms"
python3 "$root/tests/pce-test/make-pce-test.py" "$roms" || { echo "could not build the test programs" >&2; exit 1; }

digests() { grep -E '^(frames|vsync|videoHash|audioHash|lagFrames|domain\[)'; }
# What a turbo run can be held to: everything but the whole-run video hash,
# which a run that skipped the first half cannot match.
turboDigests() { grep -E '^(frames|vsync|tailVideoHash|audioHash|lagFrames|domain\[)'; }

ok=0
failed=0
report() { printf "%-30s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; SKIP) ;; *) failed=$((failed+1)) ;; esac; }
printf "%-30s %-6s %s\n" "Check" "Result" "Detail"
printf "%-30s %-6s %s\n" "-----" "------" "------"

# workdir <name> <slot> <game file> <settings JSON> [<file>=<mounted name> ...]
# a work dir as a project mounts it: the game under its own name, the slot
# map, the settings, and any firmware under its id
workdir() {
	local wd="$work/$1" slot="$2" game="$3" settings="$4"
	shift 4
	rm -rf "$wd"
	mkdir -p "$wd"
	cp "$roms/$game" "$wd/"
	[ "${game##*.}" = cue ] && cp "$roms/${game%.cue}.iso" "$wd/"
	printf '{"%s":["%s"]}' "$slot" "$game" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	local f
	for f in "$@"; do cp "$roms/${f%%=*}" "$wd/${f#*=}"; done
	echo "$wd"
}

run_nat() { "$nat/run-native" "$@" 2>"$work/err.nat" | digests; }
run_box() { "$nat/run-wbx" "$gst/core.wbx" "$@" 2>"$work/err.box" | digests; }

# equivalence, input-shaped, turbo and savestate for one machine and schedule
legs() {
	local name="$1" wd="$2"
	shift 2
	if ! run_nat "$wd" "$@" > "$work/nat.txt" || ! grep -q '^frames=' "$work/nat.txt"; then
		report "$name:equivalence" FAIL "native runner error: $(grep -v '^\[\|^[A-Z]' "$work/err.nat" | head -1)$(tail -1 "$work/err.nat")"; return
	fi
	if ! run_box "$wd" "$@" > "$work/box.txt" || ! grep -q '^frames=' "$work/box.txt"; then
		report "$name:equivalence" FAIL "sandbox runner error: $(tail -1 "$work/err.box")"; return
	fi
	local frames
	frames="$(sed -n 's/^frames=//p' "$work/box.txt")"
	cp "$work/box.txt" "$work/box.$name.txt"
	if cmp -s "$work/nat.txt" "$work/box.txt"; then
		report "$name:equivalence" PASS "$frames frames, native == sandbox ($(grep -c '^domain' "$work/box.txt") memory domains)"
	else
		report "$name:equivalence" FAIL "$(diff "$work/nat.txt" "$work/box.txt" | tr '\n' ' ' | head -c 120)"
		return
	fi

	# the input schedule must have shaped the machine: an idle run of the same
	# length must differ, or the comparison above proved nothing about input
	run_box "$wd" --frames "$frames" > "$work/idle.txt"
	if cmp -s "$work/box.txt" "$work/idle.txt"; then
		report "$name:input-shaped" FAIL "the input changed nothing"
	else
		report "$name:input-shaped" PASS "the input visibly shaped the machine"
	fi

	# Turbo: drawing off for the first half, on for the second. The machine,
	# the sound, the lag count and the second half's pictures must be what
	# they would have been, and the whole-run picture hash must differ (or
	# nothing was skipped).
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" 2>/dev/null > "$work/tnorm.raw"
	if "$nat/run-wbx" "$gst/core.wbx" "$wd" "$@" --turbo 2>/dev/null > "$work/tturbo.raw"; then
		turboDigests < "$work/tnorm.raw" > "$work/tnorm.txt"
		turboDigests < "$work/tturbo.raw" > "$work/turbo.txt"
		local nvh tvh
		nvh="$(grep -m1 '^videoHash=' "$work/tnorm.raw")"
		tvh="$(grep -m1 '^videoHash=' "$work/tturbo.raw")"
		if ! cmp -s "$work/tnorm.txt" "$work/turbo.txt"; then
			report "$name:turbo" FAIL "$(diff "$work/tnorm.txt" "$work/turbo.txt" | tr '\n' ' ' | head -c 120)"
		elif [ -z "$nvh" ] || [ "$nvh" = "$tvh" ]; then
			report "$name:turbo" FAIL "the turbo run drew every frame - nothing was skipped"
		else
			report "$name:turbo" PASS "half of $frames frames undrawn, same machine and same pictures after"
		fi
	else
		report "$name:turbo" FAIL "turbo runner error"
	fi

	# a savestate saved and loaded before every frame changes nothing
	if ! run_box "$wd" "$@" --rerecord > "$work/rr.txt" || ! grep -q '^frames=' "$work/rr.txt"; then
		report "$name:savestate" FAIL "rerecord runner error: $(tail -1 "$work/err.box")"; return
	fi
	if cmp -s "$work/box.txt" "$work/rr.txt"; then
		report "$name:savestate" PASS "a savestate saved and loaded before every frame changes nothing"
	else
		report "$name:savestate" FAIL "$(diff "$work/box.txt" "$work/rr.txt" | tr '\n' ' ' | head -c 120)"
	fi
}

# unlike <name> <wd> <settings that must build another machine> <what it is> <args...>
# Both sides of an equivalence test are built from the same settings, so it
# says the two builds agree and nothing about WHAT they built. Each setting
# under test is also held to a machine it must not be.
unlike() {
	local name="$1" wd="$2" other="$3" what="$4"
	shift 4
	local mine
	mine="$(cat "$wd/settings")"
	printf '%s' "$other" > "$wd/settings"
	run_box "$wd" "$@" > "$work/other.txt"
	printf '%s' "$mine" > "$wd/settings"
	if [ ! -s "$work/other.txt" ]; then
		report "$name:not-$what" FAIL "the other machine did not run"
	elif cmp -s "$work/box.$name.txt" "$work/other.txt"; then
		report "$name:not-$what" FAIL "it built the same machine as $what: did the setting reach the core?"
	else
		report "$name:not-$what" PASS "a different machine from $what"
	fi
}

ex=(--frames 600 --exercise)

# ---- the PC Engine: one pad ----
wd="$(workdir pce card pce-test.pce '{"machine":"pce"}')"
legs pce "$wd" "${ex[@]}"

# ---- five pads through the TurboTap: pad 3 is driven too ----
wd="$(workdir tap card pce-test.pce '{"machine":"pce","turboTap":true}')"
legs tap "$wd" "${ex[@]}" --exercise-pad 3
unlike tap "$wd" '{"machine":"pce","turboTap":false}' "no TurboTap" "${ex[@]}" --exercise-pad 3

# ---- the Avenue Pad 6: the program reads the port twice a frame ----
wd="$(workdir pad6 card pce-pad6.pce '{"machine":"pce","port1":"avenuePad6"}')"
legs pad6 "$wd" "${ex[@]}"
unlike pad6 "$wd" '{"machine":"pce","port1":"pad"}' "a two-button pad" "${ex[@]}"

# ---- the mouse in port 1 ----
wd="$(workdir mouse card pce-test.pce '{"machine":"pce","port1":"mouse"}')"
legs mouse "$wd" "${ex[@]}" --wiggle-axes
unlike mouse "$wd" '{"machine":"pce","port1":"pad"}' "a pad" "${ex[@]}" --wiggle-axes

# ---- each button is the console's button it is named for ----
# The tests above compare two builds of the same adapter, so a button wired
# to the wrong key passes them. The test program keeps what it reads: RAM
# $10-$14 the five pads (I II Select Run on bits 0-3, Up Right Down Left on
# bits 4-7) and, for the Avenue Pad 6, $18 its other half (III IV V VI on
# bits 0-3). Each button is held alone and the byte must have its bit. Where
# the upper half reads 1111, that half of the port is not a pad's directions:
# the Avenue Pad 6's other half, and the mouse's movement (none here).
# buttons <name> <workdir> <RAM offset> <first wire index> <names:bits...>
buttons() {
	local name="$1" wd="$2" at="$3" first="$4"
	shift 4
	local i=0 bad="" b want got
	for b in "$@"; do
		want="${b#*:}"
		"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 20 --hold $((first + i)) \
			--dump-domain "Work RAM" "$work/btn.ram" > /dev/null 2>&1
		got="$(python3 -c "import sys; print(open(sys.argv[1],'rb').read()[int(sys.argv[2])])" "$work/btn.ram" "$at" 2>/dev/null)"
		[ "$got" = "$want" ] || bad="$bad ${b%%:*}=${got:-?}(want $want)"
		i=$((i + 1))
	done
	if [ -z "$bad" ]; then
		report "$name:buttons" PASS "$# buttons, each read by the game as itself"
	else
		report "$name:buttons" FAIL "$bad"
	fi
}
wd="$(workdir btn card pce-test.pce '{"machine":"pce"}')"
buttons pce "$wd" 16 1 Up:16 Down:64 Left:128 Right:32 I:1 II:2 Select:4 Run:8
wd="$(workdir btntap card pce-test.pce '{"machine":"pce","turboTap":true}')"
buttons tap "$wd" 18 25 Up:16 Down:64 Left:128 Right:32 I:1 II:2 Select:4 Run:8
wd="$(workdir btn6 card pce-pad6.pce '{"machine":"pce","port1":"avenuePad6"}')"
buttons pad6 "$wd" 24 9 III:241 IV:242 V:244 VI:248
wd="$(workdir btnmouse card pce-test.pce '{"machine":"pce","port1":"mouse"}')"
buttons mouse "$wd" 16 61 "Mouse Left":242 "Mouse Right":241

# ---- the SuperGrafx ----
wd="$(workdir sgx card sgx-test.sgx '{"machine":"sgx"}')"
legs sgx "$wd" "${ex[@]}"
# The program writes a word through the second video chip's ports. On a
# SuperGrafx that is the second chip; on a PC Engine the same ports reach the
# first chip again. So the SuperGrafx must have a "VRAM 2", and the PC Engine
# machine given the same .sgx file must not be a SuperGrafx at all.
if grep -q '^domain\[VRAM 2\]' "$work/box.sgx.txt" && grep -q 'machine=sgx sgx=1' "$work/err.box"; then
	printf '{"machine":"pce"}' > "$wd/settings"
	run_box "$wd" --frames 60 > "$work/sgxpce.txt"
	if grep -q 'machine=pce sgx=0' "$work/err.box" && ! grep -q '^domain\[VRAM 2\]' "$work/sgxpce.txt"; then
		report "sgx:second-vdc" PASS "the SuperGrafx has its second video chip; the PC Engine given the same file has not"
	else
		report "sgx:second-vdc" FAIL "the PC Engine machine became a SuperGrafx for a .sgx file"
	fi
else
	report "sgx:second-vdc" FAIL "the SuperGrafx machine has no second video chip"
fi

# ---- the PC Engine CD, with this repository's stand-in System Card ----
wd="$(workdir pcecd disc cd-test.cue '{"machine":"pcecd"}' cd-card.pce=syscard)"
legs pcecd "$wd" "${ex[@]}"
# the stand-in reads sectors of the disc into RAM $0200: the first 4 bytes of
# a sector are "GGT" and its number, and RAM $02 counts the sectors read
"$nat/run-wbx" "$gst/core.wbx" "$wd" "${ex[@]}" --dump-domain "Work RAM" "$work/cd.ram" > /dev/null 2>&1
read -r reads tag <<< "$(python3 - "$work/cd.ram" <<'PY'
import sys
r = open(sys.argv[1], "rb").read()
print(r[2], r[0x200:0x203].decode("latin-1") + "/" + str(r[0x203]))
PY
)"
if [ "${tag%%/*}" = GGT ] && [ "${reads:-0}" -ge 5 ]; then
	report "pcecd:disc-read" PASS "the card read $reads sectors from the disc, the last sector ${tag#*/}"
else
	report "pcecd:disc-read" FAIL "no sector of the disc reached the machine (reads=${reads:-?}, '$tag')"
fi
unlike pcecd "$wd" '{"machine":"pcecd","cdromType":"standard"}' "a CD-ROM2 with no Super System card RAM" "${ex[@]}"
# a disc with no card in the slot is refused, and says why
rm -f "$wd/syscard"
if "$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 5 > /dev/null 2> "$work/nocard.err"; then
	report "pcecd:card-required" FAIL "a disc started with no System Card"
elif grep -q 'error.no_card' "$work/nocard.err"; then
	report "pcecd:card-required" PASS "a disc with no System Card is refused with error.no_card"
else
	report "pcecd:card-required" FAIL "refused, but not for the card: $(tail -1 "$work/nocard.err")"
fi

# ---- the LaserActive: no disc image or PAC BIOS is free to hand out, so
# only the refusal without the PAC BIOS is tested ----
wd="$(workdir la laserdisc cd-test.cue '{"machine":"laseractive"}')"
printf '{"laserdisc":["cd-test.cue"]}' > "$wd/slots"
if "$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 5 > /dev/null 2> "$work/nopac.err"; then
	report "laseractive:pac-required" FAIL "a LaserActive started with no PAC BIOS"
elif grep -q 'error.no_pac' "$work/nopac.err"; then
	report "laseractive:pac-required" PASS "a LaserActive with no PAC BIOS is refused with error.no_pac"
else
	report "laseractive:pac-required" FAIL "refused, but not for the PAC BIOS: $(tail -1 "$work/nopac.err")"
fi

# ---- what the machine is at power on: a seed the project pins ----
wd="$(workdir seed card pce-test.pce '{"machine":"pce","randomSeed":1}')"
run_nat "$wd" --frames 60 > "$work/s1n.txt"
run_box "$wd" --frames 60 > "$work/s1b.txt"
printf '{"machine":"pce"}' > "$wd/settings"
run_box "$wd" --frames 60 > "$work/s0b.txt"
printf '{"machine":"pce","powerOn":"zero"}' > "$wd/settings"
run_box "$wd" --frames 60 > "$work/szb.txt"
if ! cmp -s "$work/s1n.txt" "$work/s1b.txt"; then
	report "power-on:seed" FAIL "native and sandbox differ for seed 1"
elif cmp -s "$work/s1b.txt" "$work/s0b.txt" || cmp -s "$work/s0b.txt" "$work/szb.txt"; then
	report "power-on:seed" FAIL "the seed or the zero power-on state changed nothing"
else
	report "power-on:seed" PASS "seed 1, the default seed and the zero state are three machines; native == sandbox"
fi

# ---- the Power button ----
wd="$(workdir power card pce-test.pce '{"machine":"pce"}')"
legs power "$wd" "${ex[@]}" --power-at 300
if cmp -s "$work/box.power.txt" "$work/box.pce.txt"; then
	report "power:reset" FAIL "pressing Power at frame 300 changed nothing"
else
	report "power:reset" PASS "Power at frame 300 restarts the machine"
fi

# ---- saved games: the backup memory, out and in ----
wd="$(workdir sd card pce-test.pce '{"machine":"pce"}')"
python3 -c "import sys; open(sys.argv[1],'wb').write(bytes((i*13+7)&255 for i in range(2048)))" "$wd/game.brm"
printf '{"card":["pce-test.pce"],"savedata":["game.brm"]}' > "$wd/slots"
mkdir -p "$work/sd.nat" "$work/sd.box"
"$nat/run-native" "$wd" --frames 120 --exercise --savedata-out "$work/sd.nat" > /dev/null 2>&1
"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames 120 --exercise --savedata-out "$work/sd.box" > /dev/null 2>&1
if [ ! -s "$work/sd.box/backup.brm" ]; then
	report "savedata:export" FAIL "no backup memory was exported"
elif ! diff -r "$work/sd.nat" "$work/sd.box" > /dev/null 2>&1; then
	report "savedata:export" FAIL "the native and sandbox exports differ"
elif ! cmp -s -n 2048 "$wd/game.brm" "$work/sd.box/backup.brm"; then
	report "savedata:export" FAIL "the backup memory exported is not the saved game the project started from"
else
	report "savedata:export" PASS "the saved game given goes into the backup memory and comes out again; native == sandbox"
fi

# ------------------------------------------------- Chimera's engine
# Each read of the controllers is reported to Chimera as it happens, so a Lua
# script's event.oninputpoll runs there (chimera#344). Needs CHIMERA_ROOT, a
# Chimera checkout with this core's package installed in it.
runner="${CHIMERA_ROOT:-}/build/dll/chimera-run"
package="${CHIMERA_ROOT:-}/build/Cores/geargrafx.chimeraCore"
if [ -n "${CHIMERA_ROOT:-}" ] && [ -x "$runner" ] && [ -f "$package" ]; then
	cart="$roms/pce-test.pce"
	"$runner" --new-project "$work/none.chimeraProject" "$package" "$cart" > "$work/none.make.log" 2>&1
	"$runner" --project "$work/none.chimeraProject" "$package" --files "$roms" \
		--frames 300 --record "$work/idle.txt" > "$work/idle.log" 2>&1
	"$runner" --new-project "$work/idle.chimeraProject" "$package" "$cart" "$work/idle.txt" > "$work/idle.make.log" 2>&1
	"$runner" --project "$work/idle.chimeraProject" "$package" --files "$roms" \
		--dump "Work RAM=$work/plain.ram" > "$work/plain.log" 2>&1
	"$runner" --project "$work/idle.chimeraProject" "$package" --files "$roms" --count-input-polls \
		--dump "Work RAM=$work/polls.ram" --meta "$work/polls.meta" > "$work/polls.log" 2>&1
	polls=$(sed -n 's/^inputPolls=//p' "$work/polls.meta" 2> /dev/null)
	lags=$(sed -n 's/^lagFrames=//p' "$work/polls.meta" 2> /dev/null)
	frames=$(sed -n 's/^frames=//p' "$work/polls.meta" 2> /dev/null)
	if [ "${polls:-none}" != none ] && [ "${frames:-0}" = 300 ] && [ "${lags:-300}" -lt 300 ] \
		&& [ "${polls:-0}" -ge $(( 300 - ${lags:-300} )) ] && [ -s "$work/plain.ram" ] && cmp -s "$work/plain.ram" "$work/polls.ram"; then
		report "engine:input-polls" PASS "$polls reads of the controllers in 300 frames reach Chimera, $lags lag frames; counting them moved nothing"
	else
		report "engine:input-polls" FAIL "inputPolls=${polls:-missing} frames=${frames:-?} lagFrames=${lags:-?}, or counting moved Work RAM; the runner said: $(tail -1 "$work/polls.log" 2> /dev/null)"
	fi
else
	report "engine:input-polls" SKIP "needs CHIMERA_ROOT with build/dll/chimera-run and build/Cores/geargrafx.chimeraCore"
fi

echo ""
echo "$ok ok, $failed failed"
[ "$failed" -gt 0 ] && exit 1
exit 0
