## r90 remote batch verification (r84 procedure, plain profile)

Closure: 729 files (727 + h33_st_fwd.S/h34_shift_dep.S restored from the
deleted build/sv-timing/hyp8-src tree via pulled run hyp8-integration-r46a;
manifest sha256-pinned). Local closure dir:
C:/Users/etcim/AppData/Local/Temp/hyp8-r90-closure.

### Dispatches (testharness_proxy.py py --env, host ovh_calltorch)
- hyp8-integration-r90 : rc=1 - env var not forwarded to remote script
  (HYP8_ALLOW_OVERLAP is read remotely; must go via --env).
- hyp8-integration-r90b: rc=1 - FileNotFoundError on h34_shift_dep.S
  (closure lacked the two .S test sources; fixed, see above). Before
  the crash lint had already run clean.
- hyp8-integration-r90c: rc=0, 352.3s remote (HYP8_ALLOW_OVERLAP=1 via
  --env; guard query pgrep '[/]Variane_testharness|soft-ladder',
  allowOverlap recorded true).
- hyp8-r90-smokes      : rc=1 - HYP8_INT_TAG default (r68c) pointed at a
  stale model; redispatched.
- hyp8-r90-smokes-b    : rc=0, HYP8_INT_TAG=hyp8-integration-r90c.

### Integration results (hyp8-integration-r90c)
status = build_complete
sourceFiles = 729
modelSha256 = 48eebd37aabb5109c043ad57c5b6e3776ced3b53891f00450ec2180689d4da8d
build rc = 0 (runtimeDepFiles 210, runtimeDepChecked true)
lint scalar rc=0, 0 %Error; lint smt2 rc=0, 0 %Error
verilator = 5.008 (verilator-causal), bin sha
3e622e33b741d1b2ba6913e43158e2dba6a9d2fd5e8e89ad2c978360426a254
inputs: 2 test ELFs + 5 hyp8 directed tests assembled fresh (tohost 0x80001000)

### Smokes (hyp8-r90-smokes-b, model sha 48eebd37...)
h34_shift_dep        : pass cycles=685   rc=0
h33_st_fwd           : pass cycles=1011  rc=0
hyp8_branch_cancel   : pass cycles=492   rc=0
hyp8_csr_flush_skip  : pass cycles=2364  rc=0
hyp8_amo_store_order : pass cycles=2199  rc=0
hyp8_amo_ready_order : pass cycles=1231  rc=0
hyp8_f14_store_offset: pass cycles=671   rc=0
7/7 PASS - cycle-identical to the r84 reference
685/1011/492/2364/2199/1231/671.
