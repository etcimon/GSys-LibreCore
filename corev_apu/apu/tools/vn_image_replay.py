#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded raw color-image copies using the pinned 64-byte row-pitch ABI."""
from vn_transfer_executor import Transfer


class ImageReplay:
    NAMES = frozenset(('vkCmdCopyBufferToImage', 'vkCmdCopyImageToBuffer', 'vkCmdCopyImage',
                       'vkCmdClearColorImage'))

    def __init__(self, engine, remember, payload, extent, operations):
        self.engine, self.remember, self.payload = engine, remember, payload
        self.extent, self.operations = extent, operations
        # (entry-id, query) pairs with an active occlusion begin, tracked
        # across primary/secondary records for the whole submit batch
        self.qopen = set()
        # non-None while a conditional-rendering region is open
        self.cond = None

    def _remaining(self):
        return self.engine.transfers.max_operations - len(self.operations)

    def _image(self, record, index):
        golden = self.engine.golden
        _, entry = self.remember(record['handle'][index], golden.KIND['VkImage'])
        owner, binding, size = self.extent(record, index, 'VkImage')
        aux, state = entry['aux'], entry['state']
        w, h, fmt = aux & 0xFFFF, aux >> 16 & 0xFFFF, aux >> 32 & 255
        mips, layers, itype = aux >> 40 & 31, aux >> 45 & 511, state >> 19 & 3
        names, _, bpp, _ = self.engine.model.img_fmt_tables()
        if (fmt >= len(names) or names[fmt].startswith(('D', 'S8', 'X8_D')) or
                not bpp[fmt] or itype not in (0, 1) or
                not 0 < w <= 4096 or not 0 < h <= 4096 or
                itype == 0 and h != 1 or not 0 < mips <= 13 or not 0 < layers <= 256):
            raise ValueError('image type/format/dimensions exceed raw color-copy profile')
        layer_bytes = golden.img_layer_bytes(self.engine.model, w, h, fmt, mips)
        if layer_bytes != (state & 0x7FFFF) << 6 or size != layer_bytes * layers:
            raise ValueError('image layout descriptor is stale or inconsistent')
        return dict(owner=owner, binding=binding, size=size, w=w, h=h, fmt=fmt,
                    bpp=bpp[fmt], mips=mips, layers=layers, layer_bytes=layer_bytes,
                    layout=entry.get('layout', 0))

    def _rows(self, image, subresource, offset, extent):
        aspect, mip, base, layers = subresource
        x, y, z = offset
        width, height, depth = extent
        if (aspect != 1 or not 0 <= mip < image['mips'] or
                not 0 < layers <= image['layers'] or base + layers > image['layers'] or
                z or depth != 1 or not width or not height or
                x + width > max(1, image['w'] >> mip) or
                y + height > max(1, image['h'] >> mip)):
            raise ValueError('image copy subresource/rectangle exceeds bounds')
        if layers * height > self._remaining():
            raise MemoryError('image row-operation budget exhausted')
        golden, model = self.engine.golden, self.engine.model
        mip_offset = sum(golden.img_mpitch(model, image['w'], image['fmt'], m) *
                         max(1, image['h'] >> m) for m in range(mip))
        pitch = golden.img_mpitch(model, image['w'], image['fmt'], mip)
        return [image['binding'] + layer * image['layer_bytes'] + mip_offset +
                (y + row) * pitch + x * image['bpp']
                for layer in range(base, base + layers) for row in range(height)]

    def _copy(self, source, starts, destination, targets, size, spans):
        if len(starts) != len(targets) or len(starts) > self._remaining():
            raise MemoryError('image row-operation budget exhausted')
        for start, target in zip(starts, targets):
            spans.append((source.base + start, destination.base + target, size))
            self.operations.append(Transfer('copy', destination, target, size, source, start))

    def replay(self, name, record):
        if name == 'vkCmdClearColorImage':
            self._clear(record)
            return
        image_copy = name == 'vkCmdCopyImage'
        count = record['imm'][2 if image_copy else 1]
        if not 0 < count <= self._remaining():
            raise MemoryError('image region budget exhausted')
        data = self.payload(record, count * (17 if image_copy else 14))
        spans = []
        if image_copy:
            if record['imm'][0] not in (1, 6) or record['imm'][1] not in (1, 7):
                raise ValueError('image copy layout is not a transfer/general layout')
            source, destination = self._image(record, 0), self._image(record, 1)
            if (source['layout'] != record['imm'][0] or
                    destination['layout'] != record['imm'][1]):
                raise ValueError('image copy layout does not match current image layout')
            if source['fmt'] != destination['fmt']:
                raise ValueError('cross-format image copies exceed native profile')
            for i in range(count):
                region = data[17 * i:17 * (i + 1)]
                extent = region[14:17]
                starts = self._rows(source, region[:4], region[4:7], extent)
                targets = self._rows(destination, region[7:11], region[11:14], extent)
                self._copy(source['owner'], starts, destination['owner'], targets,
                           extent[0] * source['bpp'], spans)
        else:
            to_image = name == 'vkCmdCopyBufferToImage'
            if record['imm'][0] not in ((1, 7) if to_image else (1, 6)):
                raise ValueError('buffer/image layout is not a transfer/general layout')
            image = self._image(record, int(to_image))
            if image['layout'] != record['imm'][0]:
                raise ValueError('buffer/image layout does not match current image layout')
            buffer, binding, capacity = self.extent(record, int(not to_image))
            for i in range(count):
                r = data[14 * i:14 * (i + 1)]
                offset, row_length, image_height = r[0] | r[1] << 32, r[2], r[3]
                width, height, depth = r[11:14]
                rows = self._rows(image, r[4:8], r[8:11], (width, height, depth))
                row_length = row_length or width
                image_height = image_height or height
                size = width * image['bpp']
                end = offset + (((r[7] - 1) * image_height + height - 1) *
                                row_length + width) * image['bpp']
                if (offset % image['bpp'] or row_length < width or image_height < height or
                        end > capacity):
                    raise ValueError('buffer/image strides or logical buffer bounds are invalid')
                buffer_rows = [binding + offset + (layer * image_height + row) *
                               row_length * image['bpp']
                               for layer in range(r[7]) for row in range(height)]
                if to_image:
                    self._copy(buffer, buffer_rows, image['owner'], rows, size, spans)
                else:
                    self._copy(image['owner'], rows, buffer, buffer_rows, size, spans)
        if any(s < d + dn and d < s + sn for s, _, sn in spans for _, d, dn in spans):
            raise ValueError('image copy source/destination regions overlap')

    def _clear(self, record):
        count = record['imm'][1]
        if record['imm'][0] not in (1, 7) or not 0 < count <= self._remaining():
            raise ValueError('clear image layout/range count exceeds native profile')
        data = self.payload(record, 4 + count * 5)
        image, seen = self._image(record, 0), set()
        if image['layout'] != record['imm'][0]:
            raise ValueError('clear image layout does not match current image layout')
        texel = self.engine.golden.img_clear_texel(self.engine.model, image['fmt'], data[:4])
        for i in range(count):
            aspect, mip, levels, layer, layers = data[4 + i * 5:9 + i * 5]
            levels = image['mips'] - mip if levels == 0xFFFFFFFF else levels
            layers = image['layers'] - layer if layers == 0xFFFFFFFF else layers
            if (aspect != 1 or not 0 < levels <= image['mips'] or
                    mip + levels > image['mips'] or not 0 < layers <= image['layers'] or
                    layer + layers > image['layers']):
                raise ValueError('clear image subresource range exceeds image')
            for level in range(mip, mip + levels):
                for index in range(layer, layer + layers):
                    if (level, index) in seen:
                        raise ValueError('overlapping clear image subresource ranges')
                    seen.add((level, index))
                width, height = max(1, image['w'] >> level), max(1, image['h'] >> level)
                rows = self._rows(image, (aspect, level, layer, layers),
                                  (0, 0, 0), (width, height, 1))
                for row in rows:
                    self.operations.append(Transfer('pattern', image['owner'], row,
                                                    width * image['bpp'], data=texel))
