# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Native image descriptor provenance; resolution does not publish shader work."""
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class ImageSource:
    dtype: int
    view: int = 0
    image: int = 0
    memory: int = 0
    sampler: int = 0
    view_aux: int = 0
    image_aux: int = 0
    image_state: int = 0
    image_size: int = 0
    binding: int = 0
    sampler_aux: int = 0
    layout: int = 0


def immutable_source(source, sampler):
    if isinstance(source, ImageSource) and source.dtype in (0, 1):
        return replace(source, sampler=0, sampler_aux=sampler)
    return source


def capture_source(front, kinds, dtype, view, sampler, layout, immutable=None):
    def resolve(value, name):
        status, slot, entry = front.resolve(value, kinds[name])
        if status != 'OK' or entry['ctx'] != front.ctx:
            raise KeyError('image descriptor generation/context is stale')
        return entry['gen'] << 16 | slot, entry

    try:
        sampler_aux, sampler_handle, sampler_entry = 0, 0, None
        if dtype in (0, 1):
            if immutable is None:
                sampler_handle, sampler_entry = resolve(sampler, 'VkSampler')
                sampler_aux = sampler_entry['aux']
            else:
                sampler_aux = immutable
        if dtype == 0:
            return ImageSource(dtype, sampler=sampler_handle, sampler_aux=sampler_aux)
        view_handle, ve = resolve(view, 'VkImageView')
        image_handle, ie = resolve(ve.get('native_view_image', 0), 'VkImage')
        slot = ie.get('bind_mem', -1)
        if not 0 <= slot < front.SLOTS:
            raise KeyError('unbound image descriptor')
        memory_handle, me = resolve(ie.get('bind_mgen', 0) << 16 | slot, 'VkDeviceMemory')
        if (ve['aux'] & 0xFFFF != image_handle & 0xFFFF or
                any(entry['parent'] != ve['parent'] for entry in
                    (ie, me, *(() if sampler_entry is None else (sampler_entry,)))) or
                ie.get('bind_off', 0) + ie['size'] > me['size']):
            raise ValueError('image descriptor owner/device/range mismatch')
        return ImageSource(dtype, view_handle, image_handle, memory_handle, sampler_handle,
            ve['aux'], ie['aux'], ie['state'], ie['size'], ie.get('bind_off', 0),
            sampler_aux, layout)
    except (ValueError, KeyError):
        return None


@dataclass(frozen=True)
class ImageBinding:
    owner: object
    offset: int
    size: int
    width: int
    height: int
    pitch: int
    fmt: int
    swizzle: int
    kind: int
    sampler: tuple
    binding: int
    descriptor_set: int
    element: int


@dataclass(frozen=True)
class ImageOperand:
    binding: ImageBinding
    references: tuple
    validate: object


def image_descriptor(engine, context_id, descriptor_set, binding, element=0, set_index=0):
    context = engine.contexts[context_id]
    if not engine.transfers._live(context):
        raise KeyError('image descriptor context is unavailable')
    front, kinds = context.frontend, engine.golden.KIND
    references, entries = [], []

    def resolve(value, name):
        status, slot, entry = front.resolve(value, kinds[name])
        if status != 'OK' or entry['ctx'] != context_id:
            raise KeyError('image operand generation/context is stale')
        references.append((entry['gen'] << 16 | slot, kinds[name]))
        entries.append(entry)
        return entry

    descriptor = resolve(descriptor_set, 'VkDescriptorSet')
    dead, layout = front.dset_dead(descriptor)
    if dead or descriptor['aux'] & (1 << 31) or layout is None:
        raise KeyError('image descriptor set/pool is poisoned or stale')
    pool = resolve(descriptor['size'] & 0xFFFFFFFF, 'VkDescriptorPool')
    if (layout.get('native_handle') != descriptor['aux'] >> 32 or
            type(binding) is not int or not 0 <= binding < 256 or
            type(element) is not int or not 0 <= element < 16 or
            type(set_index) is not int or not 0 <= set_index < 4):
        raise ValueError('image descriptor identity/index exceeds native profile')
    row = front.lay_row(layout, binding)
    if row is None or row['type'] not in (0, 1, 2, 3) or element >= row['count']:
        raise ValueError('image descriptor row/element exceeds native profile')
    address = ((descriptor['aux'] & 0x1FFFFFF) << 2) + (row['off'] + element) * 32
    source = front.descriptor_sources.get(address)
    if not isinstance(source, ImageSource) or source.dtype != row['type']:
        raise KeyError('image descriptor has no typed native provenance')
    parent = pool['parent']
    device = front.ent[parent] if 0 <= parent < front.SLOTS else None
    if (device is None or layout['parent'] != parent or
            descriptor['parent'] != descriptor['size'] & 0xFFFF):
        raise ValueError('image descriptor pool/layout/device mismatch')
    resolve(device['gen'] << 16 | parent, 'VkDevice')
    if source.sampler:
        sampler = resolve(source.sampler, 'VkSampler')
        if sampler['aux'] != source.sampler_aux:
            raise KeyError('image descriptor sampler state changed')
    if row['immutable']:
        signature = next(item for item in layout['native_signature'][1] if item[0] == binding)
        if source.sampler or source.sampler_aux != signature[4][element]:
            raise ValueError('image descriptor immutable sampler differs from layout')
    owner = None
    offset = size = width = height = pitch = fmt = swizzle = 0
    expected = [0, 0, 0x100 | source.dtype, 0, 0,
                source.sampler_aux & 0xFFFFFFFF, source.sampler_aux >> 32, 0]
    if source.dtype:
        view = resolve(source.view, 'VkImageView')
        image = resolve(source.image, 'VkImage')
        memory = resolve(source.memory, 'VkDeviceMemory')
        aux, va = source.image_aux, source.view_aux
        base_w, base_h, fmt = aux & 0xFFFF, aux >> 16 & 0xFFFF, aux >> 32 & 255
        mips, layers = aux >> 40 & 31, aux >> 45 & 511
        mip, levels, layer, count = va >> 28 & 15, va >> 32 & 15, va >> 36 & 1023, va >> 46 & 1023
        names, _, bpp, _ = engine.model.img_fmt_tables()
        if (source.image_state >> 19 & 3 != 1 or va >> 56 & 7 != 0 or levels != 1 or count != 1 or
                not 0 < base_w <= 4096 or not 0 < base_h <= 4096 or
                not 0 < mips <= 13 or mip >= mips or not 0 < layers <= 256 or layer >= layers or
                fmt >= len(names) or names[fmt].startswith(('D', 'S8', 'X8_D')) or
                bpp[fmt] not in (1, 2, 4, 8, 16) or
                not (aux >> 54) & (8 if source.dtype == 3 else 4) or
                source.layout not in ((1,) if source.dtype == 3 else (1, 5))):
            raise ValueError('image descriptor type/format/view/layout exceeds native profile')
        layer_bytes = engine.golden.img_layer_bytes(engine.model, base_w, base_h, fmt, mips)
        mip_offset = sum(engine.golden.img_mpitch(engine.model, base_w, fmt, level) *
                         max(1, base_h >> level) for level in range(mip))
        width, height = max(1, base_w >> mip), max(1, base_h >> mip)
        pitch = engine.golden.img_mpitch(engine.model, base_w, fmt, mip)
        offset, size = source.binding + layer * layer_bytes + mip_offset, pitch * height
        swizzle = va >> 16 & 0xFFF
        if (source.image_size != layer_bytes * layers or
                source.image_state & 0x7FFFF != layer_bytes >> 6 or
                source.binding + source.image_size > memory['size']):
            raise ValueError('image descriptor footprint is inconsistent')
        owner = engine.memory(context_id, source.memory)
        engine.transfers._extent(context, owner, offset, size)
        expected = [source.memory, layer_bytes - mip_offset, width << 16 | 0x100 | source.dtype,
                    levels << 24 | fmt << 16 | height, swizzle << 16 | count,
                    source.sampler_aux & 0xFFFFFFFF, source.sampler_aux >> 32, offset]
    if any(entry['parent'] != parent for entry in entries[1:] if entry is not device):
        raise ValueError('image operand crosses devices')

    def validate():
        if (not engine.transfers._live(context) or front.descriptor_sources.get(address) is not source or
                front.dset_dead(descriptor)[0] or descriptor['aux'] & (1 << 31) or
                owner is not None and owner.deferred_free is not None):
            raise KeyError('image descriptor changed during admission')
        for handle, kind in references:
            if front.resolve(handle, kind)[0] != 'OK':
                raise KeyError('image operand retired during admission')
        if source.sampler and sampler['aux'] != source.sampler_aux:
            raise KeyError('image sampler changed during admission')
        if source.dtype and (view.get('native_view_image') != source.image or
                view['aux'] != source.view_aux or image['aux'] != source.image_aux or
                image['state'] != source.image_state or image['size'] != source.image_size or
                image.get('bind_mem') != source.memory & 0xFFFF or
                image.get('bind_mgen') != source.memory >> 16 or
                image.get('bind_off') != source.binding):
            raise KeyError('image/view/memory provenance changed during admission')

    validate()
    words = [front.apr64(address + index * 8) for index in range(4)]
    actual = [word >> shift & 0xFFFFFFFF for word in words for shift in (0, 32)]
    if actual != expected:
        raise ValueError('image descriptor bytes differ from native provenance')
    validate()
    return ImageOperand(ImageBinding(owner, offset, size, width, height, pitch, fmt, swizzle,
        source.dtype, (source.sampler_aux & 0xFFFFFFFF, source.sampler_aux >> 32),
        binding, set_index, element), tuple(references), validate)
