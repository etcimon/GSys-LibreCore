#!/bin/bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Categorical census of a hyp8 witness log: one line per message class.
# usage: census.sh <witness-tag>   (writes /tmp/census-<tag>.txt)
tag=$1
O=/opt/testharness/runs/$tag/output
out=/tmp/census-$tag.txt
{
  echo "tag=$tag log_bytes=$(stat -c %s $O/run-hyp8.log) lastcyc=$(tail -c 4000 $O/trace_rvfi_hart_00.dasm | grep -oE '@[0-9]+' | tail -1)"
  echo "== classes =="
  LC_ALL=C awk '
    /^\[[0-9]+\] %(Warning|Error)/ {
      k=$0; sub(/^\[[0-9]+\] /,"",k);
      # keep severity, file:line and the message stem (numbers folded)
      gsub(/[0-9a-fx]{6,}/,"#",k); gsub(/=[0-9a-f]+/,"=#",k); gsub(/ [0-9]+/," #",k);
      c[substr(k,1,150)]++; next }
    /^%(Warning|Error)/ { k=$0; gsub(/[0-9a-fx]{6,}/,"#",k); c[substr(k,1,150)]++; next }
    /^\[[a-z0-9 _-]+\]/ { k=$0; sub(/\].*/,"]",k); c[k]++; next }
    { other++ }
    END { for (k in c) printf "%10d  %s\n", c[k], k; printf "%10d  <other>\n", other }
  ' $O/run-hyp8.log | sort -rn | head -80
} > $out 2>&1
echo done >> $out
