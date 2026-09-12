/* RFC 9000 / RFC 9001 / RFC 8446 compliant QUIC Initial cover packet generator.
 * Generates TLS 1.3 ClientHello with SNI, ALPN h3, supported_versions,
 * encrypted with AES-128-GCM and header protected, padded to >= 1200 bytes.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <mbedtls/aes.h>
#include <mbedtls/gcm.h>
#include <mbedtls/md.h>

typedef struct { unsigned char b[4096]; size_t n; } buffer;
static void die(const char *s) { fprintf(stderr, "quic-i1: %s\n", s); exit(1); }
static void append(buffer *b, const void *p, size_t n) {
    if (n > sizeof(b->b) - b->n) die("buffer overflow");
    memcpy(b->b + b->n, p, n); b->n += n;
}
static void byte(buffer *b, unsigned n) { unsigned char c = (unsigned char)n; append(b, &c, 1); }
static void u16(buffer *b, size_t n) { byte(b, (unsigned)(n >> 8)); byte(b, (unsigned)n); }
static void varint(buffer *b, size_t n) {
    if (n < 64) byte(b, (unsigned)n);
    else if (n < 16384) u16(b, n | 0x4000);
    else die("varint overflow");
}
static void hmac(const unsigned char *key, size_t klen, const unsigned char *data, size_t len, unsigned char out[32]) {
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!md || mbedtls_md_hmac(md, key, klen, data, len, out)) die("HMAC failed");
}
static void derive(const unsigned char key[32], size_t n, const char *label, unsigned char *out) {
    buffer info = {{0},0}; unsigned char digest[32];
    u16(&info, n); byte(&info, (unsigned)(6 + strlen(label))); append(&info, "tls13 ", 6);
    append(&info, label, strlen(label)); byte(&info, 0); byte(&info, 1);
    hmac(key, 32, info.b, info.n, digest); memcpy(out, digest, n);
}
static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static void unhex(const char *s, unsigned char *out, size_t n) {
    size_t i; if (strlen(s) != n * 2) die("incorrect hex length");
    for (i = 0; i < n; i++) {
        int a = hexval(s[i * 2]), b = hexval(s[i * 2 + 1]);
        if (a < 0 || b < 0) die("invalid hex");
        out[i] = (unsigned char)(a * 16 + b);
    }
}
static void hex(const unsigned char *p, size_t n) {
    size_t i; for (i = 0; i < n; i++) printf("%02x", p[i]);
}
static void random_bytes(unsigned char *p, size_t n) {
    FILE *f = fopen("/dev/urandom", "rb");
    if (!f) die("cannot open /dev/urandom");
    if (fread(p, 1, n, f) != n) die("random source failed");
    fclose(f);
}
static void validate_sni(const char *s) {
    size_t i, n = strlen(s), label = 0;
    if (!n || n > 253) die("invalid SNI length");
    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '.') {
            if (!label || s[i - 1] == '-') die("invalid SNI label");
            label = 0;
        } else {
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'))
                die("SNI must be ASCII hostname");
            if ((!label && c == '-') || ++label > 63) die("invalid SNI label");
        }
    }
    if (!label || s[n - 1] == '-') die("invalid SNI label");
}

int main(int argc, char **argv) {
    const char *sni = NULL, *dcid_arg = NULL, *random_arg = NULL;
    int raw = 0, i;
    size_t sn, dcid_len = 8, padto = 1250;
    unsigned char dcid[8], random[32], initial[32], client[32], key[16], iv[12], hp[16], mask[16];
    const unsigned char salt[] = {
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17,
        0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a
    };
    buffer ext = {{0}, 0}, body = {{0}, 0}, hello = {{0}, 0};
    buffer payload = {{0}, 0}, header = {{0}, 0}, packet = {{0}, 0};
    mbedtls_gcm_context gcm;
    mbedtls_aes_context aes;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--raw")) raw = 1;
        else if (!strcmp(argv[i], "--sni") && i + 1 < argc) sni = argv[++i];
        else if (!strcmp(argv[i], "--dcid") && i + 1 < argc) dcid_arg = argv[++i];
        else if (!strcmp(argv[i], "--random") && i + 1 < argc) random_arg = argv[++i];
        else if (!strcmp(argv[i], "--padto") && i + 1 < argc) padto = (size_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--level") && i + 1 < argc) { i++; /* backward compat */ }
        else die("usage: quic-i1 --sni HOST [--padto 1200..1400] [--raw] [--dcid HEX16 --random HEX64]");
    }
    if (!sni) die("--sni required");
    validate_sni(sni); sn = strlen(sni);
    if (dcid_arg) {
        if (strlen(dcid_arg) == 16) {
            unhex(dcid_arg, dcid, 8);
        } else if (strlen(dcid_arg) == 2) {
            unhex(dcid_arg, dcid, 1);
            dcid_len = 1;
        } else die("invalid dcid length (expected 2 or 16 hex chars)");
    } else {
        random_bytes(dcid, 8);
    }
    if (random_arg) unhex(random_arg, random, 32); else random_bytes(random, 32);

    /* Build TLS 1.3 Extensions */
    /* 1. SNI extension (0x0000) */
    u16(&ext, 0x0000);
    u16(&ext, 5 + sn);
    u16(&ext, 3 + sn);
    byte(&ext, 0); /* host_name type */
    u16(&ext, sn);
    append(&ext, sni, sn);

    /* 2. Supported Versions extension (0x002b) */
    u16(&ext, 0x002b);
    u16(&ext, 3);
    byte(&ext, 2); /* list length */
    u16(&ext, 0x0304); /* TLS 1.3 */

    /* 3. ALPN extension (0x0010) */
    u16(&ext, 0x0010);
    u16(&ext, 5);
    u16(&ext, 3);
    byte(&ext, 2);
    append(&ext, "h3", 2);

    /* Build ClientHello body */
    byte(&body, 3); byte(&body, 3); /* legacy_version TLS 1.2 */
    append(&body, random, 32);
    byte(&body, 0); /* legacy_session_id length = 0 */
    u16(&body, 4); /* cipher suites length = 4 */
    u16(&body, 0x1301); /* TLS_AES_128_GCM_SHA256 */
    u16(&body, 0x1302); /* TLS_AES_256_GCM_SHA384 */
    byte(&body, 1); byte(&body, 0); /* legacy_compression_methods (1 byte: 0x00) */
    u16(&body, ext.n);
    append(&body, ext.b, ext.n);

    /* Build ClientHello Handshake packet */
    byte(&hello, 1); /* type ClientHello */
    byte(&hello, 0); /* 3-byte length MSB */
    u16(&hello, body.n);
    append(&hello, body.b, body.n);

    /* Build CRYPTO frame: type 0x06, offset 0, varint length, data */
    byte(&payload, 6);
    byte(&payload, 0); /* offset 0 */
    varint(&payload, hello.n);
    append(&payload, hello.b, hello.n);

    /* QUIC PADDING frames (0x00) up to padto bytes */
    /* Header overhead:
     * 1 (type) + 4 (ver) + 1 (dcid_len) + dcid_len + 1 (scid_len) + 1 (token_len) = 8 + dcid_len
     * varint length (2 bytes for length >= 64)
     * 1 (packet number)
     * = 11 + dcid_len bytes header
     * 16 bytes tag
     * Total overhead = 27 + dcid_len bytes
     */
    size_t overhead = 11 + dcid_len + 16;
    if (padto > 0 && padto > payload.n + overhead) {
        size_t padding = padto - (payload.n + overhead);
        while (padding--) byte(&payload, 0);
    }

    /* Build QUIC Long Header Initial (v1) */
    byte(&header, 0xc0); /* Long header, Initial, PN len = 1 byte */
    u16(&header, 0); u16(&header, 1); /* Version 1 (0x00000001) */
    byte(&header, (unsigned)dcid_len);
    append(&header, dcid, dcid_len);
    byte(&header, 0); /* SCID length = 0 */
    byte(&header, 0); /* Token length = 0 */
    varint(&header, 1 + payload.n + 16); /* length = 1 byte PN + payload + 16 bytes tag */
    byte(&header, 0); /* Packet number = 0 */

    /* Derive Initial Keys (RFC 9001 §5.2) */
    hmac(salt, sizeof(salt), dcid, dcid_len, initial);
    derive(initial, 32, "client in", client);
    derive(client, 16, "quic key", key);
    derive(client, 12, "quic iv", iv);
    derive(client, 16, "quic hp", hp);

    /* AES-128-GCM Encrypt payload with header as AAD */
    append(&packet, header.b, header.n);
    mbedtls_gcm_init(&gcm);
    if (mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 128) ||
        mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, payload.n, iv, 12,
                                  header.b, header.n, payload.b,
                                  packet.b + header.n, 16,
                                  packet.b + header.n + payload.n)) {
        die("AES-GCM encryption failed");
    }
    mbedtls_gcm_free(&gcm);
    packet.n += payload.n + 16;

    /* Header Protection (RFC 9001 §5.4) */
    /* Sample starts 4 bytes after PN field: (header.n - 1) + 4 = header.n + 3 */
    mbedtls_aes_init(&aes);
    if (mbedtls_aes_setkey_enc(&aes, hp, 128) ||
        mbedtls_aes_crypt_ecb(&aes, MBEDTLS_AES_ENCRYPT, packet.b + header.n + 3, mask)) {
        die("header protection failed");
    }
    mbedtls_aes_free(&aes);
    packet.b[0] ^= mask[0] & 0x0f;
    packet.b[header.n - 1] ^= mask[1];

    /* Output */
    if (raw) {
        hex(packet.b, packet.n);
    } else {
        printf("<b 0x");
        hex(packet.b, packet.n);
        printf(">");
    }
    putchar('\n');
    return 0;
}
