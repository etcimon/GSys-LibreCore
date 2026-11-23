cat > /tmp/taskset_test.sh <<'EOS'
FW=/opt/testharness/runs/hyp8-firmware-r116/output/build-linux-mc/platform/generic/firmware/fw_payload.elf
D=/opt/testharness/runs/devdeadz-ab/model
LOG=/tmp/taskset_results.log
: > $LOG
for cpus in 0-3 0-11; do
  ins=$(cd $D && taskset -c $cpus perf stat -e instructions:u -x, -- ./Variane_testharness +debug_disable +quiet_axi +max-cycles=30000 +time_out=30000 $FW 2>&1 | grep -oE '^[0-9]+' | head -1)
  echo "cpus=$cpus insns=$ins" >> $LOG
done
echo TASKSET_DONE >> $LOG
EOS
setsid nohup bash /tmp/taskset_test.sh > /tmp/taskset_drv.log 2>&1 < /dev/null & echo LAUNCHED
