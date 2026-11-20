#!/bin/bash
# Find which functions reference the 6 new ConstPool TABLE symbols
set -u
D=/opt/testharness/runs/devcase-ab/model/Variane_testharness
OUT=/tmp/table-users.txt
: > "$OUT"
objdump -d --no-show-raw-insn "$D" | awk '
/^[0-9a-f]+ <.*>:$/ { fn=$0 }
/TABLE_h280ae42d|TABLE_h4b04e8c6|TABLE_h5e117bc7|TABLE_h675ee9f3|TABLE_hd1804db9|TABLE_hff4b0479/ {
    print fn " || " $0
}' >> "$OUT"
wc -l "$OUT"
# summarize: which functions use tables, count per function
awk -F' \\|\\| ' '{print $1}' "$OUT" | sort | uniq -c | sort -rn | head -40
