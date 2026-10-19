
/* ChipBurner: VPP check – inserted into tl866a.c by scripts/patch-minipro.sh.
 * Run as `minipro -t` with CHIPBURNER_VPP_CHECK="<vpp code>,<vpp pin>,<gnd pin>,<seconds>" in the environment.
 * With the ZIF socket EMPTY it switches the programming voltage (VPP) onto one ZIF pin and GND onto another,
 * so the voltage the programmer really delivers can be measured with a meter between the two pins.
 * <vpp code> is the TL866A VPP code, the high nibble of the voltage byte (0x40 10 V, 0x00 12.5 V, 0x30 13.5 V,
 * 0x50 14 V, 0x10 16 V, 0x70 17 V, 0x60 18 V, 0x20 21 V; low nibble 0 = VCC 5 V). The level is set by starting a
 * transaction as for a 27C256 (protocol 0x31, variant 0x11), then every pin driver is cleared and only the VPP and
 * GND drivers are switched on. VPP goes off again on SIGINT/SIGTERM/SIGHUP (ChipBurner's Stop), on overcurrent,
 * or after <seconds>. */
#include <signal.h>

static volatile sig_atomic_t chipburner_vpp_stop = 0;

static void chipburner_vpp_signal(int sig)
{
	(void)sig;
	chipburner_vpp_stop = 1;
}

static int chipburner_vpp_off(minipro_handle_t *handle)
{
	uint8_t msg[64];
	int ret;
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_RESET_PIN_DRIVERS;
	ret = msg_send(handle->usb_handle, msg, 10);
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_END_TRANSACTION;
	msg[1] = 0x31;
	msg[2] = 0x11;
	ret |= msg_send(handle->usb_handle, msg, 4);
	return ret;
}

/* Returns 1 on overcurrent, 0 if fine, -1 on a USB error; the ZIF pin states go to rb. */
static int chipburner_vpp_ovc(minipro_handle_t *handle, uint8_t *rb)
{
	uint8_t msg[64];
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_READ_ZIF_PINS;
	if (msg_send(handle->usb_handle, msg, 18) || msg_recv(handle->usb_handle, rb, 64))
		return -1;
	return rb[1] ? 1 : 0;
}

static int chipburner_vpp_check(minipro_handle_t *handle, const char *spec)
{
	unsigned code = 0, vpin = 40, gpin = 14, secs = 120, t;
	zif_pins_t *vp = NULL, *gp = NULL;
	uint8_t msg[64], rb[64];
	size_t i;
	int ovc;

	if (sscanf(spec, "%x,%u,%u,%u", &code, &vpin, &gpin, &secs) < 1 || (code & 0x0f) || code > 0xff ||
	    secs < 1 || secs > 600) {
		fprintf(stderr, "VPP check: bad setting \"%s\"\n", spec);
		return EXIT_FAILURE;
	}
	for (i = 0; i < sizeof(vpp_pins) / sizeof(vpp_pins[0]); i++)
		if (vpp_pins[i].pin == vpin)
			vp = &vpp_pins[i];
	for (i = 0; i < sizeof(gnd_pins) / sizeof(gnd_pins[0]); i++)
		if (gnd_pins[i].pin == gpin)
			gp = &gnd_pins[i];
	if (!vp || !gp || gp->latch == 9 || vp->latch == gp->latch) {
		fprintf(stderr, "VPP check: ZIF pin %u can't have VPP or ZIF pin %u can't have GND\n", vpin, gpin);
		return EXIT_FAILURE;
	}

	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = chipburner_vpp_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);

	/* All pin drivers off */
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_RESET_PIN_DRIVERS;
	if (msg_send(handle->usb_handle, msg, 10))
		return EXIT_FAILURE;

	/* Start a transaction as for a 27C256 to set the VPP level (VCC/VDD 5 V) */
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_START_TRANSACTION;
	msg[1] = 0x31;
	msg[2] = 0x11;
	msg[5] = (uint8_t)code;
	msg[8] = 0x00;
	format_int(&(msg[9]), 0x0064, 2, MP_LITTLE_ENDIAN);
	format_int(&(msg[12]), 0x8000, 3, MP_LITTLE_ENDIAN);
	if (msg_send(handle->usb_handle, msg, 48))
		return EXIT_FAILURE;

	/* Whatever the transaction switched on: off again, then only VPP and GND */
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_RESET_PIN_DRIVERS;
	if (msg_send(handle->usb_handle, msg, 10)) {
		chipburner_vpp_off(handle);
		return EXIT_FAILURE;
	}
	memset(msg, 0, sizeof(msg));
	msg[0] = TL866A_SET_LATCH;
	msg[7] = 2;
	msg[8] = TL866A_OE_ALL;
	msg[9] = vp->latch;
	msg[10] = vp->mask;
	msg[11] = gp->latch;
	msg[12] = gp->mask;
	if (msg_send(handle->usb_handle, msg, 32)) {
		chipburner_vpp_off(handle);
		return EXIT_FAILURE;
	}
	usleep(20000);

	ovc = chipburner_vpp_ovc(handle, rb);
	if (ovc) {
		chipburner_vpp_off(handle);
		fprintf(stderr, ovc > 0 ? "VPP check: overcurrent – is the socket empty?\007\n"
					: "VPP check: lost the programmer\n");
		return EXIT_FAILURE;
	}
	fprintf(stderr, "VPP check: VPP is ON at ZIF pin %u, GND at ZIF pin %u (VPP code 0x%02x); pin %u reads %s.\n",
		vpin, gpin, code, vpin, rb[6 + vpin] ? "high" : "low");
	fprintf(stderr, "VPP check: switches off when stopped, or after %u seconds.\n", secs);

	for (t = 0; t < secs * 10 && !chipburner_vpp_stop; t++) {
		usleep(100000);
		if (t % 5 == 4 && !chipburner_vpp_stop) {
			ovc = chipburner_vpp_ovc(handle, rb);
			if (ovc) {
				chipburner_vpp_off(handle);
				fprintf(stderr, ovc > 0 ? "VPP check: overcurrent – VPP switched off\007\n"
							: "VPP check: lost the programmer\n");
				return EXIT_FAILURE;
			}
		}
	}
	if (chipburner_vpp_off(handle)) {
		fprintf(stderr, "VPP check: could not switch VPP off – unplug the programmer!\007\n");
		return EXIT_FAILURE;
	}
	fprintf(stderr, "VPP check: VPP is OFF.\n");
	return EXIT_SUCCESS;
}

