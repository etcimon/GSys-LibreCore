# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import unittest

from g6lc_sentinel_index import index, scenario, schedule_input
from g6lc_sentinel_dataflow import dataflow_index


class SentinelTest(unittest.TestCase):
    def setUp(self):
        # Task 4 waits for 2; half its wait is for preceding work, not 2.
        self.rows = {1: (0, 0, 8), 2: (8, 8, 12), 3: (0, 0, 4), 4: (4, 12, 18)}
        self.schedule = dict(seq={"0": [1, 2], "1": [3, 4]},
                             pred={"1": [], "2": [], "3": [], "4": [2]})

    def test_blocker_and_reorder_gate(self):
        captures = [{1: self.rows}, {2: self.rows}]
        result = index(self.schedule, captures)
        self.assertEqual(result["blockers"], [dict(producers=(2,), consumer=4,
                                                   count=2, body_ns=8, prefix_ns=8)])
        self.assertIn("blocked", result["reorder"]["status"])
        self.schedule["full_pred"] = self.schedule["pred"].copy()
        prediction = index(self.schedule, captures)["reorder"]
        self.assertEqual(prediction["swap"], [1, 2])
        self.assertAlmostEqual(prediction["holdout_gain_pct"], 100 / 3)
        self.schedule["full_pred"]["2"] = [1]
        self.assertNotIn("swap", index(self.schedule, captures)["reorder"])

    def test_hidden_dependency_must_be_ordered(self):
        raw = dict(schema="v3-sentinel-1", tasks=[
            dict(id=1, lane=0, waits=[], deps=[]), dict(id=2, lane=1, waits=[], deps=[1])])
        with self.assertRaisesRegex(ValueError, "uncovered"):
            schedule_input(raw)
        raw["tasks"][1]["lane"] = 0
        self.assertEqual(schedule_input(raw)["full_pred"]["2"], [1])

    def test_incomplete_round(self):
        del self.rows[1]
        with self.assertRaisesRegex(ValueError, "incomplete"):
            index(self.schedule, [{1: self.rows}])

    def test_joint_scenario_keeps_wait_and_lane_overlap(self):
        # Shortening both lanes is not additive. Task 3 already fits
        # beneath 1+2, and halving it doesn't advance the join.
        result = scenario(self.schedule, {1: self.rows}, {1: 0.5, 3: 0.5})
        self.assertEqual(result["measured_span_ns"], 18)
        self.assertEqual(result["projected_span_ns"], 14)
        with self.assertRaises(ValueError):
            scenario(self.schedule, {1: self.rows}, {5: 0.5})

    def test_descending_select_is_not_pext(self):
        def node(i, op, bits, inputs, **extra):
            return dict(id=i, op=op, bits=bits, inputs=inputs, file="leaf.sv", line=3, **extra)

        # The operand numbers, not file order, determine the projection.
        raw = dict(module="leaf", phase="pre", vertices=[
            node(0, "VARPACKED", 16, [], name="row", keep=True,
                 module_refs=True, external_refs=False),
            node(1, "SEL", 1, [[0, 0]], lsb=3), node(2, "SEL", 1, [[0, 0]], lsb=11),
            node(3, "CONCAT", 2, [[1, 2], [0, 1]])])
        result = dataflow_index(raw)
        self.assertEqual(result["regions"][0]["bit_indices"], [11, 3])
        self.assertEqual(result["regions"][0]["probe_candidates"], [])
        self.assertEqual(result["storage"][0]["consumers"], 2)
        self.assertTrue(result["storage"][0]["keep"])

    def test_transpose_proof_rejects_wrong_bit_and_extra_reader(self):
        graph = dict(module="t", phase="pre", vertices=[])
        nodes = graph["vertices"]

        def add(op, bits, sources=(), **extra):
            i = len(nodes)
            nodes.append(dict(id=i, op=op, bits=bits, inputs=list(enumerate(sources)),
                              file="t.sv", line=1, **extra))
            return i

        def var(bits, name):
            return add("VARPACKED", bits, name=name, keep=False, module_refs=False,
                       external_refs=False)

        source, tmp, mask = var(64, "rows"), var(64, "cols"), var(8, "mask")
        for col in range(8):
            v = add("SEL", 1, [source], lsb=col)
            for row in range(1, 8):
                v = add("CONCAT", row+1, [add("SEL", 1, [source], lsb=row*8+col), v])
            nodes[tmp]["inputs"].insert(0, [7-col, v, 8*col])
            read = add("SEL", 8, [tmp], lsb=8*col)
            add("REDOR", 1, [add("AND", 8, [mask, read])])

        def matches():
            return [r for r in dataflow_index(graph)["regions"]
                    if r["operation"] == "masked_transpose_reductions"]

        self.assertEqual(len(matches()), 1)
        first = nodes[3]
        first["lsb"] = 1
        self.assertFalse(matches())
        first["lsb"] = 0
        add("SEL", 1, [tmp], lsb=0)
        self.assertFalse(matches())


if __name__ == "__main__":
    unittest.main()
