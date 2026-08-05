# SPDX-License-Identifier: MIT
# Top-level helper for SMT2 OpenSBI software stack.
# Prefer scripts/*.ps1 on Windows.

ROOT := $(abspath ../..)
OUT  ?= $(ROOT)/build-platform/workspace/smt2-linux
export SMT2_LINUX_OUT := $(OUT)

.PHONY: fetch opensbi opensbi-linux payload clean help

help:
	@echo "Targets: fetch | payload | opensbi | opensbi-linux | clean"
	@echo "OUT=$(OUT)"

fetch:
	./scripts/fetch-opensbi.sh

payload:
	$(MAKE) -C payload

opensbi: fetch
	./scripts/build-opensbi-smt2.sh --skip-fetch

opensbi-linux: fetch
	./scripts/build-opensbi-smt2.sh --skip-fetch --linux

clean:
	$(MAKE) -C payload clean
	rm -rf "$(OUT)/opensbi-build" "$(OUT)/fw_payload."* "$(OUT)/smt2_sbi_dual."* "$(OUT)/ariane-smt2.dtb"
