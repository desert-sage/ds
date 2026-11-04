/* sha256 — minimal SHA-256 (FIPS 180-4), so libds needs no libcrypto. */
#ifndef LIBDS_SHA256_H
#define LIBDS_SHA256_H

#include <stddef.h>
#include <stdint.h>

#define DS_SHA256_DIGEST_LEN 32u

typedef struct ds_sha256_ctx {
    uint32_t state[8];
    uint64_t bitlen;
    uint32_t datalen;
    uint8_t  data[64];
} ds_sha256_ctx_t;

void ds_sha256_init(ds_sha256_ctx_t *ctx);
void ds_sha256_update(ds_sha256_ctx_t *ctx, const uint8_t *data, size_t len);
void ds_sha256_final(ds_sha256_ctx_t *ctx, uint8_t out[DS_SHA256_DIGEST_LEN]);

void ds_sha256(const uint8_t *data, size_t len,
                uint8_t out[DS_SHA256_DIGEST_LEN]);

#endif
