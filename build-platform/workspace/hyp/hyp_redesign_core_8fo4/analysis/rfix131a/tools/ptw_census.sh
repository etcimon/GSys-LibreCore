#!/bin/bash
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Sub-classify [ptw-err] / [mmu-ife] / [hang] / [seq-gap] / [lsq-ev-miss] records of a witness log.
tag=$1; O=/opt/testharness/runs/$tag/output; out=/tmp/ptwcensus-$tag.txt
{
grep -a '^\[ptw-err\]' $O/run-hyp8.log > /tmp/ptw-$tag.txt
echo "ptw-err total $(wc -l < /tmp/ptw-$tag.txt)"
echo "== by (instr, va-class) =="
awk '{
  va=""; ins="";
  for(i=1;i<=NF;i++){ if($i ~ /^vaddr=/) va=substr($i,7); if($i ~ /^instr=/) ins=substr($i,7) }
  hi=substr(va,1,8); cls="other";
  if (hi=="00000000") { top=substr(va,9,1); cls=(top=="8"||top=="9"||top=="a"||top=="b") ? "phys-dram-va(0x8..)" : ((substr(va,9,4)=="0000") ? "low-user/null" : "user") }
  else if (hi=="ffffffff") cls="kernel-image";
  else if (substr(va,1,6)=="ffffff") cls="kernel-linear/vmalloc";
  else cls="user-high";
  c["instr=" ins " " cls]++ }
  END { for (k in c) printf "%8d  %s\n", c[k], k }' /tmp/ptw-$tag.txt | sort -rn
echo "== top vaddr (instr=1) =="
grep 'instr=1' /tmp/ptw-$tag.txt | grep -oE 'vaddr=[0-9a-f]+' | sort | uniq -c | sort -rn | head -8
echo "== top vaddr (instr=0) =="
grep 'instr=0' /tmp/ptw-$tag.txt | grep -oE 'vaddr=[0-9a-f]+' | sort | uniq -c | sort -rn | head -12
echo "== ptw-err cycle histogram (100M buckets) =="
grep -oE 't=[0-9]+' /tmp/ptw-$tag.txt | awk -F= '{b=int($2/100000000); c[b]++} END {for (k in c) printf "%4d00M %d\n", k, c[k]}' | sort -n
echo "== R Response Errored cycle histogram (10M buckets) =="
grep -a 'Response Errored' $O/run-hyp8.log | grep -oE '^\[[0-9]+' | tr -d '[' | awk '{b=int($1/10000000); c[b]++} END {for (k in c) printf "%5d0M %d\n", k, c[k]}' | sort -n
echo "== hang samples =="
grep -a '^\[hang\]' $O/run-hyp8.log | cut -c1-200 | awk '{k=$2" "$3; c[k]++} END {for (k in c) printf "%6d %s\n", c[k], k}' | sort -rn | head -12
grep -a '^\[hang\]' $O/run-hyp8.log | head -3 | cut -c1-400
echo "== seq-gap samples =="
grep -a '^\[seq-gap\]' $O/run-hyp8.log | head -4 | cut -c1-300
echo "== lsq-ev-miss =="
grep -a '^\[lsq-ev-miss\]' $O/run-hyp8.log | head -6 | cut -c1-300
echo "== mmu-ife causes =="
grep -a '^\[mmu-ife\]' $O/run-hyp8.log | grep -oE 'priv=[0-9]+.*cause=[0-9]+' | sed -E 's/upd_va=[0-9a-f]+//' | sort | uniq -c | sort -rn | head -10
echo "== equiv =="
grep -a '^\[equiv\]' $O/run-hyp8.log | tail -12 | cut -c1-200
echo "== stall-census last =="
grep -a '^\[stall-census\]' $O/run-hyp8.log | tail -2 | cut -c1-700
} > $out 2>&1
echo done >> $out
