# SPDX-License-Identifier: MIT
# CMake toolchain for the Bootlin riscv64-lp64d glibc stable toolchain.
# BOOTLIN_ROOT points at the extracted toolchain dir (the one containing
# bin/ and riscv64-buildroot-linux-gnu/sysroot); see cts/README.md.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv64)

# Resolution order: -DBOOTLIN_ROOT / G6LC_BOOTLIN_ROOT, then the
# default location next to the repo .cache (the file is also re-read
# inside CMake try_compile scratch projects, where -D cache vars are
# not forwarded — the relative default keeps that path working).
get_filename_component(_g6lc_repo "${CMAKE_CURRENT_LIST_DIR}/../../../../../../" ABSOLUTE)
if(NOT BOOTLIN_ROOT)
  if(DEFINED ENV{G6LC_BOOTLIN_ROOT} AND NOT "$ENV{G6LC_BOOTLIN_ROOT}" STREQUAL "")
    set(BOOTLIN_ROOT "$ENV{G6LC_BOOTLIN_ROOT}")
  else()
    set(BOOTLIN_ROOT "${_g6lc_repo}/.cache/cts/toolchain/bootlin-2024.05-1")
  endif()
endif()
if(NOT BOOTLIN_ROOT OR NOT EXISTS "${BOOTLIN_ROOT}/riscv64-buildroot-linux-gnu/sysroot")
  message(FATAL_ERROR "BOOTLIN_ROOT has no sysroot: '${BOOTLIN_ROOT}' — extract the Bootlin tarball per cts/README.md")
endif()

set(BOOTLIN_TRIPLE riscv64-buildroot-linux-gnu)
set(CMAKE_SYSROOT ${BOOTLIN_ROOT}/${BOOTLIN_TRIPLE}/sysroot)
set(CMAKE_C_COMPILER   ${BOOTLIN_ROOT}/bin/${BOOTLIN_TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${BOOTLIN_ROOT}/bin/${BOOTLIN_TRIPLE}-g++)
set(CMAKE_AR           ${BOOTLIN_ROOT}/bin/${BOOTLIN_TRIPLE}-ar)
set(CMAKE_RANLIB       ${BOOTLIN_ROOT}/bin/${BOOTLIN_TRIPLE}-ranlib)

set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
