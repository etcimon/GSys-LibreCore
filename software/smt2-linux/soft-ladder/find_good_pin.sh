#!/bin/bash
set -uo pipefail
want=bc7ed11dab17454fd147e4927ba07fef
echo "looking for pin md5 $want"
found=0
while IFS= read -r -d '' f; do
  m=$(md5sum "$f" | awk '{print $1}')
  echo "$m  $f"
  if [[ "$m" == "$want" ]]; then
    echo "FOUND_GOOD $f"
    found=1
  fi
done < <(find /mnt/e/cva6/software/smt2-linux/soft-ladder/build \
  /mnt/c/Users/etcim/.grok/worktrees/cva6 \
  /tmp \
  -name 'fw_payload*.elf' -type f 2>/dev/null | head -80 | tr '\n' '\0')
# also plain md5 all local build
echo "--- local build ---"
md5sum /mnt/e/cva6/software/smt2-linux/soft-ladder/build/* 2>/dev/null || true
if [[ "$found" -eq 0 ]]; then
  echo "GOOD_PIN_NOT_FOUND"
  exit 1
fi
exit 0
