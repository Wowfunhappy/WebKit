// The resolver result follows a connection through reuse, DNS-cache hits and easy-handle reset.
#include <curl/curl.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "canonical-name FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
extern unsigned fixtureResolutionCount(void);

static void *serveConnection(void *context)
{
    int connection = (int)(intptr_t)context;
    char request[8192];
    size_t used = 0;
    static const char reply[] = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
    for (;;) {
        ssize_t received = recv(connection, request + used, sizeof(request) - used - 1, 0);
        if (received <= 0)
            break;
        used += (size_t)received;
        request[used] = 0;
        if (!strstr(request, "\r\n\r\n")) {
            CHECK(used < sizeof(request) - 1);
            continue;
        }
        for (size_t sent = 0; sent < sizeof(reply) - 1; ) {
            ssize_t count = send(connection, reply + sent, sizeof(reply) - 1 - sent, 0);
            CHECK(count > 0);
            sent += (size_t)count;
        }
        used = 0;
    }
    close(connection);
    return NULL;
}

static void *serve(void *context)
{
    int listener = (int)(intptr_t)context;
    for (;;) {
        int connection = accept(listener, NULL, NULL);
        if (connection < 0)
            return NULL;
        pthread_t thread;
        CHECK(!pthread_create(&thread, NULL, serveConnection, (void *)(intptr_t)connection));
        pthread_detach(thread);
    }
}

static size_t discard(char *bytes, size_t size, size_t count, void *context)
{
    (void)bytes;
    (void)context;
    return size * count;
}

static void configure(CURL *easy, const char *url)
{
    CHECK(curl_easy_setopt(easy, CURLOPT_URL, url) == CURLE_OK);
    CHECK(curl_easy_setopt(easy, CURLOPT_PROXY, "") == CURLE_OK);
    CHECK(curl_easy_setopt(easy, CURLOPT_NOPROXY, "*") == CURLE_OK);
    CHECK(curl_easy_setopt(easy, CURLOPT_IPRESOLVE, (long)CURL_IPRESOLVE_V4) == CURLE_OK);
    CHECK(curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, discard) == CURLE_OK);
    CHECK(curl_easy_setopt(easy, CURLOPT_TIMEOUT, 10L) == CURLE_OK);
}

static void expectName(CURL *easy, const char *expected)
{
    char *name = NULL;
    CHECK(curl_easy_getinfo(easy, CURLINFO_PRIMARY_CANONICAL_NAME, &name) == CURLE_OK);
    CHECK(expected ? name && !strcmp(name, expected) : !name);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    alarm(60);
    CHECK(curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(listener >= 0);
    struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET };
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(!bind(listener, (struct sockaddr *)&address, sizeof(address)));
    CHECK(!listen(listener, 8));
    socklen_t length = sizeof(address);
    CHECK(!getsockname(listener, (struct sockaddr *)&address, &length));
    pthread_t server;
    CHECK(!pthread_create(&server, NULL, serve, (void *)(intptr_t)listener));
    char aliasURL[128], plainURL[128], proxy[128];
    snprintf(aliasURL, sizeof(aliasURL), "http://alias.curl.test:%u/", ntohs(address.sin_port));
    snprintf(plainURL, sizeof(plainURL), "http://plain.curl.test:%u/", ntohs(address.sin_port));
    snprintf(proxy, sizeof(proxy), "http://alias.curl.test:%u", ntohs(address.sin_port));
    CURL *easy = curl_easy_init();
    CHECK(easy);
    expectName(easy, NULL);
    configure(easy, aliasURL);
    CHECK(curl_easy_perform(easy) == CURLE_OK);
    expectName(easy, "canonical.curl.test");
    CHECK(fixtureResolutionCount() == 1);
    CHECK(curl_easy_perform(easy) == CURLE_OK);
    expectName(easy, "canonical.curl.test");
    long newConnections = -1;
    CHECK(curl_easy_getinfo(easy, CURLINFO_NUM_CONNECTS, &newConnections) == CURLE_OK);
    CHECK(!newConnections && fixtureResolutionCount() == 1);
    CHECK(curl_easy_setopt(easy, CURLOPT_FRESH_CONNECT, 1L) == CURLE_OK);
    CHECK(curl_easy_perform(easy) == CURLE_OK);
    expectName(easy, "canonical.curl.test");
    CHECK(fixtureResolutionCount() == 1);
    curl_easy_reset(easy);
    expectName(easy, NULL);
    configure(easy, plainURL);
    CHECK(curl_easy_perform(easy) == CURLE_OK);
    expectName(easy, "plain.curl.test");
    CHECK(fixtureResolutionCount() == 2);
    configure(easy, "http://origin.curl.test/");
    CHECK(curl_easy_setopt(easy, CURLOPT_PROXY, proxy) == CURLE_OK);
    CHECK(curl_easy_setopt(easy, CURLOPT_NOPROXY, "") == CURLE_OK);
    CHECK(curl_easy_perform(easy) == CURLE_OK);
    expectName(easy, NULL);
    CHECK(fixtureResolutionCount() == 2);
    configure(easy, "http://[invalid/");
    CHECK(curl_easy_perform(easy) == CURLE_URL_MALFORMAT);
    expectName(easy, NULL);
    curl_easy_cleanup(easy);
    close(listener);
    puts("canonical name: connection, reuse, DNS cache, reset, proxy and failed transfer PASS");
    return 0;
}
