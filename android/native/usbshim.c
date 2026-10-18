/*
 * USB access for minipro on Android.
 *
 * An Android app may not open /dev/bus/usb itself: it asks UsbManager for permission and gets an
 * already-open file descriptor. ChipBurner passes that descriptor to minipro over a Unix socket
 * (SCM_RIGHTS), named by the CHIPBURNER_USB_SOCKET environment variable, and this shim turns it into
 * a libusb device with libusb_wrap_sys_device(). minipro is compiled with its libusb calls renamed
 * to the cb_* functions below (via pkg-config Cflags), so minipro's source stays unchanged.
 *
 * Device discovery is always switched off on Android (it can't read /dev/bus/usb anyway), so
 * minipro sees either the one programmer handed over, or none.
 */
#include <libusb.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int usb_fd = -2;                      /* -2: not asked yet, -1: none */
static libusb_context *wrapped_ctx = NULL;
static libusb_device_handle *wrapped = NULL;
static libusb_device *wrapped_dev = NULL;
static libusb_device **our_list = NULL;

static int receive_fd(void)
{
	const char *name = getenv("CHIPBURNER_USB_SOCKET");
	if (!name || !*name)
		return -1;
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	size_t n = strlen(name);
	if (n > sizeof(a.sun_path) - 2)
		n = sizeof(a.sun_path) - 2;
	memcpy(a.sun_path + 1, name, n); /* abstract namespace: leading NUL */
	socklen_t len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + n);
	if (connect(s, (struct sockaddr *)&a, len) < 0) {
		close(s);
		return -1;
	}
	char byte;
	struct iovec io = { &byte, 1 };
	union {
		char buf[CMSG_SPACE(sizeof(int))];
		struct cmsghdr align;
	} ctl;
	struct msghdr m;
	memset(&m, 0, sizeof m);
	m.msg_iov = &io;
	m.msg_iovlen = 1;
	m.msg_control = ctl.buf;
	m.msg_controllen = sizeof ctl.buf;
	int fd = -1;
	if (recvmsg(s, &m, 0) > 0) {
		struct cmsghdr *c = CMSG_FIRSTHDR(&m);
		if (c && c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS)
			memcpy(&fd, CMSG_DATA(c), sizeof(int));
	}
	close(s);
	return fd;
}

static void wrap_if_needed(libusb_context *ctx)
{
	if (usb_fd == -2)
		usb_fd = receive_fd();
	if (usb_fd >= 0 && !wrapped) {
		if (libusb_wrap_sys_device(ctx, (intptr_t)usb_fd, &wrapped) == 0) {
			wrapped_ctx = ctx;
			wrapped_dev = libusb_get_device(wrapped);
		} else {
			wrapped = NULL;
		}
	}
}

int cb_init(libusb_context **ctx)
{
	libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
	int r = libusb_init(ctx);
	if (r == 0)
		wrap_if_needed(ctx ? *ctx : NULL);
	return r;
}

#if defined(LIBUSB_API_VERSION) && LIBUSB_API_VERSION >= 0x0100010A
int cb_init_context(libusb_context **ctx, const struct libusb_init_option options[], int num_options)
{
	libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
	int r = libusb_init_context(ctx, options, num_options);
	if (r == 0)
		wrap_if_needed(ctx ? *ctx : NULL);
	return r;
}
#endif

void cb_exit(libusb_context *ctx)
{
	if (wrapped && ctx == wrapped_ctx) {
		libusb_close(wrapped); /* leaves the file descriptor open, so it can be wrapped again */
		wrapped = NULL;
		wrapped_dev = NULL;
		wrapped_ctx = NULL;
	}
	libusb_exit(ctx);
}

ssize_t cb_get_device_list(libusb_context *ctx, libusb_device ***list)
{
	if (!wrapped)
		wrap_if_needed(ctx);
	if (wrapped_dev) {
		libusb_device **l = calloc(2, sizeof *l);
		if (!l)
			return LIBUSB_ERROR_NO_MEM;
		l[0] = libusb_ref_device(wrapped_dev);
		our_list = l;
		*list = l;
		return 1;
	}
	return libusb_get_device_list(ctx, list);
}

void cb_free_device_list(libusb_device **list, int unref_devices)
{
	if (list && list == our_list) {
		if (unref_devices && list[0])
			libusb_unref_device(list[0]);
		free(list);
		our_list = NULL;
		return;
	}
	libusb_free_device_list(list, unref_devices);
}

int cb_open(libusb_device *dev, libusb_device_handle **handle)
{
	if (wrapped && dev == wrapped_dev) {
		*handle = wrapped;
		return 0;
	}
	return libusb_open(dev, handle);
}

libusb_device_handle *cb_open_device_with_vid_pid(libusb_context *ctx, uint16_t vid, uint16_t pid)
{
	if (!wrapped)
		wrap_if_needed(ctx);
	if (wrapped_dev) {
		struct libusb_device_descriptor d;
		if (libusb_get_device_descriptor(wrapped_dev, &d) == 0 && d.idVendor == vid && d.idProduct == pid)
			return wrapped;
		return NULL;
	}
	return libusb_open_device_with_vid_pid(ctx, vid, pid);
}

void cb_close(libusb_device_handle *handle)
{
	if (handle && handle == wrapped)
		return; /* kept open for the rest of the run; closed in cb_exit */
	libusb_close(handle);
}
