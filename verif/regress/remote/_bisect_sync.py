"""One-off: rsync a local snapshot tree to a remote repo dir via the proxy transport."""
import sys
sys.path.insert(0, "verif/regress/remote")
import testharness_proxy as tp


# git archive leaves submodule dirs empty; excluding them protects the
# already-populated remote copies from --delete-delay.
SUBMODULE_DIRS = [
    "corev_apu/axi_mem_if",
    "corev_apu/register_interface",
    "corev_apu/fpga/src/apb_uart",
    "corev_apu/fpga/src/apb_node",
    "corev_apu/fpga/src/axi2apb",
    "corev_apu/fpga/src/axi_slice",
    "corev_apu/fpga/src/ariane-ethernet",
    "corev_apu/fpga/src/apb_timer",
    "corev_apu/fpga/src/apb",
    "corev_apu/fpga/src/gpio",
    "corev_apu/riscv-dbg",
    "corev_apu/rv_plic",
    "corev_apu/tb/common_verification",
    "verif/core-v-verif",
    "verif/sim/dv",
    "core/cvfpu",
    "core/cache_subsystem/hpdcache",
    "vendor/ara/upstream",
]


def whitelist_filters():
    filters = []
    for d in SUBMODULE_DIRS:
        filters += ["--exclude", f"/{d}/"]
    for inc in tp.SYNC_INCLUDE:
        if inc.endswith("/"):
            parts = inc.rstrip("/").split("/")
            acc = ""
            for p in parts:
                acc = f"{acc}/{p}" if acc else p
                filters += ["--include", f"/{acc}/"]
            filters += ["--include", f"/{inc}***"]
        else:
            parts = inc.split("/")
            acc = ""
            for p in parts[:-1]:
                acc = f"{acc}/{p}" if acc else p
                filters += ["--include", f"/{acc}/"]
            filters += ["--include", f"/{inc}"]
    for pat in tp.SYNC_EXCLUDE:
        filters += ["--exclude", pat]
    filters += ["--exclude", "*"]
    return filters


def main():
    src, dst = sys.argv[1], sys.argv[2]
    rem = tp.Remote("ovh_calltorch")
    rem.start_master()
    rem.run(f"mkdir -p {dst}")
    rem.rsync(src, f"ovh_calltorch:{dst}/", whitelist_filters())
    print("SYNCED", src, "->", dst)


if __name__ == "__main__":
    main()
