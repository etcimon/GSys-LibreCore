#!/bin/bash
# Compare ConstPool symbols between baseline and dev binaries
set -u
B=/opt/testharness/runs/hyp8-rfix131a-phantomprobe-aggregate-t2/output/model/Variane_testharness
D=/opt/testharness/runs/devcase-ab/model/Variane_testharness
nm "$B" | grep ConstPool | awk '{print $3}' | sort > /tmp/cp-base.txt
nm "$D" | grep ConstPool | awk '{print $3}' | sort > /tmp/cp-dev.txt
wc -l /tmp/cp-base.txt /tmp/cp-dev.txt
comm -13 /tmp/cp-base.txt /tmp/cp-dev.txt > /tmp/cp-new.txt
comm -23 /tmp/cp-base.txt /tmp/cp-dev.txt > /tmp/cp-gone.txt
wc -l /tmp/cp-new.txt /tmp/cp-gone.txt
echo "=== NEW constpool symbols (dev only) ==="
cat /tmp/cp-new.txt
echo "=== GONE (base only) ==="
cat /tmp/cp-gone.txt
