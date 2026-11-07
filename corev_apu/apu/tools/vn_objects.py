#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Object-table state extracted from the Venus golden front, without encoding."""


class ObjectTable:
    """Generation handles, directory and lifetime bookkeeping in RTL order."""

    SLOTS = 256

    def __init__(self, slots=256):
        self.SLOTS = slots
        self.reset_objects()

    def reset_objects(self):
        self.ent = [None] * self.SLOTS
        self.gens = [0] * self.SLOTS
        self.idmap = {}
        self.live_cnt = 0
        self.ctx = 0
        self.freestk = []
        self.bump = 0
        self.ctxorder = {}

    def resolve(self, idv, kind, allow_zomb=False):
        """Resolve a tagged client id or generation handle; gate zombies."""
        if idv == 0:
            return 'MISS', -1, None
        if idv < (1 << 32) and ((idv >> 16) & 0xFFFF) != 0:
            slot, gen = idv & 0xFFFF, (idv >> 16) & 0xFFFF
            if slot >= self.SLOTS:
                return 'GEN', -1, None
            e = self.ent[slot]
            if e is None or e['gen'] != gen:
                return 'GEN', -1, None
            if e.get('zomb') and not allow_zomb:
                return 'GEN', -1, None
            if kind and e['kind'] != kind:
                return 'KIND', slot, e
            return 'OK', slot, e
        s = self.idmap.get(idv)
        if s is None:
            return 'MISS', -1, None
        e = self.ent[s]
        if e is None:
            return 'MISS', -1, None
        if e.get('zomb') and not allow_zomb:
            return 'MISS', -1, None
        if kind and e['kind'] != kind:
            return 'KIND', s, e
        return 'OK', s, e

    def alloc(self, idv, kind, parent_h):
        if idv in self.idmap and self.ent[self.idmap[idv]] is not None:
            return 'DUP', 0, -1
        if self.freestk:
            slot = self.freestk.pop()
        elif self.bump < self.SLOTS:
            slot = self.bump
            self.bump += 1
        else:
            return 'FULL', 0, -1
        par = -1
        if parent_h:
            st, ps, _pe = self.resolve(parent_h, 0)
            if st != 'OK':
                return 'PARENT_MISS', 0, -1
            par = ps
        g = self.gens[slot] + 1
        if g > 0xFFFF:
            g = 1
        self.gens[slot] = g
        self.ent[slot] = {'id': idv, 'kind': kind, 'gen': g,
                          'parent': par, 'refcnt': 0, 'pins': 0,
                          'zomb': 0,
                          'state': 0, 'aux': 0, 'ctx': self.ctx,
                          'size': 0, 'bind_mem': -1, 'bind_mgen': 0,
                          'bind_off': 0}
        self.idmap[idv] = slot
        self.live_cnt += 1
        self.ctxorder.setdefault(self.ctx, []).append(slot)
        if par >= 0:
            self.ent[par]['refcnt'] += 1
        return 'OK', (g << 16) | slot, slot

    def _free_slot(self, s, e):
        self.ent[s] = None
        self.idmap.pop(e['id'], None)
        self.live_cnt -= 1
        cl = self.ctxorder.get(e['ctx'])
        if cl is not None and s in cl:
            cl.remove(s)
        self.freestk.append(s)

    def retire(self, idv, kind):
        st, s, e = self.resolve(idv, kind)
        if st != 'OK':
            return st, s
        if e['pins']:
            return 'PINNED', s
        if e['refcnt']:
            return 'BUSY_CHILDREN', s
        if e['parent'] >= 0 and self.ent[e['parent']] is not None:
            self.ent[e['parent']]['refcnt'] -= 1
        self._free_slot(s, e)
        return 'OK', s

    def retire_kids(self, h, kind):
        """RETIRE_KIDS walks newest first, using the parent slot directly."""
        s = h & 0xFFFF
        if s >= self.SLOTS:
            return 'MISS', 0
        pe = self.ent[s]
        ctxn = pe['ctx'] if pe is not None else self.ctx
        n = 0
        for i in list(self.ctxorder.get(ctxn, []))[::-1]:
            c = self.ent[i]
            if c is not None and c['parent'] == s:
                self._free_slot(i, c)
                n += 1
        for i, c in enumerate(self.ent):
            if c is not None and c['parent'] == s:
                self._free_slot(i, c)
                n += 1
        e = self.ent[s]
        if e is not None:
            e['refcnt'] = 0
        return 'OK', n

    def setstate(self, h, mask, value):
        st, s, e = self.resolve(h, 0)
        if st != 'OK':
            return st, s
        e['state'] = (e['state'] & ~mask) | (value & mask)
        return 'OK', s

    def setaux(self, h, mask, value):
        st, s, e = self.resolve(h, 0)
        if st != 'OK':
            return st, s
        e['aux'] = (e['aux'] & ~mask) | (value & mask)
        return 'OK', s

    def setauxhi(self, h, value32):
        """aux[63:32] = {base_chunk[15:0], words[15:0]}."""
        st, s, e = self.resolve(h, 0)
        if st != 'OK':
            return st, s
        e['aux'] = (e['aux'] & 0xFFFFFFFF) | \
            ((value32 & 0xFFFFFFFF) << 32)
        return 'OK', s
