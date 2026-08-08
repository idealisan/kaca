#include "base64.h"
#include <stdlib.h>
#include <string.h>

static const char B64[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

void base64_encode(const uint8_t *in, size_t len, char **out) {
    size_t outlen = ((len + 2) / 3) * 4 + 1;
    char *s = (char *)malloc(outlen);
    if (!s) { *out = NULL; return; }
    size_t o = 0;
    for (size_t i = 0; i < len; i += 3) {
        uint32_t b = ((uint32_t)in[i]) << 16;
        if (i + 1 < len) b |= ((uint32_t)in[i + 1]) << 8;
        if (i + 2 < len) b |=  ((uint32_t)in[i + 2]);
        int n = (len - i) >= 3 ? 3 : (int)(len - i);

        s[o++] = B64[(b >> 18) & 0x3F];
        s[o++] = B64[(b >> 12) & 0x3F];
        if (n >= 2) s[o++] = B64[(b >> 6) & 0x3F];
        else        s[o++] = '=';
        if (n >= 3) s[o++] = B64[b & 0x3F];
        else        s[o++] = '=';
    }
    s[o] = '\0';
    *out = s;
}
