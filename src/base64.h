#ifndef BASE64_H
#define BASE64_H

#include <stddef.h>
#include <stdint.h>

/* 将 in[0..len) 编码为 base64 字符串，结果写入 *out（调用方负责 free）*/
void base64_encode(const uint8_t *in, size_t len, char **out);

#endif /* BASE64_H */
