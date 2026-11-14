#!/bin/bash
# Real games, from tests/roms-local (gitignored: games and firmware that may
# not be passed on stay out of the repository). Each game named below runs
# the pseudo-random pad exercise for a number of frames in the native
# reference, in the sandbox, and in the sandbox with a savestate saved and
# loaded before every frame; the three must agree on picture, sound, lag and
# every memory domain, and the exercise must have changed the machine.
#
# A game or firmware file that is not in tests/roms-local is a SKIP, named.
# The sandbox run's last picture is kept in build/local-shots/<tag>.tga, to
# see how far the game got.
# CD games also need the System Card there, as syscard3.pce; Run is pressed at
# its title screen to start the disc before the pad exercise begins.
#
# Usage: ./waterbox/tests/run-local.sh [-n <native build dir>] [-g <guest build dir>] [--frames N]
#        [--only <part of a tag>]
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
nat="$root/build/meson-native"
gst="$root/build/meson-guest"
local_dir="$root/tests/roms-local"
frames=3000
only=""
while [ $# -gt 0 ]; do
	case "$1" in
		-n) nat="$2"; shift ;;
		-g) gst="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		--only) only="$2"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
digests() { grep -E '^(frames|vsync|videoHash|audioHash|lagFrames|domain\[)'; }

ok=0
failed=0
skipped=0
report() { printf "%-34s %-6s %s\n" "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok+1)) ;; SKIP) skipped=$((skipped+1)) ;; *) failed=$((failed+1)) ;; esac; }

# tag | file in tests/roms-local | slot | settings | firmware file (or -) | extra harness options
games=(
	"bonk|Bonk's Adventure (U).pce|card|{\"machine\":\"pce\"}|-|"
	"bomberman93-tap|Bomberman '93 (U).pce|card|{\"machine\":\"pce\",\"turboTap\":true}|-|--exercise-pad 2"
	"sf2ce-pad6|Street Fighter II' - Champion Edition (J).pce|card|{\"machine\":\"pce\",\"port1\":\"avenuePad6\"}|-|"
	"populous|Populous (J).pce|card|{\"machine\":\"pce\"}|-|"
	"1941-sgx|1941 - Counter Attack (J) (SGX).pce|card|{\"machine\":\"sgx\"}|-|"
	"dariusplus-sgx|Darius Plus (J) (SGX).pce|card|{\"machine\":\"sgx\"}|-|"
	"f1team-cd|F1 Team Simulation Project F (JP).cue|disc|{\"machine\":\"pcecd\"}|syscard3.pce|"
	"dinotour-cd|Magical Dinosaur Tour (US).cue|disc|{\"machine\":\"pcecd\"}|syscard3.pce|"
)

for g in "${games[@]}"; do
	IFS='|' read -r tag file slot settings fw extra <<< "$g"
	case "$tag" in *"$only"*) ;; *) continue ;; esac
	if [ ! -f "$local_dir/$file" ]; then
		report "$tag" SKIP "tests/roms-local/$file is not there"; continue
	fi
	if [ "$fw" != - ] && [ ! -f "$local_dir/$fw" ]; then
		report "$tag" SKIP "the System Card tests/roms-local/$fw is not there"; continue
	fi
	wd="$work/$tag"
	mkdir -p "$wd"
	cp "$local_dir/$file" "$wd/"
	if [ "${file##*.}" = cue ]; then
		# the track files the sheet names, beside it
		grep -i '^ *FILE' "$local_dir/$file" | sed 's/^ *FILE *"\(.*\)".*/\1/' | while read -r t; do cp "$local_dir/$t" "$wd/"; done
	fi
	[ "$fw" != - ] && cp "$local_dir/$fw" "$wd/syscard"
	printf '{"%s":["%s"]}' "$slot" "$file" > "$wd/slots"
	printf '%s' "$settings" > "$wd/settings"
	sha="$(sha1sum "$local_dir/$file" | cut -c1-12)"
	# shellcheck disable=SC2086
	args=(--frames "$frames" --exercise $extra)
	if [ "$slot" = disc ]; then
		# the System Card waits at PUSH RUN BUTTON: Run held for frames 300 to
		# 307 starts the disc, and the pad exercise takes over at frame 600.
		# Without it the random pad wanders into the card's own menus.
		python3 -c "
for f in range(600):
    l = ['.'] * 63
    if 300 <= f < 308: l[8] = 'R'
    print(''.join(l))" > "$wd/boot.inputs"
		args+=(--inputs "$wd/boot.inputs")
	fi
	"$nat/run-native" "$wd" "${args[@]}" 2>/dev/null | digests > "$work/n.txt"
	mkdir -p "$root/build/local-shots"
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" --screenshot "$root/build/local-shots/$tag.tga" \
		2>"$work/b.err" | digests > "$work/b.txt"
	"$nat/run-wbx" "$gst/core.wbx" "$wd" "${args[@]}" --rerecord 2>/dev/null | digests > "$work/r.txt"
	"$nat/run-wbx" "$gst/core.wbx" "$wd" --frames "$frames" 2>/dev/null | digests > "$work/i.txt"
	lag="$(sed -n 's/^lagFrames=//p' "$work/b.txt")"
	if ! grep -q '^frames=' "$work/b.txt"; then
		report "$tag" FAIL "the sandbox did not run: $(tail -1 "$work/b.err")"
	elif ! cmp -s "$work/n.txt" "$work/b.txt"; then
		report "$tag" FAIL "native and sandbox differ: $(diff "$work/n.txt" "$work/b.txt" | tr '\n' ' ' | head -c 100)"
	elif ! cmp -s "$work/b.txt" "$work/r.txt"; then
		report "$tag" FAIL "a savestate before every frame changed the run: $(diff "$work/b.txt" "$work/r.txt" | tr '\n' ' ' | head -c 100)"
	elif cmp -s "$work/b.txt" "$work/i.txt"; then
		report "$tag" FAIL "the pad exercise changed nothing: did the game read its controller?"
	else
		report "$tag" PASS "$frames frames, native == sandbox == savestate every frame; $lag lag frames; sha1 $sha..."
	fi
done

echo ""
echo "$ok ok, $failed failed, $skipped skipped"
[ "$failed" -gt 0 ] && exit 1
exit 0
