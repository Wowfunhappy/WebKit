// Which lines of a header section reach CURLOPT_HEADERFUNCTION, and whether a tunnelled transfer
// survives the ones that are dropped.
//
// A line carrying no colon is not a field line (RFC 9112 section 5), and curl-http1-framing.patch
// drops it from all three sections that reach the callback -- response headers, chunked trailers and
// the CONNECT response -- so CocoaCurlTransfer::header() only ever parses field lines. Each drop
// also has to leave its section able to continue: the CONNECT path keeps its line buffer, and a
// dropped line there must reset it or the next line is appended to the one that was dropped.
#include <curl/curl.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "header delivery FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)

#define ORIGIN "http://127.0.0.1:18988"
#define PROXY "http://127.0.0.1:18989"

static char delivered[16384];
static size_t deliveredLength;
static int colonless, statusLines, blankLines;

static size_t headerCallback(char *data, size_t size, size_t count, void *context)
{
    size_t length = size * count;
    (void)context;
    if (length >= 5 && !memcmp(data, "HTTP/", 5))
        ++statusLines;
    else if (length && (data[0] == '\r' || data[0] == '\n'))
        ++blankLines;
    else if (!memchr(data, ':', length)) {
        ++colonless;
        fprintf(stderr, "  colon-less line delivered: \"%.*s\"\n", (int)length, data);
    }
    CHECK(deliveredLength + length < sizeof delivered);
    memcpy(delivered + deliveredLength, data, length);
    deliveredLength += length;
    delivered[deliveredLength] = 0;
    return length;
}

static size_t sink(char *data, size_t size, size_t count, void *context)
{
    (void)data; (void)context;
    return size * count;
}

// Runs one case and leaves the delivered lines in |delivered| for the caller to check.
static void fetch(const char *path, const char *proxy, long *status, long *connectcode)
{
    CURL *easy = curl_easy_init();
    CHECK(easy);
    delivered[0] = 0;
    deliveredLength = 0;
    colonless = statusLines = blankLines = 0;
    CHECK(!curl_easy_setopt(easy, CURLOPT_URL, path));
    CHECK(!curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, headerCallback));
    CHECK(!curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, sink));
    CHECK(!curl_easy_setopt(easy, CURLOPT_HTTP09_ALLOWED, 0L));
    CHECK(!curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1));
    CHECK(!curl_easy_setopt(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 0L));
    CHECK(!curl_easy_setopt(easy, CURLOPT_TIMEOUT, 20L));
    if (proxy) {
        CHECK(!curl_easy_setopt(easy, CURLOPT_PROXY, proxy));
        CHECK(!curl_easy_setopt(easy, CURLOPT_HTTPPROXYTUNNEL, 1L));
        // The loopback proxy is the case under test, and NO_PROXY in this environment names
        // 127.0.0.1; an empty list keeps the tunnel in the path.
        CHECK(!curl_easy_setopt(easy, CURLOPT_NOPROXY, ""));
    }
    CURLcode result = curl_easy_perform(easy);
    if (result != CURLE_OK)
        fprintf(stderr, "  %s: %s\n", path, curl_easy_strerror(result));
    CHECK(result == CURLE_OK);
    CHECK(!curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, status));
    CHECK(!curl_easy_getinfo(easy, CURLINFO_HTTP_CONNECTCODE, connectcode));
    curl_easy_cleanup(easy);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    alarm(120);
    CHECK(!curl_global_init(CURL_GLOBAL_DEFAULT));
    long status = 0, connectcode = 0;

    // A well-formed section is delivered whole.
    fetch(ORIGIN "/plain", NULL, &status, &connectcode);
    CHECK(status == 200 && colonless == 0 && statusLines == 1 && blankLines == 1);
    CHECK(strstr(delivered, "Content-Length: 2\r\n"));

    // A colon-less line between two field lines is dropped, and the fields around it survive.
    fetch(ORIGIN "/nocolon", NULL, &status, &connectcode);
    CHECK(status == 200 && colonless == 0);
    CHECK(!strstr(delivered, "ZYX"));
    CHECK(strstr(delivered, "Content-Type: text/plain\r\n") && strstr(delivered, "Content-Length: 2\r\n"));

    // The cookies/value/value.html shape: the bare LF ends the Set-Cookie line, and what follows it
    // is dropped rather than failing the response.
    fetch(ORIGIN "/bareLF", NULL, &status, &connectcode);
    CHECK(status == 200 && colonless == 0);
    CHECK(strstr(delivered, "Set-Cookie: test=13\n"));
    CHECK(!strstr(delivered, "ZYX"));

    // The same rule in the chunked trailer section, where a real trailer still arrives.
    fetch(ORIGIN "/trailer", NULL, &status, &connectcode);
    CHECK(status == 200 && colonless == 0);
    CHECK(!strstr(delivered, "TRAILERNOCOLON"));
    CHECK(strstr(delivered, "X-Tr: v\r\n"));

    // The CONNECT response's own section, whose dropped line must leave the tunnel able to read the
    // lines after it and the origin response behind them.
    fetch(ORIGIN "/plain", PROXY, &status, &connectcode);
    CHECK(status == 200 && connectcode == 200 && colonless == 0);
    CHECK(!strstr(delivered, "TUNNELNOCOLON"));
    CHECK(strstr(delivered, "X-Proxy: yes\r\n"));
    CHECK(strstr(delivered, "HTTP/1.1 200 Connection established\r\n"));
    CHECK(statusLines == 2 && blankLines == 2);
    CHECK(strstr(delivered, "Content-Length: 2\r\n"));

    curl_global_cleanup();
    puts("curl HTTP/1 header delivery, dropped non-field lines and tunnel continuation: FAILED=0");
    return 0;
}
