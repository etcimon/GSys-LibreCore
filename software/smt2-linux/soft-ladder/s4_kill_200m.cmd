set -uo pipefail
echo "=== testharness PIDs ==="
ps -eo pid,comm,args | awk '/Variane_testhar/ {print}'
killed=0
while read -r pid comm; do
  case "$comm" in
    Variane_testhar*)
      echo "kill $pid $comm"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      killed=1
      ;;
  esac
done < <(ps -eo pid=,comm=)
sleep 1
echo "=== after ==="
ps -eo pid,comm,args | awk '/Variane_testhar/ {print}' || echo none
echo "killed_any=$killed"
# also reap the wrapper bash if it is still waiting on the redirected run
pgrep -af 's4-smv-200m' || true
