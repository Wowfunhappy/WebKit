// A wss:// server with a self-signed certificate, over the same BoringSSL the browser uses, so the
// handshake reaches certificate verification instead of failing on the protocol version. It serves
// one text frame and closes, which is enough to tell an accepted certificate from a refused one.
//
//   openssl req -x509 -newkey rsa:2048 -keyout self.key -out self.crt -days 30 -nodes -subj /CN=127.0.0.1
//   ./build/wsselfsigned 9444 self.crt self.key
//
// A page opening wss://127.0.0.1:9444/ then fails under wk1host, and opens under
// WK1HOST_ALLOW_ANY_SSL=1. Build with build.sh.
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <openssl/sha.h>
#include <openssl/base64.h>

static void b64(const uint8_t *in, size_t len, char *out, size_t cap)
{ size_t n = 0; EVP_EncodedLength(&n, len); (void)cap; EVP_EncodeBlock((uint8_t *)out, in, len); }

int main(int argc, char **argv)
{
    int port = atoi(argv[1]);
    SSL_CTX *ctx = SSL_CTX_new(TLS_method());
    if (SSL_CTX_use_certificate_file(ctx, argv[2], SSL_FILETYPE_PEM) != 1
        || SSL_CTX_use_PrivateKey_file(ctx, argv[3], SSL_FILETYPE_PEM) != 1) {
        fprintf(stderr, "bad certificate or key\n"); return 2;
    }
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in address; memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET; address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(0x7f000001);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 8)) {
        fprintf(stderr, "bind failed\n"); return 2;
    }
    printf("listening on %d\n", port); fflush(stdout);
    for (;;) {
        int client = accept(listener, NULL, NULL);
        SSL *ssl = SSL_new(ctx);
        SSL_set_fd(ssl, client);
        if (SSL_accept(ssl) != 1) {
            printf("handshake refused\n"); fflush(stdout);
            SSL_free(ssl); close(client); continue;
        }
        char request[4096]; int n = SSL_read(ssl, request, sizeof(request) - 1);
        if (n <= 0) { SSL_free(ssl); close(client); continue; }
        request[n] = 0;
        char *key = strstr(request, "Sec-WebSocket-Key: ");
        char accept_header[64] = "";
        if (key) {
            key += strlen("Sec-WebSocket-Key: ");
            char *end = strstr(key, "\r\n");
            char combined[256];
            snprintf(combined, sizeof(combined), "%.*s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", (int)(end - key), key);
            uint8_t digest[SHA_DIGEST_LENGTH];
            SHA1((const uint8_t *)combined, strlen(combined), digest);
            b64(digest, sizeof(digest), accept_header, sizeof(accept_header));
        }
        char response[256];
        int len = snprintf(response, sizeof(response),
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n", accept_header);
        SSL_write(ssl, response, len);
        const char *payload = "selfsigned";
        uint8_t frame[2 + 10];
        frame[0] = 0x81; frame[1] = (uint8_t)strlen(payload);
        memcpy(frame + 2, payload, strlen(payload));
        SSL_write(ssl, frame, 2 + strlen(payload));
        printf("served one connection\n"); fflush(stdout);
        SSL_shutdown(ssl); SSL_free(ssl); close(client);
    }
}
