// A complete END_STREAM remains successful; missing END_STREAM and RST_STREAM must fail.
#include <curl/curl.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef OPENSSL_IS_BORINGSSL
#error The deployed headers must be BoringSSL
#endif
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "HTTP/2 stream FAIL line %d: %s\n", __LINE__, #x); ERR_print_errors_fp(stderr); exit(1); } } while (0)
static const char body[] = "BoringSSL curl local decrypted response: 0123456789 abcdefghijklmnopqrstuvwxyz\n";
static int ctx_calls, verify_calls;
static int scenario;
static char received[1024];
static size_t received_size;
static int verify(int ok, X509_STORE_CTX *store) {
    SSL *ssl = X509_STORE_CTX_get_ex_data(store, SSL_get_ex_data_X509_STORE_CTX_idx());
    CHECK(ssl && SSL_CTX_get_app_data(SSL_get_SSL_CTX(ssl)) == &ctx_calls);
    ++verify_calls;
    return ok;
}
static CURLcode ctx_callback(CURL *curl, void *ctx, void *unused) {
    ++ctx_calls;
    SSL_CTX_set_app_data(ctx, &ctx_calls);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, verify);
    return CURLE_OK;
}
static size_t consume(char *p, size_t size, size_t count, void *unused) {
    size_t n = size * count;
    if (n > sizeof received - received_size) return 0;
    memcpy(received + received_size, p, n); received_size += n;
    return n;
}
static void read_exact(SSL *ssl, void *p, size_t n) {
    while (n) { int r = SSL_read(ssl, p, n); CHECK(r > 0); p = (char *)p + r; n -= r; }
}
static void write_exact(SSL *ssl, const void *p, size_t n) {
    while (n) { int r = SSL_write(ssl, p, n); CHECK(r > 0); p = (const char *)p + r; n -= r; }
}
static int alpn(SSL *ssl, const unsigned char **out, unsigned char *len,
                const unsigned char *in, unsigned int n, void *arg) {
    const unsigned char h2[] = {2,'h','2'};
    CHECK(SSL_select_next_proto((unsigned char **)out, len, h2, sizeof h2, in, n) == OPENSSL_NPN_NEGOTIATED);
    *out = (const unsigned char *)"h2"; *len = 2;
    return SSL_TLSEXT_ERR_OK;
}
static void frame(SSL *ssl, int type, int flags, unsigned stream, const void *p, unsigned n) {
    unsigned char h[9] = {n >> 16, n >> 8, n, type, flags, stream >> 24, stream >> 16, stream >> 8, stream};
    write_exact(ssl, h, sizeof h); if (n) write_exact(ssl, p, n);
}
static void server(int listener, const char *cert, const char *key, int mode) {
    alarm(20);
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method()); CHECK(ctx);
    CHECK(SSL_CTX_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM));
    CHECK(SSL_CTX_use_PrivateKey_file(ctx, key, SSL_FILETYPE_PEM));
    CHECK(SSL_CTX_set_min_proto_version(ctx, TLS1_3_VERSION));
    SSL_CTX_set_alpn_select_cb(ctx, alpn, NULL);
    int fd = accept(listener, NULL, NULL); CHECK(fd >= 0);
    SSL *ssl = SSL_new(ctx); CHECK(ssl && SSL_set_fd(ssl, fd));
    int accepted = SSL_accept(ssl);
    CHECK(accepted == 1);
    if ((mode == 1 || mode == 6)) {
        char preface[24]; read_exact(ssl, preface, sizeof preface);
        CHECK(!memcmp(preface, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24));
        frame(ssl, 4, 0, 0, NULL, 0);
        unsigned stream = 0;
        while (!stream) {
            unsigned char h[9]; read_exact(ssl, h, 9);
            unsigned n = ((unsigned)h[0] << 16) | ((unsigned)h[1] << 8) | h[2];
            CHECK(n < 65536); unsigned char buf[65536]; read_exact(ssl, buf, n);
            if (h[3] == 4 && !(h[4] & 1)) frame(ssl, 4, 1, 0, NULL, 0);
            if (h[3] == 1) {
                CHECK(h[4] & 4);
                stream = ((unsigned)(h[5] & 127) << 24) | ((unsigned)h[6] << 16) | ((unsigned)h[7] << 8) | h[8];
            }
        }
        const unsigned char status200 = 0x88;
        frame(ssl, 1, 4, stream, &status200, 1);
        frame(ssl, 0, scenario ? 0 : 1, stream, body, scenario ? 3 : sizeof body - 1);
        if (scenario == 2) {
            const unsigned char internalError[4] = { 0, 0, 0, 2 };
            frame(ssl, 3, 0, stream, internalError, sizeof internalError);
        }
    }
    SSL_shutdown(ssl); SSL_free(ssl); SSL_CTX_free(ctx); close(fd);
}
static void transfer(const char *cert, const char *key, int mode) {
    int listener = socket(AF_INET, SOCK_STREAM, 0); CHECK(listener >= 0);
    struct sockaddr_in addr; memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    CHECK(!bind(listener, (struct sockaddr *)&addr, sizeof addr) && !listen(listener, 1));
    socklen_t len = sizeof addr; CHECK(!getsockname(listener, (struct sockaddr *)&addr, &len));
    fflush(NULL); pid_t pid = fork(); CHECK(pid >= 0);
    if (!pid) { server(listener, cert, key, mode); _exit(0); }
    char url[128]; snprintf(url, sizeof url, "https://localhost:%u/", ntohs(addr.sin_port));
    char resolve[128]; snprintf(resolve, sizeof resolve, "localhost:%u:127.0.0.1", ntohs(addr.sin_port));
    struct curl_slist *hosts = curl_slist_append(NULL, resolve); CHECK(hosts);
    CURL *curl = curl_easy_init(); CHECK(curl);
#define OPT(k, v) CHECK(curl_easy_setopt(curl, k, v) == CURLE_OK)
    char error[CURL_ERROR_SIZE] = {0};
    received_size = 0; ctx_calls = 0; verify_calls = 0;
    OPT(CURLOPT_URL, url); OPT(CURLOPT_RESOLVE, hosts); OPT(CURLOPT_PROXY, ""); OPT(CURLOPT_NOPROXY, "*");
    OPT(CURLOPT_TIMEOUT, 15L); OPT(CURLOPT_ERRORBUFFER, error); OPT(CURLOPT_ACCEPT_ENCODING, "");
    OPT(CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_3); OPT(CURLOPT_SSL_CTX_FUNCTION, ctx_callback);
    OPT(CURLOPT_SSL_VERIFYPEER, 1L); OPT(CURLOPT_SSL_VERIFYHOST, 2L);
    OPT(CURLOPT_CAINFO, cert); OPT(CURLOPT_CAPATH, NULL);
    OPT(CURLOPT_HTTP_VERSION, (mode == 1 || mode == 6) ? CURL_HTTP_VERSION_2TLS : CURL_HTTP_VERSION_1_1);
    OPT(CURLOPT_WRITEFUNCTION, consume);
    if (mode == 5 || mode == 6) {
        OPT(CURLOPT_CONNECT_ONLY, CURL_CONNECT_ONLY_REUSABLE);
        CHECK(curl_easy_perform(curl) == CURLE_OK);
        long request_bytes = -1, connections = -1;
        CHECK(curl_easy_getinfo(curl, CURLINFO_REQUEST_SIZE, &request_bytes) == CURLE_OK);
        CHECK(curl_easy_getinfo(curl, CURLINFO_NUM_CONNECTS, &connections) == CURLE_OK);
        CHECK(request_bytes == 0 && connections == 1 && received_size == 0);
        OPT(CURLOPT_CONNECT_ONLY, 0L);
    }
    CURLcode rc = curl_easy_perform(curl);
    if (mode == 5 || mode == 6) {
        long connections = -1;
        CHECK(curl_easy_getinfo(curl, CURLINFO_NUM_CONNECTS, &connections) == CURLE_OK);
        CHECK(connections == 0);
        puts("reusable preconnect: no HTTP request, subsequent transfer reused TLS connection PASS");
    }
    long status = 0, version = 0, proxy = -1;
    CHECK(!curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status));
    CHECK(!curl_easy_getinfo(curl, CURLINFO_HTTP_VERSION, &version));
    CHECK(!curl_easy_getinfo(curl, CURLINFO_USED_PROXY, &proxy));
    fprintf(stdout, "curl stream mode=%d rc=%d http=%ld version=%ld proxy=%ld ctx=%d verify=%d bytes=%lu error=%s\n", mode, rc, status, version, proxy, ctx_calls, verify_calls, (unsigned long)received_size, error);
    curl_easy_cleanup(curl); curl_slist_free_all(hosts); close(listener);
    int child; CHECK(waitpid(pid, &child, 0) == pid && WIFEXITED(child) && !WEXITSTATUS(child));
    CHECK(proxy == 0 && ctx_calls == 1 && verify_calls > 0);
    if (scenario) {
        CHECK(rc != CURLE_OK && status == 200 && received_size == 3);
        printf("HTTP/2 unfinished stream scenario=%d propagated actual error=%d PASS\n", scenario, rc);
        return;
    }
    CHECK(rc == CURLE_OK && status == 200);
    CHECK(version == ((mode == 1 || mode == 6) ? CURL_HTTP_VERSION_2_0 : CURL_HTTP_VERSION_1_1));
    CHECK(received_size == sizeof body - 1 && !memcmp(received, body, received_size));
}
int main(int argc, char **argv) {
    CHECK(argc == 3); signal(SIGPIPE, SIG_IGN); alarm(70);
    CHECK(!curl_global_init(CURL_GLOBAL_DEFAULT));
    for (scenario = 0; scenario != 3; ++scenario) transfer(argv[1], argv[2], 6);
    curl_global_cleanup(); puts("HTTP/2 complete, truncated, and reset streams: FAILED=0"); return 0;
}
