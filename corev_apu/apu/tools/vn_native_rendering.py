# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded rendering-object identity; no draw or attachment execution admission."""
from dataclasses import dataclass


@dataclass(frozen=True)
class RenderPass:
    context: object
    device: int
    attachments: tuple
    colors: tuple
    # subpass-0 color refs live in `colors` (the only executable profile);
    # `subpasses` retains every subpass's refs and `dependencies` the
    # validated VkSubpassDependency records for the execution follow-up.
    # `depths` retains each subpass's optional depth-stencil reference
    # `(attachment_index, layout)` or None, parallel to `subpasses`.
    subpasses: tuple = ()
    dependencies: tuple = ()
    depths: tuple = ()

    @property
    def subpass_count(self):
        return len(self.subpasses or (self.colors,))

    def subpass_colors(self, index):
        refs = self.subpasses or (self.colors,)
        if not 0 <= index < len(refs):
            raise ValueError('render pass subpass index exceeds profile')
        return refs[index]

    def subpass_depth(self, index):
        """Depth-stencil attachment ref `(index, layout)` for `index`, or
        None when the subpass declares no depth attachment.  Multi-subpass
        passes carry the per-subpass refs; single-subpass passes fall back
        to the `depths` tuple's single entry."""
        refs = self.subpasses or (self.colors,)
        if not 0 <= index < len(refs):
            raise ValueError('render pass subpass index exceeds profile')
        depths = self.depths or (None,) * len(refs)
        return depths[index] if index < len(depths) else None

    def compatible(self, other):
        if (not isinstance(other, RenderPass) or self.context is not other.context or
                self.device != other.device or len(self.colors) != len(other.colors) or
                len(self.depths or ()) != len(other.depths or ())):
            return False
        for (left, _), (right, _) in zip(self.colors, other.colors):
            if left == 0xFFFFFFFF or right == 0xFFFFFFFF:
                if left != right:
                    return False
            elif self.attachments[left][:2] != other.attachments[right][:2]:
                return False
        for left, right in zip(self.depths or (), other.depths or ()):
            if (left is None) != (right is None):
                return False
            if (left is not None and
                    self.attachments[left[0]][:2] != other.attachments[right[0]][:2]):
                return False
        return True


@dataclass(frozen=True)
class Attachment:
    view: int
    image: int
    memory: int
    view_aux: int
    image_aux: int
    image_state: int
    image_size: int
    binding: int


@dataclass(frozen=True)
class Framebuffer:
    context: object
    device: int
    render_pass: RenderPass
    attachments: tuple
    width: int
    height: int


def _fields(engine, words):
    decoder = engine.golden.Sim(engine.model, engine.assembly)
    decoded = decoder.run(words, want_trace=True)
    if decoded['fault'] or decoded['words'] != len(words):
        raise ValueError('rendering object packet is malformed')
    result = {}
    for pc, op, position in decoder.trace:
        name = engine.assembly['dec_ops'][pc][3].split(':')[0]
        if op in ('U32', 'FLAGS'):
            value = words[position]
        elif op in ('HANDLE', 'PTR', 'BLOB', 'ARRAY', 'PNEXT'):
            value = words[position] | words[position + 1] << 32
        else:
            continue
        result.setdefault(name, []).append(value)
    if (result.get('pCreateInfo') != [1] or result.get('pAllocator') != [0] or
            any(result.get('flags', ())) or any(result.get('pNext', ()))):
        raise ValueError('rendering object flags/chain/allocator exceed profile')
    return result


def capture(engine, current, name, words, record):
    if name not in ('vkCreateRenderPass', 'vkCreateFramebuffer'):
        return None
    context = engine.contexts[current.frontend.ctx]
    front, kinds = current.frontend, engine.golden.KIND
    fields = _fields(engine, words)

    def resolve(value, kind):
        status, slot, entry = front.resolve(value, kinds[kind])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('rendering object generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    def one(key):
        values = fields.get(key, ())
        if len(values) != 1:
            raise ValueError('rendering object field/count mismatch: ' + key)
        return values[0]

    device, _ = resolve(one('device'), 'VkDevice')
    if name == 'vkCreateRenderPass':
        count = one('attachmentCount')
        nsub, ndep = one('subpassCount'), one('dependencyCount')
        if (not 0 < count <= 4 or not 1 <= nsub <= 4 or ndep > 8 or
                one('pAttachments') != count or one('pSubpasses') != nsub or
                one('pDependencies') != ndep):
            raise ValueError('render pass counts/subpass/dependencies exceed profile')

        def per(key, total):
            values = fields.get(key, ())
            if len(values) != total:
                raise ValueError('render pass fields are incomplete: ' + key)
            return values

        # every per-subpass scalar/array field appears once per element;
        # input/resolve/preserve stay refused inside each subpass.  The
        # depth-stencil reference is admitted: its pointer presence is
        # `pDepthStencilAttachment` (one per subpass, 0 = NULL) and its
        # {attachment,layout} members interleave into the flat
        # `attachment`/`layout` lists right after that subpass's colour
        # references (the decoder drops the pointer hop).
        if (any(per('pipelineBindPoint', nsub)) or
                any(per('inputAttachmentCount', nsub)) or
                any(per('pInputAttachments', nsub)) or
                any(per('pResolveAttachments', nsub)) or
                any(per('preserveAttachmentCount', nsub)) or
                any(per('pPreserveAttachments', nsub))):
            raise ValueError('render pass subpass inputs/resolve/preserve exceed profile')
        depth_flags = per('pDepthStencilAttachment', nsub)
        color_counts = per('colorAttachmentCount', nsub)
        if (any(c > 4 for c in color_counts) or
                list(per('pColorAttachments', nsub)) != list(color_counts)):
            raise ValueError('render pass color attachment counts exceed profile')
        att_list = list(fields.get('attachment', ()))
        lay_list = list(fields.get('layout', ()))
        total_refs = (sum(color_counts) +
                      sum(1 for d in depth_flags if d))
        if len(att_list) != len(lay_list) or len(att_list) != total_refs:
            raise ValueError('render pass attachment references are incomplete')
        subpasses, depths, pos = [], [], 0
        for i, c in enumerate(color_counts):
            refs = tuple(zip(att_list[pos:pos + c], lay_list[pos:pos + c]))
            pos += c
            used = [index for index, _ in refs if index != 0xFFFFFFFF]
            if (len(set(used)) != len(used) or any(index >= count for index in used) or
                    any(layout not in (1, 2) for index, layout in refs
                        if index != 0xFFFFFFFF)):
                raise ValueError('render pass color references exceed profile')
            subpasses.append(refs)
            if depth_flags[i]:
                dref = (att_list[pos], lay_list[pos])
                pos += 1
                # a present depth reference must name a real attachment and
                # an in-use attachment layout (GENERAL..SHADER_READ_ONLY)
                if not 0 <= dref[0] < count or dref[1] not in (1, 2, 3, 4, 5):
                    raise ValueError('render pass depth reference exceeds profile')
                depths.append(dref)
            else:
                depths.append(None)
        dependencies = ()
        if ndep:
            dep_names = ('srcSubpass', 'dstSubpass', 'srcStageMask', 'dstStageMask',
                         'srcAccessMask', 'dstAccessMask', 'dependencyFlags')
            columns = [per(key, ndep) for key in dep_names]
            # stage/access bounds mirror vn_image_barriers.scope()'s
            # graphics profile; BY_REGION (bit0) is the only legal flag
            stages_bound, accesses_bound = 0x17001 | 0x78E, 0x1F98F
            external = 0xFFFFFFFF
            dependencies = tuple(zip(*columns))
            for s, d, ss, ds, sa, da, fl in dependencies:
                if ((s != external and s >= nsub) or
                        (d != external and d >= nsub) or
                        (s == external and d == external) or fl & ~1 or
                        ss & ~stages_bound or ds & ~stages_bound or
                        sa & ~accesses_bound or da & ~accesses_bound):
                    raise ValueError('render pass dependency exceeds profile')
        names = ('format', 'samples', 'loadOp', 'storeOp', 'stencilLoadOp',
                 'stencilStoreOp', 'initialLayout', 'finalLayout')
        if any(len(fields.get(key, ())) != count for key in names):
            raise ValueError('render pass attachment fields are incomplete')
        # an attachment referenced as a subpass depth-stencil target must
        # carry a bounded depth format: device fmt 12 = D32_SFLOAT (the
        # float32 depth path) or fmt 14 = D24S8 (the packed depth-stencil
        # path, {stencil[31:24], depth_unorm24[23:0]}); every other
        # attachment keeps the colour-format bound.  Bounded profile: an
        # attachment may not serve as both a colour and a depth target.
        depth_idx = {d[0] for d in depths if d is not None}
        color_idx = {index for refs in subpasses for index, _ in refs
                     if index != 0xFFFFFFFF}
        if depth_idx & color_idx:
            raise ValueError('render pass attachment is both colour and depth')
        attachments = tuple(zip(*(fields[key] for key in names)))
        for i, (fmt, samples, load, store, sload, sstore, initial, final) in enumerate(attachments):
            dev_fmt = engine.golden.img_fmt_id(engine.model, fmt)
            fmt_ok = (dev_fmt in (12, 14)) if i in depth_idx else dev_fmt in (2, 3, 4, 5)
            if (not fmt_ok or samples != 1 or
                    load not in (0, 1, 2) or store not in (0, 1) or
                    sload not in (0, 1, 2) or sstore not in (0, 1) or
                    initial not in (0, 1, 2, 5, 6, 7, 8) or final not in (1, 2, 5, 6, 7)):
                raise ValueError('render pass attachment format/ops/layout exceed profile')
        return RenderPass(context, device, attachments, subpasses[0],
                          tuple(subpasses), dependencies, tuple(depths))
    _, entry = resolve(one('renderPass'), 'VkRenderPass')
    render_pass = entry.get('native_rendering')
    if (not isinstance(render_pass, RenderPass) or render_pass.context is not context or
            render_pass.device != device):
        raise ValueError('framebuffer has no same-device render pass identity')
    count, width, height = one('attachmentCount'), one('width'), one('height')
    if (count != len(render_pass.attachments) or one('pAttachments') != count or
            not 0 < width <= 4096 or not 0 < height <= 4096 or one('layers') != 1 or
            len(record['pay']) != 6 + 2 * count):
        raise ValueError('framebuffer attachment count/dimensions exceed profile')
    # attachment indices named as a subpass depth-stencil target back a
    # DEPTH_STENCIL_ATTACHMENT-usage image; every other slot stays a
    # colour-attachment image (aux usage bits 22+ -> aux>>54)
    depth_idx = {d[0] for d in (render_pass.depths or ()) if d is not None}
    attachments = []
    for i in range(count):
        position = 3 + i * 2
        raw = record['pay'][position] | record['pay'][position + 1] << 32
        view, ve = resolve(raw, 'VkImageView')
        image, ie = resolve(ve.get('native_view_image', 0), 'VkImage')
        slot = ie.get('bind_mem', -1)
        if not 0 <= slot < front.SLOTS:
            raise KeyError('framebuffer image has no live memory binding')
        memory, me = resolve(ie.get('bind_mgen', 0) << 16 | slot, 'VkDeviceMemory')
        aux, va = ie['aux'], ve['aux']
        mip, layer = va >> 28 & 15, va >> 36 & 1023
        need_usage = 32 if i in depth_idx else 16
        if (any(value['parent'] != device & 0xFFFF for value in (ve, ie, me)) or
                ie['state'] >> 19 & 3 != 1 or va & 0xFFFF != image & 0xFFFF or
                va >> 56 & 7 or va >> 16 & 0xFFF or
                va >> 32 & 15 != 1 or va >> 46 & 1023 != 1 or
                mip >= aux >> 40 & 31 or layer >= aux >> 45 & 511 or
                not aux >> 54 & need_usage or
                aux >> 32 & 255 != engine.golden.img_fmt_id(
                    engine.model, render_pass.attachments[i][0]) or
                width > max(1, (aux & 0xFFFF) >> mip) or
                height > max(1, (aux >> 16 & 0xFFFF) >> mip) or
                ie.get('bind_off', 0) + ie['size'] > me['size']):
            raise ValueError('framebuffer view/image/device/range exceeds profile')
        attachments.append(Attachment(view, image, memory, va, aux, ie['state'],
                                      ie['size'], ie.get('bind_off', 0)))
    return Framebuffer(context, device, render_pass, tuple(attachments), width, height)


def attach(front, name, record, out, snapshot):
    if snapshot is None or out['fault'] or out['result']:
        return
    index = next(i for i in range(8) if record['qv'] >> i & 1 and record['role'][i] == 1)
    status, _, entry = front.resolve(record['q'][index], record['kind'][index])
    if status != 'OK':
        raise KeyError('created rendering object is unavailable')
    entry['native_rendering'] = snapshot


@dataclass(frozen=True)
class ColorAttachment:
    owner: object
    offset: int
    size: int
    pitch: int
    fmt: int


@dataclass(frozen=True)
class FramebufferOperand:
    framebuffer: Framebuffer
    attachments: tuple
    references: tuple
    validate: object


def framebuffer_operand(engine, context_id, handle):
    context = engine.contexts[context_id]
    front, kinds = context.frontend, engine.golden.KIND
    references, entries = [], []

    def resolve(value, kind):
        status, slot, entry = front.resolve(value, kinds[kind])
        if status != 'OK' or entry['ctx'] != context_id:
            raise KeyError('framebuffer operand generation/context is stale')
        references.append((entry['gen'] << 16 | slot, kinds[kind]))
        return entry

    entry = resolve(handle, 'VkFramebuffer')
    snapshot = entry.get('native_rendering')
    if (not isinstance(snapshot, Framebuffer) or snapshot.context is not context or
            not engine.transfers._live(context)):
        raise ValueError('framebuffer has no live native identity')
    resolve(snapshot.device, 'VkDevice')
    colors = []
    for source in snapshot.attachments:
        ve, ie, me = (resolve(value, kind) for value, kind in (
            (source.view, 'VkImageView'), (source.image, 'VkImage'),
            (source.memory, 'VkDeviceMemory')))
        entries.append((source, ve, ie, me))
        aux, va = source.image_aux, source.view_aux
        width, height, fmt = aux & 0xFFFF, aux >> 16 & 0xFFFF, aux >> 32 & 255
        mips, layers = aux >> 40 & 31, aux >> 45 & 511
        mip, layer = va >> 28 & 15, va >> 36 & 1023
        stride = engine.golden.img_layer_bytes(engine.model, width, height, fmt, mips)
        offset = source.binding + layer * stride + sum(
            engine.golden.img_mpitch(engine.model, width, fmt, level) *
            max(1, height >> level) for level in range(mip))
        pitch = engine.golden.img_mpitch(engine.model, width, fmt, mip)
        size = pitch * snapshot.height
        if (source.image_size != stride * layers or
                source.image_state & 0x7FFFF != stride >> 6 or
                source.binding + source.image_size > me['size']):
            raise ValueError('framebuffer image footprint is inconsistent')
        owner = engine.memory(context_id, source.memory)
        engine.transfers._extent(context, owner, offset, size)
        colors.append(ColorAttachment(owner, offset, size, pitch, fmt))

    def validate():
        if (not engine.transfers._live(context) or entry.get('native_rendering') is not snapshot or
                entry['parent'] != snapshot.device & 0xFFFF):
            raise KeyError('framebuffer identity changed during admission')
        for value, kind in references:
            if front.resolve(value, kind)[0] != 'OK':
                raise KeyError('framebuffer operand retired during admission')
        for source, ve, ie, me in entries:
            if (any(e['parent'] != snapshot.device & 0xFFFF for e in (ve, ie, me)) or
                    ve.get('native_view_image') != source.image or ve['aux'] != source.view_aux or
                    ie['aux'] != source.image_aux or ie['state'] != source.image_state or
                    ie['size'] != source.image_size or ie.get('bind_off') != source.binding or
                    ie.get('bind_mem') != source.memory & 0xFFFF or
                    ie.get('bind_mgen') != source.memory >> 16):
                raise KeyError('framebuffer attachment provenance changed')
        if any(color.owner.deferred_free is not None for color in colors):
            raise KeyError('framebuffer backing is pending free')

    validate()
    return FramebufferOperand(snapshot, tuple(colors), tuple(references), validate)
