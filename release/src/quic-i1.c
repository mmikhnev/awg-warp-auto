/* Mini QUIC compatible TLS SNI cover-packet generator. No network access.
 * Algorithm reference: https://sageptr.github.io/mini_quic_generator/quic.js
 * and https://warp-generation.github.io/quic.js . */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>
#include <mbedtls/aes.h>
#include <mbedtls/gcm.h>
#include <mbedtls/md.h>

typedef struct { unsigned char b[2048]; size_t n; } buffer;
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
static void frame(buffer *b, const buffer *hello, size_t start, size_t end) {
    byte(b, 6); varint(b, start); varint(b, end-start); append(b, hello->b+start, end-start);
}
static void hmac(const unsigned char *key, size_t klen, const unsigned char *data, size_t len, unsigned char out[32]) {
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!md || mbedtls_md_hmac(md, key, klen, data, len, out)) die("HMAC failed");
}
static void derive(const unsigned char key[32], size_t n, const char *label, unsigned char *out) {
    buffer info = {{0},0}; unsigned char digest[32];
    u16(&info,n); byte(&info,(unsigned)(6+strlen(label))); append(&info,"tls13 ",6);
    append(&info,label,strlen(label)); byte(&info,0); byte(&info,1);
    hmac(key,32,info.b,info.n,digest); memcpy(out,digest,n);
}
static int hexval(char c) {
    if (c >= '0' && c <= '9') return c-'0';
    if (c >= 'a' && c <= 'f') return c-'a'+10;
    if (c >= 'A' && c <= 'F') return c-'A'+10;
    return -1;
}
static void unhex(const char *s, unsigned char *out, size_t n) {
    size_t i; if (strlen(s) != n*2) die("incorrect hex length");
    for (i=0;i<n;i++) { int a=hexval(s[i*2]), b=hexval(s[i*2+1]);
        if (a<0 || b<0) die("invalid hex");
        out[i]=(unsigned char)(a*16+b); }
}
static void hex(const unsigned char *p, size_t n) { size_t i; for(i=0;i<n;i++) printf("%02x",p[i]); }
static void random_bytes(unsigned char *p,size_t n) {
    FILE *f=fopen("/dev/urandom","rb");
    if (!f) die("cannot open /dev/urandom");
    if (fread(p,1,n,f)!=n) die("random source failed");
    fclose(f);
}
static void validate_sni(const char *s) {
    size_t i,n=strlen(s),label=0;
    if (!n || n>253) die("invalid SNI length");
    for(i=0;i<n;i++) {
        unsigned char c=(unsigned char)s[i];
        if (c=='.') { if (!label || s[i-1]=='-') die("invalid SNI label"); label=0; }
        else { if (!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-')) die("SNI must be ASCII hostname");
            if ((!label && c=='-') || ++label>63) die("invalid SNI label"); }
    }
    if (!label || s[n-1]=='-') die("invalid SNI label");
}
int main(int argc,char **argv) {
    const char *sni=NULL,*dcid_arg=NULL,*random_arg=NULL;
    int level=4,raw=0,i; size_t sn,cut[4]={0},cuts=2,padding,offset;
    unsigned char dcid,random[32],initial[32],client[32],key[16],iv[12],hp[16],mask[16];
    const unsigned char salt[]={0x38,0x76,0x2c,0xf7,0xf5,0x59,0x34,0xb3,0x4d,0x17,0x9a,0xe6,0xa4,0xc8,0x0c,0xad,0xcc,0xbb,0x7f,0x0a};
    buffer hello={{0},0},payload={{0},0},header={{0},0},packet={{0},0};
    mbedtls_gcm_context gcm; mbedtls_aes_context aes;
    for(i=1;i<argc;i++) {
        if (!strcmp(argv[i],"--raw")) raw=1;
        else if (!strcmp(argv[i],"--sni") && i+1<argc) sni=argv[++i];
        else if (!strcmp(argv[i],"--dcid") && i+1<argc) dcid_arg=argv[++i];
        else if (!strcmp(argv[i],"--random") && i+1<argc) random_arg=argv[++i];
        else if (!strcmp(argv[i],"--level") && i+1<argc) {
            const char *v=argv[++i]; if (strlen(v)!=1 || *v<'0' || *v>'4') die("level must be 0..4"); level=*v-'0';
        } else die("usage: quic-i1 --sni HOST [--level 0..4] [--raw] [--dcid XX --random HEX64]");
    }
    if (!sni) die("--sni required");
    validate_sni(sni); sn=strlen(sni);
    if (dcid_arg) unhex(dcid_arg,&dcid,1); else random_bytes(&dcid,1);
    if (random_arg) unhex(random_arg,random,32); else random_bytes(random,32);
    /* TLS ClientHello with only SNI, identical to quicTlsClientHelloSniOnly. */
    byte(&hello,1); byte(&hello,0); u16(&hello,49+sn); byte(&hello,3); byte(&hello,3);
    append(&hello,random,32); u16(&hello,0); u16(&hello,0);
    u16(&hello,9+sn); u16(&hello,0); u16(&hello,5+sn); u16(&hello,3+sn); byte(&hello,0); u16(&hello,sn); append(&hello,sni,sn);
    if (!level) {
        frame(&payload,&hello,0,hello.n); cut[0]=payload.n-hello.n+6; cut[1]=32; cut[2]=hello.n-38; cut[3]=16; cuts=4;
    } else if (level==1 || level==2) {
        frame(&payload,&hello,38,hello.n); frame(&payload,&hello,0,38);
        cut[0]=payload.n-(level==1?32:37); cut[1]=16+(level==1?32:37);
    } else {
        size_t start=38; if (level==4) while(start<hello.n && !hello.b[start]) start++;
        frame(&payload,&hello,0,1); frame(&payload,&hello,start,hello.n);
        cut[0]=payload.n; cut[1]=16;
    }
    padding=payload.n<3?3-payload.n:0;
    byte(&header,0xc0); byte(&header,0); byte(&header,0); byte(&header,0); byte(&header,1);
    byte(&header,1); byte(&header,dcid); byte(&header,0); byte(&header,0);
    varint(&header,1+payload.n+padding+16); byte(&header,0);
    hmac(salt,sizeof(salt),&dcid,1,initial); derive(initial,32,"client in",client);
    derive(client,16,"quic key",key); derive(client,12,"quic iv",iv); derive(client,16,"quic hp",hp);
    while(padding--) byte(&payload,0);
    append(&packet,header.b,header.n);
    mbedtls_gcm_init(&gcm);
    if (mbedtls_gcm_setkey(&gcm,MBEDTLS_CIPHER_ID_AES,key,128) ||
        mbedtls_gcm_crypt_and_tag(&gcm,MBEDTLS_GCM_ENCRYPT,payload.n,iv,12,header.b,header.n,payload.b,packet.b+header.n,16,packet.b+header.n+payload.n)) die("AES-GCM failed");
    mbedtls_gcm_free(&gcm); packet.n+=payload.n+16;
    mbedtls_aes_init(&aes);
    if (mbedtls_aes_setkey_enc(&aes,hp,128) || mbedtls_aes_crypt_ecb(&aes,MBEDTLS_AES_ENCRYPT,packet.b+header.n+3,mask)) die("header protection failed");
    mbedtls_aes_free(&aes); packet.b[0]^=mask[0]&15; packet.b[header.n-1]^=mask[1];
    if (raw) hex(packet.b,packet.n);
    else {
        if(cut[0]<19) { size_t add=19-cut[0]; cut[0]+=add; cut[1]-=add; }
        cut[0]+=header.n; offset=0;
        for(i=0;i<(int)cuts;i++) { if(cut[i]) {
            if(i%2) printf("<r %zu>",cut[i]); else { printf("<b 0x"); hex(packet.b+offset,cut[i]); printf(">"); }
            offset+=cut[i]; }
        }
    }
    putchar('\n'); return 0;
}
