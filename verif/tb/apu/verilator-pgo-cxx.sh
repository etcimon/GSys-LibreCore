#!/usr/bin/env bash
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
# Copied into a private build attempt: keep object paths identical in both passes.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cxx="$(cat "$here/compiler")"
flags=()
# Configure probes must not pollute or consume the compiler's gcov profiles.
probe=0
for argument in "$@"; do
  [[ "$argument" != *conftest* ]] || probe=1
done
if (( ! probe )); then
  case "$(cat "$here/phase")" in
    generate) flags+=("-fprofile-generate=$here/profile" -fprofile-update=atomic) ;;
    use) flags+=("-fprofile-use=$here/profile" -fprofile-correction
                 -Werror=coverage-mismatch -Wno-error=missing-profile) ;;
    *) echo "Invalid PGO compiler phase" >&2; exit 2 ;;
  esac
  printf 'PGO-CXX phase=%s flags=' "$(cat "$here/phase")" >&2
  printf '%q ' "${flags[@]}" >&2
  printf '\n' >&2
fi
exec "$cxx" "${flags[@]}" "$@"
