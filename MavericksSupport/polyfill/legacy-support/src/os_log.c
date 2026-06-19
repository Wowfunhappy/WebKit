/*
 * os_log stubs (added macOS 10.12) --
 * custom polyfill (not from macports-legacy-support).
 *
 * Logging is disabled; the entry points exist only so modern binaries link
 * and run.
 */

struct os_log_s { int dummy; };
static struct os_log_s _os_log_default_val = { 0 };
void *_os_log_default = &_os_log_default_val;

int os_log_type_enabled(void *log, int type) {
	(void)log; (void)type;
	return 0; /* logging disabled */
}

void _os_log_error_impl(void *dso, void *log, int type,
                        const char *format, void *buf, unsigned int size) {
	(void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}

void _os_log_impl(void *dso, void *log, int type,
                  const char *format, void *buf, unsigned int size) {
	(void)dso; (void)log; (void)type; (void)format; (void)buf; (void)size;
}
