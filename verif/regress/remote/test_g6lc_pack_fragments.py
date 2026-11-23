# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import unittest

from g6lc_pack_predicates import lower
from g6lc_pack_wrapped_columns import lower_wrapped


class MatcherGuardTest(unittest.TestCase):
    def test_no_batch_across_mutation_or_condition(self):
        header = "VlWide<32>/*1023:0*/ x; VlWide<8>/*255:0*/ y;"

        def store(plane):
            rhs = " | ".join(f"(((vlSelf->x[{i}U] >> {plane}U) & 1U) << {i}U)"
                             for i in range(32))
            return f"    vlSelf->y[{plane}U] = {rhs};\n"
        stores = [store(i) for i in range(4)]
        self.assertEqual(lower_wrapped("{\n"+"".join(stores), header)[1], 4)
        self.assertEqual(lower_wrapped("if (cond)\n"+"".join(stores), header)[1], 0)
        self.assertEqual(lower_wrapped("{\n"+"".join(stores[:2])+"    vlSelf->x[0U]++;\n"
                                       +"".join(stores[2:]), header)[1], 0)
        self.assertEqual(lower_wrapped(("{\n"+"".join(stores)).replace("->y", "->x"), header)[1], 0)

    def test_unsigned_predicate_required(self):
        header = "CData/*0:0*/ g; IData/*31:0*/ v; IData/*31:0*/ x; VlWide<2>/*63:0*/ y;"
        terms = [f"((1U & (~((IData)(vlSelf->g) & (vlSelf->x >> {i}U))"
                 f" & (vlSelf->v >> {i}U))) << {i}U)" for i in range(32)]
        store = "    vlSelf->y[0U] = " + " | ".join(terms) + ";"
        self.assertEqual(lower(store, header)[1], 1)
        self.assertEqual(lower(store.replace("(IData)(vlSelf->g)", "vlSelf->g"), header)[1], 0)
        self.assertEqual(lower(store.replace("vlSelf->x", "unknown()"), header)[1], 0)


if __name__ == "__main__":
    unittest.main()
