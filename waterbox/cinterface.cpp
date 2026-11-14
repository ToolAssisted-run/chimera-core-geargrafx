/* cinterface.cpp - Geargrafx behind Chimera's guest ABI.
 *
 * Geargrafx (https://github.com/drhelius/Geargrafx) is a PC Engine /
 * TurboGrafx-16, SuperGrafx, CD-ROM2 and LaserActive emulator. This file
 * plays the part upstream's libretro frontend (platforms/libretro/
 * libretro.cpp) plays: it reads the project's settings and files, builds the
 * machine, hands the controllers' state to it and runs it a frame at a time.
 *
 * Settings arrive in the mounted "settings" file, the game in the project's
 * slots (the "slots" file), and firmware under its id. Nothing here reads a
 * clock: the power-on random seed is a setting (patches/0001).
 *
 * This file compiles unchanged for the guest (miniBox's emulibc) and for the
 * native reference build (native-shim/emulibc.h): the two are what the core
 * test compares.
 */
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include "geargrafx.h"

/* A text a person reads is a key of languages/en.json, each of its arguments
 * after a TEXT_ARG (Chimera's docs/translations.md). */
#define TEXT_ARG "\x1f"

/* ---- what patches/0001 asks of the adapter ---- */
unsigned int gg_chimera_random_seed = 0x12345678u;
bool gg_chimera_no_sgx = false;

static int g_inputRead;
/* Chimera's function to call at each read of the controllers, so a Lua
 * script's event.oninputpoll runs there (chimera#344). The same callback slot
 * in every session; no savestate carries it. */
ECL_INVISIBLE static uintptr_t (*g_inputPoll)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t);

void gg_chimera_input_read(void)
{
	g_inputRead = 1;
	if (g_inputPoll)
		g_inputPoll(0, 0, 0, 0, 0, 0);
}

/* Upstream's log goes through libretro's log callback when __LIBRETRO__ is
 * defined. Everything it says goes to stderr: stdout is the test drivers'. */
static void log_to_stderr(enum retro_log_level level, const char *fmt, ...)
{
	(void)level;
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}
retro_log_printf_t log_cb = log_to_stderr;

/* ---- the machines (the "machine" setting) ---- */
enum Machine { M_PCE = 0, M_SGX, M_PCECD, M_LASERACTIVE };
static int g_machine;

static char g_loadError[512];
static int g_inited;
static GeargrafxCore *g_core;

/* ---- the wire: waterbox.config's button order ----
 * 0 Power, then for players 1 to 5:
 * Up Down Left Right I II Select Run III IV V VI,
 * then 61 P1 Mouse Left and 62 P1 Mouse Right (the mouse's buttons, which
 * are the console's II and I).
 * Axes: 0 P1 Mouse X, 1 P1 Mouse Y (the mouse's movement this frame,
 * -127..127). */
#define BTN_PLAYERS 5
#define BTN_PER_PAD 12
#define BTN_MOUSE (1 + BTN_PLAYERS * BTN_PER_PAD) /* 61 */
#define BTN_COUNT (BTN_MOUSE + 2)                 /* 63 */
#define AXIS_COUNT 2
static uint8_t g_buttons[BTN_COUNT];
static int32_t g_axes[AXIS_COUNT];

static const GG_Keys kColToKey[BTN_PER_PAD] = {
	GG_KEY_UP, GG_KEY_DOWN, GG_KEY_LEFT, GG_KEY_RIGHT,
	GG_KEY_I, GG_KEY_II, GG_KEY_SELECT, GG_KEY_RUN,
	GG_KEY_III, GG_KEY_IV, GG_KEY_V, GG_KEY_VI,
};

/* ---- video: Geargrafx draws RGBA8888 (bytes R, G, B, A); Chimera takes
 * BGRA. The largest picture is the LaserActive's, 1176 wide; upstream's
 * libretro frontend gives the core a 2048x512 buffer and so does this. ---- */
#define FB_W 2048
#define FB_H 512
static uint8_t *g_frame;      /* what Geargrafx draws into */
static uint32_t *g_videoOut;  /* what Chimera reads */
static int g_vwidth = 256, g_vheight = 240;
/* Turbo: the frontend's choice for the moment, not part of the machine. */
ECL_INVISIBLE static int g_render = 1;

#define AUDIO_MAX GG_AUDIO_BUFFER_SIZE
static int16_t g_audio[AUDIO_MAX];
static int g_nsamples;

/* ---- reading the project's files ---- */
static uint8_t *read_file(const char *name, long *size)
{
	FILE *f = fopen(name, "rb");
	if (f == NULL)
		return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *buf = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
	if (n < 0 || fread(buf, 1, (size_t)n, f) != (size_t)n)
	{
		fclose(f);
		free(buf);
		return NULL;
	}
	fclose(f);
	*size = n;
	return buf;
}

static int setting_is(const char *name, const char *value, const char *dflt)
{
	char buf[64];
	strncpy(buf, dflt, sizeof buf - 1);
	buf[sizeof buf - 1] = 0;
	wbx_setting_str(name, buf, sizeof buf);
	return strcmp(buf, value) == 0;
}

static int has_extension(const char *name, const char *ext)
{
	const char *dot = strrchr(name, '.');
	if (dot == NULL)
		return 0;
	dot++;
	for (; *dot && *ext; dot++, ext++)
		if ((*dot | 0x20) != (*ext | 0x20))
			return 0;
	return *dot == 0 && *ext == 0;
}

static GG_Controller_Type pad_type(int player)
{
	char key[16], buf[32];
	snprintf(key, sizeof key, "port%d", player);
	strcpy(buf, "pad");
	wbx_setting_str(key, buf, sizeof buf);
	if (strcmp(buf, "avenuePad3") == 0) return GG_CONTROLLER_AVENUE_PAD_3;
	if (strcmp(buf, "avenuePad6") == 0) return GG_CONTROLLER_AVENUE_PAD_6;
	if (player == 1 && strcmp(buf, "mouse") == 0) return GG_CONTROLLER_MOUSE;
	if (strcmp(buf, "pad") != 0)
		fprintf(stderr, "[geargrafx] unknown %s '%s', using a pad\n", key, buf);
	return GG_CONTROLLER_STANDARD;
}

/* The System Card in the console's slot for a CD (the "syscard" firmware),
 * or the Games Express card. */
static int load_card(void)
{
	long size = 0;
	uint8_t *card = read_file("syscard", &size);
	if (card == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_card");
		return 0;
	}
	int gexpress = setting_is("systemCard", "gamesExpress", "syscard3");
	int ok = g_core->LoadBiosFromBuffer(card, (int)size, !gexpress);
	free(card);
	if (!ok)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.bad_card");
		return 0;
	}
	g_core->GetMedia()->ForceGameExpress(gexpress != 0);
	return 1;
}

static int load_pac_bios(void)
{
	long size = 0;
	uint8_t *bios = read_file("pacbios", &size);
	if (bios == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_pac");
		return 0;
	}
	GG_LaserActive_Region region = setting_is("laseractiveBios", "pacN10", "pacN1")
		? GG_LASERACTIVE_REGION_US : GG_LASERACTIVE_REGION_JAPAN;
	g_core->SetLaserActiveRegion(region);
	int ok = g_core->LoadPacBiosFromBuffer(bios, (int)size, region);
	free(bios);
	if (!ok)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.bad_pac");
		return 0;
	}
	return 1;
}

/* A saved game the project starts from (the "savedata" slot): the backup
 * memory's 2 KiB, or an MB128's 128 KiB, told apart by size. */
static void load_savedata(void)
{
	char name[512];
	if (wbx_slot_count("savedata") <= 0 || wbx_slot_name("savedata", 0, name, sizeof name) == NULL)
		return;
	long size = 0;
	uint8_t *data = read_file(name, &size);
	if (data == NULL)
		return;
	MB128 *mb = g_core->GetInput()->GetMB128();
	Memory *mem = g_core->GetMemory();
	if (mb->IsConnected() && size == (long)mb->GetRAMSize())
	{
		memcpy(mb->GetRAM(), data, (size_t)size);
		fprintf(stderr, "[geargrafx] savedata: MB128 from %s\n", name);
	}
	else if (mem->IsBackupRamEnabled() && size > 0 && size <= mem->GetBackupRAMSize())
	{
		memcpy(mem->GetBackupRAM(), data, (size_t)size);
		fprintf(stderr, "[geargrafx] savedata: backup memory from %s\n", name);
	}
	else
		fprintf(stderr, "[geargrafx] savedata: %s (%ld bytes) fits nothing this machine has\n", name, size);
	free(data);
}

extern "C" {

ECL_EXPORT const char *GetLoadError(void)
{
	return g_loadError;
}

ECL_EXPORT int Init(void)
{
	g_loadError[0] = 0;

	char machine[32] = "pce";
	wbx_setting_str("machine", machine, sizeof machine);
	if (strcmp(machine, "sgx") == 0) g_machine = M_SGX;
	else if (strcmp(machine, "pcecd") == 0) g_machine = M_PCECD;
	else if (strcmp(machine, "laseractive") == 0) g_machine = M_LASERACTIVE;
	else g_machine = M_PCE;

	/* what the machine is at power on: upstream's random registers, palette
	 * and memory map from a seed the project pins, or upstream's fixed
	 * "deterministic netplay" values */
	gg_chimera_random_seed = (unsigned int)wbx_setting_ulong("randomSeed", 0x12345678u);
	gg_chimera_no_sgx = g_machine == M_PCE;

	g_frame = (uint8_t *)calloc(FB_W * FB_H, 4);
	g_videoOut = (uint32_t *)calloc(FB_W * FB_H, 4);

	g_core = new GeargrafxCore();
	g_core->Init(NULL, GG_PIXEL_RGBA8888);

	/* what upstream's libretro frontend sets before it loads a game
	 * (check_variables), from the project's settings */
	Media *media = g_core->GetMedia();
	GG_Console_Type console = GG_CONSOLE_AUTO;
	if (g_machine == M_SGX)
		console = GG_CONSOLE_SGX;
	else if (setting_is("region", "pce", "auto"))
		console = GG_CONSOLE_PCE;
	else if (setting_is("region", "tg16", "auto"))
		console = GG_CONSOLE_TG16;
	media->SetConsoleType(console);

	GG_CDROM_Type cd = GG_CDROM_AUTO;
	if (g_machine == M_PCECD)
	{
		if (setting_is("cdromType", "standard", "auto")) cd = GG_CDROM_STANDARD;
		else if (setting_is("cdromType", "super", "auto")) cd = GG_CDROM_SUPER_CDROM;
		else if (setting_is("cdromType", "arcade", "auto")) cd = GG_CDROM_ARCADE_CARD;
	}
	media->SetCDROMType(cd);
	media->ForceBackupRAM(wbx_setting_bool("backupRam", 1) != 0);
	media->PreloadCdRom(false);

	if (setting_is("powerOn", "zero", "random"))
	{
		g_core->GetMemory()->SetResetValues(0, 0, 0, 0);
		g_core->GetHuC6260()->SetResetValue(0);
		g_core->GetHuC6280()->SetResetValue(0);
		g_core->GetScsiController()->SetResetValue(0);
	}
	else
	{
		g_core->GetMemory()->SetResetValues(-1, 0, 0, 0);
		g_core->GetHuC6260()->SetResetValue(-1);
		g_core->GetHuC6280()->SetResetValue(-1);
		g_core->GetScsiController()->SetResetValue(-1);
	}

	int noSpriteLimit = wbx_setting_bool("noSpriteLimit", 0) != 0;
	g_core->GetHuC6270_1()->SetNoSpriteLimit(noSpriteLimit);
	g_core->GetHuC6270_2()->SetNoSpriteLimit(noSpriteLimit);

	GG_PSG_Revision psg = GG_PSG_REVISION_AUTO;
	if (setting_is("psg", "huc6280", "auto")) psg = GG_PSG_REVISION_HUC6280;
	else if (setting_is("psg", "huc6280a", "auto")) psg = GG_PSG_REVISION_HUC6280A;
	g_core->SetPSGRevision(psg);

	/* the picture: which columns and lines are shown, and the colours */
	HuC6260 *vce = g_core->GetHuC6260();
	vce->SetOverscan(wbx_setting_bool("overscan", 0) ? 1 : 0);
	if (setting_is("lines", "224", "240"))
	{
		vce->SetScanlineStart(11);
		vce->SetScanlineEnd(234);
	}
	else
	{
		vce->SetScanlineStart(2);
		vce->SetScanlineEnd(241);
	}
	if (setting_is("palette", "turboxray", "standard"))
		vce->SetPalette(HuC6260::HuC6260_PALETTE_TURBOXRAY);
	else if (setting_is("palette", "kitrinx", "standard"))
		vce->SetPalette(HuC6260::HuC6260_PALETTE_KITRINX);
	else
		vce->SetPalette(HuC6260::HuC6260_PALETTE_STANDARD_RGB);

	/* the controllers: a pad, an Avenue Pad 3 or 6, or (port 1) a mouse;
	 * five of them through the TurboTap */
	Input *input = g_core->GetInput();
	int tap = wbx_setting_bool("turboTap", 0) != 0;
	input->EnableTurboTap(tap);
	for (int p = 1; p <= BTN_PLAYERS; p++)
		input->SetControllerType((GG_Controllers)(p - 1), (p == 1 || tap) ? pad_type(p) : GG_CONTROLLER_STANDARD);

	/* the firmware, then the game */
	if (g_machine == M_PCECD && !load_card())
		return 0;
	if (g_machine == M_LASERACTIVE && !load_pac_bios())
		return 0;

	const char *slot = g_machine == M_PCECD ? "disc" : g_machine == M_LASERACTIVE ? "laserdisc" : "card";
	char name[512];
	if (wbx_slot_count(slot) <= 0 || wbx_slot_name(slot, 0, name, sizeof name) == NULL)
	{
		snprintf(g_loadError, sizeof g_loadError, "error.no_file");
		return 0;
	}

	if (g_machine == M_PCECD || g_machine == M_LASERACTIVE)
	{
		if (g_machine == M_PCECD && !has_extension(name, "cue") && !has_extension(name, "chd"))
		{
			snprintf(g_loadError, sizeof g_loadError, "error.not_disc" TEXT_ARG "%s", name);
			return 0;
		}
		if (!g_core->LoadMedia(name))
		{
			snprintf(g_loadError, sizeof g_loadError, "error.rejected" TEXT_ARG "%s", name);
			return 0;
		}
		if (!media->IsBiosReady())
		{
			snprintf(g_loadError, sizeof g_loadError, "%s",
				media->IsGameExpress() ? "error.needs_gexpress" : "error.no_card");
			return 0;
		}
	}
	else
	{
		long size = 0;
		uint8_t *rom = read_file(name, &size);
		if (rom == NULL)
		{
			snprintf(g_loadError, sizeof g_loadError, "error.not_read" TEXT_ARG "%s", name);
			return 0;
		}
		int ok = g_core->LoadHuCardFromBuffer(rom, (int)size, name);
		free(rom);
		if (!ok)
		{
			snprintf(g_loadError, sizeof g_loadError, "error.rejected" TEXT_ARG "%s", name);
			return 0;
		}
	}

	/* the MB128 backup unit: Auto asks the game database, which knows the
	 * games that use it, so it is decided after the game is in */
	GG_MB128_Mode mb = GG_MB128_AUTO;
	if (setting_is("mb128", "on", "auto")) mb = GG_MB128_ENABLED;
	else if (setting_is("mb128", "off", "auto")) mb = GG_MB128_DISABLED;
	g_core->EnableMB128(mb);

	load_savedata();

	/* one greppable line per boot, so a test can say what was built */
	fprintf(stderr, "[geargrafx] machine=%s sgx=%d cdrom=%d laseractive=%d mb128=%d\n", machine,
		media->IsSGX() ? 1 : 0, media->IsCDROMHardwareEnabled() ? 1 : 0, media->IsLaserActive() ? 1 : 0,
		input->GetMB128()->IsConnected() ? 1 : 0);

	g_inited = 1;
	return 1;
}

ECL_EXPORT void SetButton(int32_t index, int32_t state)
{
	if (index >= 0 && index < BTN_COUNT)
		g_buttons[index] = state != 0;
}

ECL_EXPORT void SetAxis(int32_t index, int32_t value)
{
	if (index >= 0 && index < AXIS_COUNT)
		g_axes[index] = value;
}

static void apply_input(void)
{
	int mouse = g_core->GetInput()->GetControllerType(GG_CONTROLLER_1) == GG_CONTROLLER_MOUSE;
	for (int p = 0; p < BTN_PLAYERS; p++)
		for (int c = 0; c < BTN_PER_PAD; c++)
		{
			int held = g_buttons[1 + p * BTN_PER_PAD + c];
			/* the mouse's left button is the console's II, its right I */
			if (mouse && p == 0 && kColToKey[c] == GG_KEY_II) held |= g_buttons[BTN_MOUSE];
			if (mouse && p == 0 && kColToKey[c] == GG_KEY_I) held |= g_buttons[BTN_MOUSE + 1];
			if (held)
				g_core->KeyPressed((GG_Controllers)p, kColToKey[c]);
			else
				g_core->KeyReleased((GG_Controllers)p, kColToKey[c]);
		}
	if (mouse)
	{
		int32_t dx = g_axes[0], dy = g_axes[1];
		if (dx < -127) dx = -127;
		if (dx > 127) dx = 127;
		if (dy < -127) dy = -127;
		if (dy > 127) dy = 127;
		g_core->GetInput()->SetMouseDelta(dx, dy);
	}
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	(void)packed; /* input rides the SetButton channel */
	if (!g_inited)
		return;

	/* Power: the console switched off and on again; the backup memory keeps
	 * what it holds, as its battery does */
	if (g_buttons[0])
		g_core->ResetMedia(true);

	apply_input();

	g_inputRead = 0;
	int count = 0;
	g_core->RunToVBlank(g_frame, g_audio, &count, NULL, g_render != 0);
	g_nsamples = count / 2;

	if (g_render)
	{
		GG_Runtime_Info info;
		g_core->GetRuntimeInfo(info);
		int w = info.screen_width, h = info.screen_height;
		if (w < 1) w = 1;
		if (h < 1) h = 1;
		if (w > FB_W) w = FB_W;
		if (h > FB_H) h = FB_H;
		const uint8_t *src = g_frame;
		for (int i = 0; i < w * h; i++, src += 4)
			g_videoOut[i] = (uint32_t)src[2] | ((uint32_t)src[1] << 8) | ((uint32_t)src[0] << 16) | 0xff000000u;
		g_vwidth = w;
		g_vheight = h;
	}
}

/* Turbo: while off the core draws nothing and is otherwise the machine it
 * would have been (run-gate.sh's turbo test). Geargrafx renders nothing when
 * RunToVBlank is given render = false. */
ECL_EXPORT void SetRenderingEnabled(int on) { g_render = on != 0; }

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_videoOut; }
ECL_EXPORT int GetVideoWidth(void) { return g_vwidth; }
ECL_EXPORT int GetVideoHeight(void) { return g_vheight; }

ECL_EXPORT int16_t *GetAudio(void) { return g_audio; }
ECL_EXPORT int GetAudioSampleCount(void) { return g_nsamples; }

/* 21477273 Hz over 1365 clocks a line and 263 lines a frame: 59.826 frames
 * a second. A game may set 262 lines; the frame is then shorter. */
ECL_EXPORT int GetVsyncNumerator(void)
{
	return GG_MASTER_CLOCK_RATE;
}
ECL_EXPORT int GetVsyncDenominator(void)
{
	return g_core ? HUC6260_LINE_LENGTH * g_core->GetHuC6260()->GetTotalLines() : HUC6260_LINE_LENGTH * HUC6260_LINES;
}

ECL_EXPORT int InputWasRead(void)
{
	return g_inputRead;
}

ECL_EXPORT void SetInputPollCallback(uint64_t fn)
{
	g_inputPoll = (uintptr_t (*)(uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t))(uintptr_t)fn;
}

/* ---- memory domains: the names the Mesen core gives the same memories ---- */
static const char *memdom(int which, void **area, int64_t *size, int *writable)
{
	*writable = 1;
	if (g_core == NULL)
		return NULL;
	Memory *mem = g_core->GetMemory();
	Media *media = g_core->GetMedia();
	switch (which)
	{
	case 0:
		*area = mem->GetWorkingRAM();
		*size = mem->GetWorkingRAMSize();
		return "Work RAM";
	case 1:
		if (!mem->IsBackupRamEnabled()) return NULL;
		*area = mem->GetBackupRAM();
		*size = mem->GetBackupRAMSize();
		return "Backup RAM";
	case 2:
		if (!media->IsCDROMHardwareEnabled()) return NULL;
		*area = mem->GetCDROMRAM();
		*size = mem->GetCDROMRAMSize();
		return "CD RAM";
	case 3:
		if (mem->GetCardRAMSize() <= 0) return NULL;
		*area = mem->GetCardRAM();
		*size = mem->GetCardRAMSize();
		return "Card RAM";
	case 4:
		if (!media->IsCDROMHardwareEnabled()) return NULL;
		*area = g_core->GetAdpcm()->GetRAM();
		*size = 0x10000;
		return "ADPCM RAM";
	case 5:
		if (media->GetMapper() != Media::ARCADE_CARD_MAPPER) return NULL;
		*area = mem->GetArcadeRAM();
		*size = mem->GetArcadeCardRAMSize();
		return "Arcade Card RAM";
	case 6:
		*area = g_core->GetHuC6270_1()->GetVRAM();
		*size = HUC6270_VRAM_SIZE * 2;
		return "VRAM";
	case 7:
		if (!media->IsSGX()) return NULL;
		*area = g_core->GetHuC6270_2()->GetVRAM();
		*size = HUC6270_VRAM_SIZE * 2;
		return "VRAM 2";
	case 8:
		*area = g_core->GetHuC6270_1()->GetSAT();
		*size = HUC6270_SAT_SIZE * 2;
		return "SAT";
	case 9:
		if (!media->IsSGX()) return NULL;
		*area = g_core->GetHuC6270_2()->GetSAT();
		*size = HUC6270_SAT_SIZE * 2;
		return "SAT 2";
	case 10:
		if (media->IsCDROM() || media->GetROMSize() <= 0) return NULL;
		*area = media->GetROM();
		*size = media->GetROMSize();
		return "Card ROM";
	case 11:
	{
		MB128 *mb = g_core->GetInput()->GetMB128();
		if (!mb->IsConnected()) return NULL;
		*area = mb->GetRAM();
		*size = mb->GetRAMSize();
		return "MB128";
	}
	default:
		return NULL;
	}
}
#define DOMAIN_KINDS 12

static int domain_slot(int i)
{
	int found = 0;
	for (int which = 0; which < DOMAIN_KINDS; which++)
	{
		void *area = NULL;
		int64_t size = 0;
		int w = 0;
		if (memdom(which, &area, &size, &w) != NULL)
		{
			if (found == i) return which;
			found++;
		}
	}
	return -1;
}

ECL_EXPORT int GetMemoryDomainCount(void)
{
	int count = 0;
	while (domain_slot(count) >= 0) count++;
	return count;
}
ECL_EXPORT const char *GetMemoryDomainName(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 ? memdom(which, &area, &size, &w) : NULL;
}
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 && memdom(which, &area, &size, &w) != NULL ? (uint8_t *)area : NULL;
}
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 && memdom(which, &area, &size, &w) != NULL ? size : 0;
}
ECL_EXPORT int GetMemoryDomainWritable(int i)
{
	void *area = NULL;
	int64_t size = 0;
	int w = 0;
	int which = domain_slot(i);
	return which >= 0 && memdom(which, &area, &size, &w) != NULL ? w : 0;
}

/* ---- saved games out: the backup memory and the MB128 ---- */
static const char *savedata_entry(int32_t i, uint8_t **buf, int64_t *size)
{
	static const int kinds[] = { 1, 11 };
	static const char *const names[] = { "backup.brm", "mb128.bin" };
	int32_t found = 0;
	for (int k = 0; k < 2; k++)
	{
		void *area = NULL;
		int64_t sz = 0;
		int w = 0;
		if (memdom(kinds[k], &area, &sz, &w) == NULL) continue;
		if (found == i)
		{
			*buf = (uint8_t *)area;
			*size = sz;
			return names[k];
		}
		found++;
	}
	return NULL;
}

ECL_EXPORT int32_t GetSaveDataFileCount(void)
{
	uint8_t *b;
	int64_t n;
	int32_t count = 0;
	while (savedata_entry(count, &b, &n) != NULL) count++;
	return count;
}
ECL_EXPORT const char *GetSaveDataFileName(int32_t i)
{
	uint8_t *b;
	int64_t n;
	return savedata_entry(i, &b, &n);
}
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t i)
{
	uint8_t *b = NULL;
	int64_t n = 0;
	return savedata_entry(i, &b, &n) != NULL ? n : 0;
}
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t i)
{
	uint8_t *b = NULL;
	int64_t n = 0;
	return savedata_entry(i, &b, &n) != NULL ? b : NULL;
}

} /* extern "C" */
