/*
 * syslog$DARWIN_EXTSN -- custom polyfill (not from macports-legacy-support).
 *
 * Newer ABI variant of syslog(); forward to vsyslog().
 */

#include <syslog.h>
#include <stdarg.h>

void syslog_darwin_extsn(int priority, const char *message, ...)
    __asm("_syslog$DARWIN_EXTSN");
void syslog_darwin_extsn(int priority, const char *message, ...) {
	va_list ap;
	va_start(ap, message);
	vsyslog(priority, message, ap);
	va_end(ap);
}
