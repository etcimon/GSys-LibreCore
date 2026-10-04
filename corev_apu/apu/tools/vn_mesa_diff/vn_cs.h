/* Copyright 2026 Etienne Cimon */
/* SPDX-License-Identifier: MIT */
/*
 * vn_cs.h stub for the vn_mesa_diff harness.
 *
 * Implements the API the generated Mesa venus-protocol driver headers
 * expect (see vn_protocol_driver_cs.h): a byte-buffer encoder, aborting
 * decoder, handle<->id map where ids ARE the handle values, and the
 * renderer-protocol capability gates.  The differential test advertises
 * Vulkan 1.1 + every extension so Mesa emits everything our generated
 * tables can decode.
 */
#ifndef VN_CS_H
#define VN_CS_H

#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

struct vn_cs_encoder {
   uint8_t *buf;
   size_t len;
   size_t cap;
};

static inline void
vn_cs_encoder_reserve(struct vn_cs_encoder *enc, size_t size)
{
   assert(enc->len + size <= enc->cap);
   (void)size;
}

static inline size_t
vn_cs_encoder_get_len(const struct vn_cs_encoder *enc)
{
   return enc->len;
}

static inline void
vn_cs_encoder_write(struct vn_cs_encoder *enc, size_t size,
                    const void *data, size_t data_size)
{
   assert(size % 4 == 0);
   assert(data_size <= size);
   vn_cs_encoder_reserve(enc, size);
   if (data && data_size)
      memcpy(enc->buf + enc->len, data, data_size);
   memset(enc->buf + enc->len + data_size, 0, size - data_size);
   enc->len += size;
}

struct vn_cs_decoder {
   bool fatal;
};

static inline void
vn_cs_decoder_set_fatal(struct vn_cs_decoder *dec)
{
   dec->fatal = true;
}

static inline void
vn_cs_decoder_read(struct vn_cs_decoder *dec, size_t size,
                   void *data, size_t data_size)
{
   (void)dec; (void)size; (void)data; (void)data_size;
   abort();
}

static inline void
vn_cs_decoder_peek(struct vn_cs_decoder *dec, size_t size,
                   void *data, size_t data_size)
{
   (void)dec; (void)size; (void)data; (void)data_size;
   abort();
}

static inline uint64_t
vn_cs_handle_load_id(const void **val, VkObjectType obj_type)
{
   (void)obj_type;
   return (uint64_t)(uintptr_t)*val;
}

static inline void
vn_cs_handle_store_id(void **val, uint64_t id, VkObjectType obj_type)
{
   (void)obj_type;
   *val = (void *)(uintptr_t)id;
}

static inline bool
vn_cs_renderer_protocol_has_extension(uint32_t ext_number)
{
   (void)ext_number;
   return true;
}

static inline bool
vn_cs_renderer_protocol_has_api_version(uint32_t version)
{
   return version <= VK_API_VERSION_1_1;
}

#endif /* VN_CS_H */
