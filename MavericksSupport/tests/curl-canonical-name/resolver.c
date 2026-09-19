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
#define MOCK_ADDRINFO 0x40000000
static atomic_uint resolutions;

static int fixtureGetAddrInfo(const char *host, const char *service, const struct addrinfo *hints, struct addrinfo **result)
{
    *result = NULL;
    if (strcmp(host, "alias.curl.test") && strcmp(host, "plain.curl.test"))
        return EAI_NONAME;
    atomic_fetch_add(&resolutions, 1);
    CHECK(hints && (hints->ai_flags & AI_CANONNAME));
    CHECK(hints->ai_family == AF_INET);
    struct addrinfo *ai = calloc(1, sizeof(*ai));
    struct sockaddr_in *address = calloc(1, sizeof(*address));
    CHECK(ai && address);
    address->sin_len = sizeof(*address);
    address->sin_family = AF_INET;
    address->sin_port = htons((unsigned short)atoi(service));
    address->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    ai->ai_flags = MOCK_ADDRINFO;
    ai->ai_family = AF_INET;
    ai->ai_socktype = SOCK_STREAM;
    ai->ai_protocol = IPPROTO_TCP;
    ai->ai_addrlen = sizeof(*address);
    ai->ai_addr = (struct sockaddr *)address;
    ai->ai_canonname = strdup(!strcmp(host, "alias.curl.test") ? "canonical.curl.test" : host);
    CHECK(ai->ai_canonname);
    *result = ai;
    return 0;
}

static void fixtureFreeAddrInfo(struct addrinfo *ai)
{
    if (ai && ai->ai_flags != MOCK_ADDRINFO) {
        void (*original)(struct addrinfo *) = dlsym(RTLD_NEXT, "freeaddrinfo");
        CHECK(original);
        original(ai);
        return;
    }
    while (ai) {
        struct addrinfo *next = ai->ai_next;
        free(ai->ai_canonname);
        free(ai->ai_addr);
        free(ai);
        ai = next;
    }
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } resolverInterpositions[] = {
    { fixtureGetAddrInfo, getaddrinfo }, { fixtureFreeAddrInfo, freeaddrinfo }
};


unsigned fixtureResolutionCount(void) { return atomic_load(&resolutions); }
