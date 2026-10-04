/* Copyright 2026 Etienne Cimon */
/* SPDX-License-Identifier: MIT */
/*
 * vn_ring.h stub for the vn_mesa_diff harness.  The generated
 * vn_protocol_driver_transport.h defines vn_submit_* inline wrappers
 * that reference these; the harness only calls vn_encode_vk* directly,
 * so prototypes suffice (the functions are never emitted).
 */
#ifndef VN_RING_H
#define VN_RING_H

#include <stddef.h>
#include <stdint.h>

struct vn_ring;
struct vn_cs_encoder;
struct vn_cs_decoder;

/* complete type: the generated transport layer stack-allocates it */
struct vn_ring_submit_command {
   struct vn_cs_encoder *enc;
   struct vn_cs_decoder *dec;
};

struct vn_cs_encoder *vn_ring_submit_command_init(
   struct vn_ring *vn_ring, struct vn_ring_submit_command *submit,
   void *cmd_data, size_t cmd_size, size_t reply_size);
void vn_ring_submit_command(struct vn_ring *vn_ring,
                            struct vn_ring_submit_command *submit);
struct vn_cs_decoder *vn_ring_get_command_reply(
   struct vn_ring *vn_ring, struct vn_ring_submit_command *submit);
void vn_ring_free_command_reply(struct vn_ring *vn_ring,
                                struct vn_ring_submit_command *submit);

#endif /* VN_RING_H */
