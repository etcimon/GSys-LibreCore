#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# g6q.py — PRIMARY cross-platform CLI for the g6lc_qemu package.
# Prefer this over shell/PowerShell for all package automation (AGENTS.md section 4).
#
#   python tools/g6q.py setup          # contained rustup/cargo under .tools/
#   python tools/g6q.py setup-riscv    # contained xPack RISC-V cross-toolchain under .tools/
#   python tools/g6q.py setup-host     # auto-install host tools (toolchain/qemu/dtc/spike)
#   python tools/g6q.py doctor         # host probe
#   python tools/g6q.py build | test | check | run | cargo | flist | clean | env
#   python tools/g6q.py fetch-qemu | build-qemu | install-qemu
#   python tools/g6q.py fetch-fw   | build-fw
#   python tools/g6q.py bridge    # host AI-tensor bridge wrapper
#
# GREEN COMMAND: `python tools/g6q.py check`

from __future__ import annotations

import argparse
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import urllib.request
import venv
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import (  # noqa: E402
    apply_env,
    cargo_bin,
    cargo_home,
    contained_env,
    have_contained_toolchain,
    out_dir,
    python_venv,
    riscv_toolchain_bin,
    package_root,
    rustup_home,
    target_dir,
    toolchain_channel,
    tools_dir,
    venv_python,
)
from platform_constants import (  # noqa: E402
    host_tool,
    host_tool_build_hint,
    host_tool_cmd,
    host_tool_fallback,
    rustup_url,
    xpack_riscv,
)
import msvc_env  # noqa: E402

_WINDOWS = platform.system() == "Windows"


def log(msg: str) -> None:
    print(f"[g6q] {msg}")


def err(msg: str) -> None:
    print(f"[g6q] ERROR: {msg}", file=sys.stderr)


def run(cmd: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        check: bool = True, capture_output: bool = False, text: bool = False,
        **kwargs) -> subprocess.CompletedProcess:
    log("+ " + " ".join(str(c) for c in cmd))
    return subprocess.run([str(c) for c in cmd], cwd=str(cwd) if cwd else None,
                          env=env, check=check, capture_output=capture_output, text=text,
                          **kwargs)


def resolve_cargo() -> str | None:
    """Contained cargo first, then PATH. Returns None when neither exists."""
    if cargo_bin().is_file():
        return str(cargo_bin())
    found = shutil.which("cargo")
    return found


def require_cargo() -> str:
    c = resolve_cargo()
    if not c:
        err("no cargo found. Run `python tools/g6q.py setup` to install a contained "
            "toolchain, or put cargo on PATH.")
        raise SystemExit(2)
    return c


# ----------------------------------------------------------------------- setup ---

def cmd_setup(args: argparse.Namespace) -> int:
    tools_dir().mkdir(parents=True, exist_ok=True)

    if have_contained_toolchain() and not args.force:
        log(f"contained cargo already present: {cargo_bin()}")
    else:
        channel = toolchain_channel()
        log(f"installing contained rustup + toolchain {channel} into {tools_dir()}")
        # Installation must be contained unconditionally; see env_common.contained_env.
        env = contained_env()
        # rustup-init takes ONE value per --component; a second bare word is parsed as a
        # positional and rejected.
        components = ["--component", "rustfmt", "--component", "clippy"]
        if _WINDOWS:
            init = tools_dir() / "rustup-init.exe"
            _download(rustup_url(), init)
            run([init, "-y", "--no-modify-path", "--profile", "minimal",
                 "--default-toolchain", channel, *components], env=env)
        else:
            init = tools_dir() / "rustup-init.sh"
            _download(rustup_url(), init)
            init.chmod(init.stat().st_mode | stat.S_IEXEC)
            run(["sh", str(init), "-y", "--no-modify-path", "--profile", "minimal",
                 "--default-toolchain", channel, *components], env=env)

        if not have_contained_toolchain():
            err(f"setup finished but no cargo at {cargo_bin()}; refusing to claim success")
            return 1

    # Prove containment rather than assume it: a toolchain that silently landed in the
    # user's home directory would defeat the point of this command.
    log(f"RUSTUP_HOME = {rustup_home()}")
    log(f"CARGO_HOME  = {cargo_home()}")
    log("setup complete; next: python tools/g6q.py check")
    return 0


def _download(url: str, dest: Path) -> None:
    log(f"downloading {url} -> {dest}")
    with urllib.request.urlopen(url) as resp, open(dest, "wb") as fh:  # noqa: S310
        shutil.copyfileobj(resp, fh)


def _extract_archive(archive: Path, dest: Path, archive_type: str,
                     strip_components: int = 0) -> None:
    """Extract a tar/zip archive to a temporary location and then move it to `dest`."""
    import tarfile
    import zipfile

    extract_tmp = tools_dir() / f".{archive.name}.extract"
    if extract_tmp.exists():
        shutil.rmtree(extract_tmp)
    extract_tmp.mkdir(parents=True)

    if archive_type == "zip":
        with zipfile.ZipFile(archive) as z:
            z.extractall(path=extract_tmp)
    elif archive_type in ("tar", "tar.gz", "tar.bz2", "tar.xz"):
        mode = {
            "tar": "r:",
            "tar.gz": "r:gz",
            "tar.bz2": "r:bz2",
            "tar.xz": "r:xz",
        }[archive_type]
        with tarfile.open(archive, mode) as t:
            t.extractall(path=extract_tmp)
    else:
        raise ValueError(f"unsupported archive type: {archive_type}")

    top = [p for p in extract_tmp.iterdir() if p.is_dir()]
    if strip_components > 0 and len(top) == 1:
        # The archive has a single top-level directory; move its contents up.
        if dest.exists():
            shutil.rmtree(dest)
        top[0].rename(dest)
    else:
        if dest.exists():
            shutil.rmtree(dest)
        extract_tmp.rename(dest)


def _install_standalone(name: str, spec: dict, dry_run: bool, force: bool) -> int:
    """Download and extract a standalone host tool according to platform-constants.toml."""
    if dry_run:
        log(f"would install {name} standalone: {spec['url']}")
        return 0

    url = spec["url"]
    archive_type = spec["archive"]
    install_dir = package_root() / Path(spec["install_dir"])
    install_dir.mkdir(parents=True, exist_ok=True)

    if archive_type == "exe":
        # Windows installer (Inno Setup). Silent install to a fixed directory.
        setup = tools_dir() / f"{name}-setup.exe"
        _download(url, setup)
        abs_dir = install_dir.resolve()
        run([str(setup), "/S", f"/D={abs_dir}"], check=True)
        setup.unlink(missing_ok=True)
    else:
        archive = tools_dir() / f"{name}-download.{archive_type.replace('.', '')}"
        _download(url, archive)
        _extract_archive(
            archive,
            install_dir,
            archive_type,
            strip_components=spec.get("strip_components", 0),
        )
        archive.unlink(missing_ok=True)

    log(f"{name} standalone installed: {install_dir}")
    return 0


def _install_from_source(name: str, spec: dict, pm: str | None, *,
                         dry_run: bool, force: bool) -> int:
    """Download and build a host tool from source."""
    if dry_run:
        log(f"would build {name} from source: {spec['url']}")
        return 0

    required = spec.get("requires", [])
    if required and _ensure_build_tools(required, pm, dry_run=dry_run, force=force) != 0:
        err(f"{name} source build requires: {', '.join(required)}")
        return 1

    url = spec["url"]
    archive_type = spec["archive"]
    src_dir = package_root() / Path(spec["install_dir"])
    src_dir.mkdir(parents=True, exist_ok=True)

    archive = tools_dir() / f"{name}-src.{archive_type.replace('.', '')}"
    _download(url, archive)
    _extract_archive(archive, src_dir, archive_type,
                     strip_components=spec.get("strip_components", 0))
    archive.unlink(missing_ok=True)

    build_env = spec.get("build_env")
    if build_env == "msvc" and not _WINDOWS:
        raise SystemExit(f"{name} build_env=msvc is only supported on Windows")
    if build_env == "msvc" and _WINDOWS:
        if not msvc_env.import_msvc_environment():
            err("MSVC build environment not found; install Visual Studio Build Tools with the C++ workload")
            return 1
        log(f"MSVC ready: {shutil.which('cl')}")

    if "build_steps" in spec:
        for step in spec["build_steps"]:
            if isinstance(step, str):
                step = shlex.split(step)
            log(f"building {name}: {' '.join(step)}")
            run(step, cwd=src_dir, check=True)
    else:
        build_cmd = spec["build_cmd"]
        if isinstance(build_cmd, str):
            build_cmd = shlex.split(build_cmd)
        log(f"building {name}: {' '.join(build_cmd)}")
        run(build_cmd, cwd=src_dir, check=True)
    log(f"{name} built: {src_dir}")
    return 0


def _xpack_riscv_asset_url(ref: str) -> str:
    """Return the GitHub release asset URL for this platform."""
    base = f"{xpack_riscv()['repo']}/releases/download/v{ref}"
    system = platform.system().lower()
    if system == "windows":
        return f"{base}/xpack-riscv-none-elf-gcc-{ref}-win32-x64.zip"
    if system == "linux":
        return f"{base}/xpack-riscv-none-elf-gcc-{ref}-linux-x64.tar.gz"
    if system == "darwin":
        return f"{base}/xpack-riscv-none-elf-gcc-{ref}-darwin-x64.tar.gz"
    raise SystemExit(f"unsupported platform for RISC-V toolchain setup: {system}")


def _xpack_extract_top_dir(archive: Path) -> str:
    """Peek at the archive and return the name of the single top-level directory."""
    if archive.suffix == ".zip":
        import zipfile

        with zipfile.ZipFile(archive) as z:
            names = z.namelist()
    else:
        import tarfile

        with tarfile.open(archive, "r:gz") as t:
            names = t.getnames()
    top = {n.split("/")[0] for n in names if "/" in n}
    if len(top) != 1:
        raise SystemExit(f"archive {archive} does not contain exactly one top-level directory")
    return top.pop()


def cmd_setup_riscv(args: argparse.Namespace) -> int:
    """Download and extract the pinned xPack RISC-V toolchain under .tools/."""
    ref = args.ref or xpack_riscv()["ref"]
    tools = tools_dir()
    tools.mkdir(parents=True, exist_ok=True)
    dest = tools / f"xpack-riscv-none-elf-gcc-{ref}"
    if dest.exists() and not args.force:
        log(f"contained RISC-V toolchain already present: {dest}")
        return 0

    url = _xpack_riscv_asset_url(ref)
    suffix = ".zip" if url.endswith(".zip") else ".tar.gz"
    archive = tools / f"xpack-riscv-none-elf-gcc-{ref}{suffix}"

    if args.dry_run:
        log(f"would download {url}")
        log(f"would extract into {dest}")
        return 0

    _download(url, archive)

    if archive.suffix == ".zip":
        import zipfile

        with zipfile.ZipFile(archive) as z:
            z.extractall(tools)
    else:
        import tarfile

        with tarfile.open(archive, "r:gz") as t:
            t.extractall(tools)

    top_dir = tools / _xpack_extract_top_dir(archive)
    if not top_dir.samefile(dest):
        top_dir.rename(dest)

    archive.unlink()

    gcc = dest / "bin" / ("riscv-none-elf-gcc" + (".exe" if _WINDOWS else ""))
    if not gcc.is_file():
        err(f"toolchain extracted but no gcc at {gcc}")
        return 1

    log(f"RISC-V toolchain installed: {dest}")
    log("next: python tools/g6q.py doctor")
    return 0


def _probe_riscv_cross() -> tuple[str, str] | None:
    """Return (gcc_exe, prefix) for the first RISC-V cross-toolchain on PATH.

    On Windows the contained xPack `riscv-none-elf-gcc` is fine for small payloads
    but cannot build OpenSBI because its linker does not support PIE. We therefore
    prefer a WSL toolchain (especially `riscv64-linux-gnu-`) when WSL is present.
    """
    path = apply_env().get("PATH", os.environ.get("PATH", ""))
    prefixes = [
        "riscv-none-elf-",
        "riscv64-unknown-elf-",
        "riscv64-unknown-linux-gnu-",
        "riscv64-linux-gnu-",
        "riscv64-none-elf-",
    ]
    env = os.environ.get("CROSS_COMPILE", "")
    if env:
        if _WINDOWS and shutil.which("wsl"):
            if subprocess.run(["wsl", "which", f"{env}gcc"], capture_output=True).returncode == 0:
                return (f"wsl {env}gcc", env)
        gcc = f"{env}gcc"
        if shutil.which(gcc, path=path):
            return (gcc, env)
    # Prefer WSL toolchains on Windows because OpenSBI needs a PIE-capable linker.
    if _WINDOWS and shutil.which("wsl"):
        for prefix in ["riscv64-linux-gnu-", "riscv64-unknown-freebsd-", "riscv64-unknown-elf-", "riscv-none-elf-"]:
            if subprocess.run(["wsl", "which", f"{prefix}gcc"], capture_output=True).returncode == 0:
                return (f"wsl {prefix}gcc", prefix)
    if (bin_dir := riscv_toolchain_bin()) is not None:
        gcc = bin_dir / ("riscv-none-elf-gcc" + (".exe" if _WINDOWS else ""))
        if gcc.is_file():
            return (str(gcc), "riscv-none-elf-")
    for prefix in prefixes:
        gcc = f"{prefix}gcc"
        if shutil.which(gcc, path=path):
            return (gcc, prefix)
    return None


# ------------------------------------------------------------------ setup-host ---
# Tooling that the package can consume from the host. Each entry maps a logical tool
# to a package-list per package manager. A `None` value means the tool is not packaged
# for that manager and must be installed manually or built from source.

_HOST_TOOLS: dict[str, dict[str, object]] = {
    "opensbi-toolchain": {
        "help": "PIE-capable RISC-V cross-toolchain for OpenSBI",
        "probe": _probe_riscv_cross,
        "packages": {
            "choco": None,
            "wsl-apt": ["gcc-riscv64-linux-gnu"],
            "apt": ["gcc-riscv64-linux-gnu"],
            "dnf": ["gcc-riscv64-linux-gnu"],
            "pacman": ["riscv64-linux-gnu-gcc"],
            "apk": None,
            "brew": None,
        },
    },
    "qemu": {
        "help": "QEMU system emulator for RISC-V",
        "probe": lambda: _which_host("qemu-system-riscv64"),
        "packages": {
            "choco": ["qemu"],
            "wsl-apt": ["qemu-system-misc"],
            "apt": ["qemu-system-misc"],
            "dnf": ["qemu-system-riscv"],
            "pacman": ["qemu"],
            "apk": ["qemu-system-riscv64"],
            "brew": ["qemu"],
        },
    },
    "dtc": {
        "help": "device-tree compiler",
        "probe": lambda: _which_host("dtc"),
        "packages": {
            "choco": ["dtc-msys2"],
            "wsl-apt": ["device-tree-compiler"],
            "apt": ["device-tree-compiler"],
            "dnf": ["dtc"],
            "pacman": ["dtc"],
            "apk": ["dtc"],
            "brew": ["dtc"],
        },
    },
    "spike": {
        "help": "Spike RISC-V ISA simulator",
        "probe": lambda: _which_host("spike"),
        "packages": {
            "choco": None,
            "wsl-apt": None,
            "apt": None,
            "dnf": None,
            "pacman": None,
            "apk": None,
            "brew": None,
        },
    },
}

# Build tools required for build-from-source fallbacks. `pip` is the PyPI package
# name used when no package manager is available; the venv lives under .tools/python-venv.
_BUILD_TOOLS: dict[str, dict[str, object]] = {
    "make": {
        "cmd": "make",
        "packages": {
            "choco": ["make"],
            "wsl-apt": ["make"],
            "apt": ["make"],
            "dnf": ["make"],
            "pacman": ["make"],
            "apk": ["make"],
            "brew": ["make"],
        },
    },
    "meson": {
        "cmd": "meson",
        "pip": "meson",
        "packages": {
            "choco": ["meson"],
            "wsl-apt": ["meson"],
            "apt": ["meson"],
            "dnf": ["meson"],
            "pacman": ["meson"],
            "apk": ["meson"],
            "brew": ["meson"],
        },
    },
    "ninja": {
        "cmd": "ninja",
        "pip": "ninja",
        "packages": {
            "choco": ["ninja"],
            "wsl-apt": ["ninja-build"],
            "apt": ["ninja-build"],
            "dnf": ["ninja-build"],
            "pacman": ["ninja"],
            "apk": ["ninja"],
            "brew": ["ninja"],
        },
    },
    "cmake": {
        "cmd": "cmake",
        "pip": "cmake",
        "packages": {
            "choco": ["cmake"],
            "wsl-apt": ["cmake"],
            "apt": ["cmake"],
            "dnf": ["cmake"],
            "pacman": ["cmake"],
            "apk": ["cmake"],
            "brew": ["cmake"],
        },
    },
    "bison": {
        "cmd": "bison",
        "packages": {
            "choco": ["winflexbison3"],
            "wsl-apt": ["bison"],
            "apt": ["bison"],
            "dnf": ["bison"],
            "pacman": ["bison"],
            "apk": ["bison"],
            "brew": ["bison"],
        },
    },
    "flex": {
        "cmd": "flex",
        "packages": {
            "choco": ["winflexbison3"],
            "wsl-apt": ["flex"],
            "apt": ["flex"],
            "dnf": ["flex"],
            "pacman": ["flex"],
            "apk": ["flex"],
            "brew": ["flex"],
        },
    },
}


def _wsl_has_apt() -> bool:
    """True when the default WSL distribution can run apt-get."""
    if not shutil.which("wsl"):
        return False
    return subprocess.run(["wsl", "-e", "apt-get", "--version"],
                          capture_output=True).returncode == 0


def _which_host(cmd: str) -> str | None:
    """Look for a host executable, checking .tools/ and WSL on Windows when needed."""
    path = apply_env().get("PATH", os.environ.get("PATH", ""))
    if not _WINDOWS:
        return shutil.which(cmd, path=path)
    exe = cmd + ".exe"
    native = shutil.which(exe, path=path) or shutil.which(cmd, path=path)
    if native:
        return native
    if shutil.which("wsl"):
        if subprocess.run(["wsl", "which", cmd], capture_output=True).returncode == 0:
            return f"wsl {cmd}"
    return None


def _detect_package_manager() -> str | None:
    """Pick the best package manager for this host.

    On Windows, Chocolatey is preferred for native tooling; WSL apt is used
    when no native package manager is available (OpenSBI still requires WSL).
    """
    if _WINDOWS:
        if shutil.which("choco"):
            return "choco"
        if _wsl_has_apt():
            return "wsl-apt"
        return None
    if shutil.which("apt-get"):
        return "apt"
    if shutil.which("dnf"):
        return "dnf"
    if shutil.which("pacman"):
        return "pacman"
    if shutil.which("apk"):
        return "apk"
    if shutil.which("brew"):
        return "brew"
    return None


def _host_sudo_prefix() -> list[str]:
    """Return ['sudo', '-n'] when not root and sudo is available, otherwise []."""
    if _WINDOWS or os.geteuid() == 0 or not shutil.which("sudo"):
        return []
    return ["sudo", "-n"]


def _install_packages(pm: str, packages: list[str], dry_run: bool) -> None:
    if dry_run:
        log(f"would install with {pm}: {' '.join(packages)}")
        return
    if pm == "wsl-apt":
        run(["wsl", "-u", "root", "-e", "apt-get", "update", "-qq"], check=False)
        run(["wsl", "-u", "root", "-e", "apt-get", "install", "-y", *packages])
    elif pm == "apt":
        run([*_host_sudo_prefix(), "apt-get", "update"], check=False)
        run([*_host_sudo_prefix(), "apt-get", "install", "-y", *packages])
    elif pm == "dnf":
        run([*_host_sudo_prefix(), "dnf", "install", "-y", *packages])
    elif pm == "pacman":
        run([*_host_sudo_prefix(), "pacman", "-S", "--noconfirm", *packages])
    elif pm == "apk":
        run([*_host_sudo_prefix(), "apk", "add", *packages])
    elif pm == "brew":
        run(["brew", "install", *packages])
    elif pm == "choco":
        # Chocolatey packages often need an admin shell; the caller is responsible for that.
        # -y auto-confirm; --no-progress keeps the log quiet.
        run(["choco", "install", "-y", "--no-progress", *packages])
    else:
        raise SystemExit(f"unsupported package manager: {pm}")


def _is_admin() -> bool:
    """Return True when the current Windows process has admin rights."""
    if not _WINDOWS:
        return os.geteuid() == 0
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _install_choco() -> int:
    """Install Chocolatey using the official install script (requires admin)."""
    if not _is_admin():
        err("Chocolatey install requires an administrator PowerShell; re-run as administrator")
        return 1
    log("installing Chocolatey...")
    script = (
        "[System.Net.ServicePointManager]::SecurityProtocol = 3072; "
        "iex (New-Object System.Net.WebClient).DownloadString("
        "'https://community.chocolatey.org/install.ps1')"
    )
    run([
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-Command", script,
    ], check=True)
    choco_bin = Path(r"C:\ProgramData\chocolatey\bin")
    if choco_bin.is_dir():
        sep = os.pathsep
        paths = os.environ.get("PATH", "").split(sep)
        if str(choco_bin) not in paths:
            paths.insert(0, str(choco_bin))
            os.environ["PATH"] = sep.join(paths)
    if not shutil.which("choco"):
        err("Chocolatey install completed but choco is not on PATH; open a new terminal and retry")
        return 1
    log(f"Chocolatey ready: {shutil.which('choco')}")
    return 0


def _install_msvc_via_choco(year: int) -> int:
    """Install Visual Studio Build Tools + VC workload via Chocolatey (requires admin)."""
    if not _is_admin():
        err("MSVC install via Chocolatey requires an administrator shell")
        return 1
    base = f"visualstudio{year}buildtools"
    workload = f"visualstudio{year}-workload-vctools"
    log(f"installing {base} + {workload} via Chocolatey...")
    run(["choco", "install", "-y", "--no-progress", base, workload], check=True)
    if not msvc_env.import_msvc_environment():
        err("MSVC package installed but cl.exe is still not on PATH; open a new terminal and retry")
        return 1
    log(f"MSVC ready: {shutil.which('cl')}")
    return 0


def _print_wsl_instructions() -> None:
    log("""
WSL is required for OpenSBI (it needs a POSIX shell and a PIE-capable RISC-V Linux linker).
To install WSL, open an administrator PowerShell and run:

    wsl --install -d Ubuntu

Then reboot when asked, complete the Ubuntu first-run setup, and re-run:

    python tools/g6q.py setup-host --toolchain
""")


def _windows_source_build_selected(args: argparse.Namespace, selected: list[str]) -> bool:
    """Return True when the selected host tools imply a native Windows source build."""
    if "dtc" in selected and (args.standalone or not _wsl_has_apt()):
        return True
    if "spike" in selected:
        return True
    if "all" in selected and not _wsl_has_apt():
        return True
    return False


def _smart_windows_preflight(args: argparse.Namespace, selected: list[str]) -> int:
    """Detect missing native-Windows prerequisites and prompt/auto-install.

    Returns 0 to continue, 1 to exit gracefully. With --yes, auto-install is
    attempted; in an interactive terminal the user is prompted.
    """
    if not _WINDOWS:
        return 0

    have_choco = shutil.which("choco") is not None
    have_wsl = shutil.which("wsl") is not None
    have_msvc = msvc_env.have_msvc()
    source_build = _windows_source_build_selected(args, selected)

    # Nothing missing.
    if have_choco and (have_wsl or not source_build) and have_msvc:
        return 0

    if args.yes:
        # Non-interactive auto-install path.
        if not have_choco:
            if _install_choco() != 0:
                return 1
            have_choco = True
        if source_build and not have_msvc:
            if _install_msvc_via_choco(args.vs_year) != 0:
                return 1
            have_msvc = True
        if "opensbi-toolchain" in selected and not have_wsl:
            err("OpenSBI toolchain requires WSL; install it with: wsl --install -d Ubuntu")
            _print_wsl_instructions()
            return 1
        return 0

    if args.dry_run:
        # In dry-run, just report what would be missing.
        if not have_choco:
            log("would need to install Chocolatey for native Windows tooling")
        if source_build and not have_msvc:
            log(f"would need to install Visual Studio {args.vs_year} Build Tools for native source builds")
        if not have_wsl and "opensbi-toolchain" in selected:
            log("would need WSL for the OpenSBI toolchain")
        return 0

    if not sys.stdin.isatty():
        err("native Windows setup is incomplete: install Chocolatey and/or Visual Studio Build Tools, or use --yes to auto-install")
        _print_wsl_instructions()
        return 1

    # Build a menu based on what is missing.
    options: list[tuple[str, str]] = []
    if not have_choco:
        options.append(("Install Chocolatey", "choco"))
    if source_build and not have_msvc and have_choco:
        options.append((f"Install Visual Studio {args.vs_year} Build Tools", "msvc"))
    if not have_wsl:
        options.append(("Show WSL install instructions", "wsl"))
    options.append(("Exit", "exit"))

    print("[g6q] Native Windows setup is incomplete.")
    if not have_choco:
        print("  - Chocolatey not found")
    if source_build and not have_msvc:
        print(f"  - MSVC (Visual Studio {args.vs_year} Build Tools) not found")
    if not have_wsl:
        print("  - WSL not found")
    print("Choose an option:")
    for i, (label, _) in enumerate(options, 1):
        print(f"  {i}. {label}")

    choice_str = input("Option: ").strip()
    try:
        choice = int(choice_str)
    except ValueError:
        choice = 0
    if choice < 1 or choice > len(options):
        err("invalid option")
        return 1
    action = options[choice - 1][1]

    if action == "choco":
        if _install_choco() != 0:
            return 1
        return _smart_windows_preflight(args, selected)
    if action == "msvc":
        if _install_msvc_via_choco(args.vs_year) != 0:
            return 1
        return _smart_windows_preflight(args, selected)
    if action == "wsl":
        _print_wsl_instructions()
        return 1
    return 1


def _install_host_tool(name: str, pm: str | None, *, dry_run: bool, force: bool,
                       prefer_standalone: bool = False) -> int:
    """Install a single host tool: package manager first, then standalone, then source."""
    spec = _HOST_TOOLS[name]
    probe = spec["probe"]
    present = probe() if callable(probe) else shutil.which(str(probe))
    if present and not force:
        log(f"{name} already present: {present}")
        return 0

    # Package-manager path when one is detected and the tool is packaged for it.
    packages = spec["packages"].get(pm or "") if pm else None
    if packages and not prefer_standalone:
        if dry_run:
            log(f"would install {name} via {pm}: {packages}")
            return 0
        log(f"installing {name} via {pm}: {packages}")
        _install_packages(pm, packages, dry_run=False)
        present = probe() if callable(probe) else shutil.which(str(probe))
        if present:
            log(f"{name} installed: {present}")
            return 0
        err(f"{name} still not on PATH after package-manager install")

    # Standalone binary download fallback.
    standalone = host_tool_fallback(name, kind="standalone")
    if standalone:
        if dry_run:
            log(f"would install {name} standalone from {standalone['url']}")
            return 0
        rc = _install_standalone(name, standalone, dry_run=False, force=force)
        present = probe() if callable(probe) else shutil.which(str(probe))
        if present:
            log(f"{name} installed: {present}")
            return 0
        err(f"{name} still not on PATH after standalone install")
        return 1 if rc == 0 else rc

    # Build-from-source fallback.
    source = host_tool_fallback(name, kind="build_from_source")
    if source:
        if dry_run:
            log(f"would build {name} from source: {source['url']}")
            return 0
        rc = _install_from_source(name, source, pm, dry_run=False, force=force)
        present = probe() if callable(probe) else shutil.which(str(probe))
        if present:
            log(f"{name} installed: {present}")
            return 0
        err(f"{name} still not on PATH after source build")
        return 1 if rc == 0 else rc

    if pm and not prefer_standalone:
        log(f"{name} is not available from {pm}; install it manually")
    else:
        log(f"{name} has no standalone or build-from-source entry for this platform; install it manually")
    if name == "spike":
        log(f"spike build hint: see {host_tool_build_hint('spike')}")
    return 0 if dry_run else 1


def _ensure_python_venv() -> Path:
    """Create or return the contained Python venv under .tools/python-venv."""
    vdir = python_venv()
    if not (vdir / ("Scripts" if _WINDOWS else "bin") / ("python.exe" if _WINDOWS else "python")).is_file():
        log(f"creating contained Python venv: {vdir}")
        vdir.mkdir(parents=True, exist_ok=True)
        venv.create(vdir, with_pip=True)
    return vdir


def _venv_pip() -> list[str]:
    """Return the pip invocation inside .tools/python-venv."""
    py = venv_python()
    return [str(py), "-m", "pip"]


def _install_build_tool(name: str, pm: str | None, *, dry_run: bool,
                        force: bool) -> int:
    """Install a single build tool via package manager, then pip, then report missing."""
    spec = _BUILD_TOOLS[name]
    cmd = spec["cmd"]
    present = _which_host(cmd)
    if present and not force:
        log(f"{name} already present: {present}")
        return 0

    packages = spec.get("packages", {}).get(pm or "") if pm else None
    if packages:
        if dry_run:
            log(f"would install {name} via {pm}: {packages}")
            return 0
        log(f"installing {name} via {pm}: {packages}")
        _install_packages(pm, packages, dry_run=False)
        # Chocolatey's winflexbison3 installs win_bison/win_flex; create bison/flex shims.
        if pm == "choco" and name in ("bison", "flex"):
            _setup_winflexbison_shims()
        present = _which_host(cmd)
        if present:
            log(f"{name} installed: {present}")
            return 0
        err(f"{name} still not on PATH after package-manager install")

    pip_pkg = spec.get("pip")
    if pip_pkg:
        if dry_run:
            log(f"would install {name} into .tools/python-venv via pip: {pip_pkg}")
            return 0
        vdir = _ensure_python_venv()
        run(_venv_pip() + ["install", "--upgrade", pip_pkg], check=True)
        present = _which_host(cmd)
        if present:
            log(f"{name} installed in venv: {present}")
            return 0
        err(f"{name} still not on PATH after pip install")

    log(f"{name} has no package or pip fallback for this platform; install it manually")
    return 0 if dry_run else 1


def _find_winflexbison_dir() -> Path | None:
    """Return the directory containing the real win_bison.exe/win_flex.exe."""
    roots = [
        Path(r"C:\ProgramData\chocolatey\lib\winflexbison3\tools"),
        Path(r"C:\ProgramData\chocolatey\lib\winflexbison3\tools\winflexbison3"),
        Path(r"C:\tools\winflexbison3"),
    ]
    for r in roots:
        if (r / "win_bison.exe").is_file() and (r / "win_flex.exe").is_file():
            return r
    wb = shutil.which("win_bison")
    if wb:
        p = Path(wb)
        if p.name.lower() == "win_bison.exe" and (p.parent / "win_flex.exe").is_file():
            return p.parent
    return None


def _setup_winflexbison_shims() -> None:
    """Chocolatey's winflexbison3 installs win_bison/win_flex; meson looks for bison/flex."""
    src = _find_winflexbison_dir()
    if src is None:
        log("winflexbison3 installed but win_bison.exe/win_flex.exe not found; bison/flex may not work")
        return
    shim = package_root() / ".tools" / "win-flex-bison"
    if shim.is_dir():
        shutil.rmtree(shim)
    shim_bin = shim / "bin"
    shim_bin.mkdir(parents=True, exist_ok=True)
    for exe in ("win_bison.exe", "win_flex.exe"):
        shutil.copy2(src / exe, shim_bin / exe)
    (shim_bin / "win_bison.exe").rename(shim_bin / "bison.exe")
    (shim_bin / "win_flex.exe").rename(shim_bin / "flex.exe")
    log(f"created bison/flex shims in {shim_bin}")


def _ensure_build_tools(required: list[str], pm: str | None, *, dry_run: bool,
                        force: bool) -> int:
    """Ensure all build tools required by a source build are installed."""
    rc = 0
    for tool in required:
        if _install_build_tool(tool, pm, dry_run=dry_run, force=force) != 0:
            rc = 1
    return rc


def _install_build_tools_selected(selected: list[str], pm: str | None, *,
                                  dry_run: bool, force: bool) -> int:
    """Install the requested build tools (or all if selected is empty)."""
    tools = selected or list(_BUILD_TOOLS.keys())
    rc = 0
    for name in tools:
        if _install_build_tool(name, pm, dry_run=dry_run, force=force) != 0:
            rc = 1
    return rc


def cmd_setup_host(args: argparse.Namespace) -> int:
    """Install missing host tooling using the detected package manager.

    Fallback order: package manager → standalone binary download → build from source.
    On Windows this prefers WSL with a Debian/Ubuntu-derived distribution because
    OpenSBI needs a POSIX shell and a PIE-capable RISC-V linker. When WSL is not
    available, standalone binaries (e.g. QEMU) are used where a pinned download exists.
    """
    selected: list[str] = []
    if args.toolchain or args.all:
        selected.append("opensbi-toolchain")
    if args.qemu or args.all:
        selected.append("qemu")
    if args.dtc or args.all:
        selected.append("dtc")
    if args.spike or args.all:
        selected.append("spike")
    if not selected and args.build_tools is None:
        selected.append("opensbi-toolchain")

    rc = _smart_windows_preflight(args, selected)
    if rc != 0:
        return rc

    pm = _detect_package_manager()
    if args.standalone:
        log("preferring standalone/build-from-source binaries")
    elif pm:
        log(f"using package manager: {pm}")
    else:
        log("no package manager detected; using standalone/build-from-source fallbacks")

    rc = 0
    for name in selected:
        if _install_host_tool(name, pm, dry_run=args.dry_run, force=args.force,
                              prefer_standalone=args.standalone) != 0:
            rc = 1

    if args.build_tools is not None:
        build_tools = args.build_tools or list(_BUILD_TOOLS.keys())
        if _install_build_tools_selected(build_tools, pm, dry_run=args.dry_run, force=args.force) != 0:
            rc = 1

    return rc


# ---------------------------------------------------------------------- doctor ---

def cmd_doctor(args: argparse.Namespace) -> int:
    root = package_root()
    rows: list[tuple[str, str, str]] = []

    def probe(name: str, exe: str | None, version_args: list[str] | None = None,
              note: str = "") -> None:
        if not exe:
            rows.append((name, "MISSING", note))
            return
        ver = ""
        if version_args:
            try:
                # WSL tools are reported as "wsl <cmd>"; run them through wsl.
                cmd = ["wsl", exe[4:]] if isinstance(exe, str) and exe.startswith("wsl ") else [exe]
                out = subprocess.run([*cmd, *version_args], capture_output=True,
                                     text=True, timeout=20)
                ver = (out.stdout or out.stderr).strip().splitlines()[0][:60]
            except Exception:  # noqa: BLE001 - a probe must never raise
                ver = "(version probe failed)"
        rows.append((name, "ok", ver or exe))

    probe("python", sys.executable, ["--version"])
    probe("cargo", resolve_cargo(), ["--version"],
          note="run `g6q setup` for a contained toolchain")
    probe("git", shutil.which("git"), ["--version"])
    # Optional, only needed by later stages.
    probe("qemu-system-riscv64", _which_host("qemu-system-riscv64"), ["--version"],
          note="optional; run `g6q setup-host --qemu` to install")
    probe("dtc", _which_host("dtc"), ["--version"],
          note="optional; run `g6q setup-host --dtc` to install")
    probe("spike", _which_host("spike"), None,
          note="optional; run `g6q setup-host --spike` for build instructions")
    probe("wsl", shutil.which("wsl"), ["--version"],
          note="optional; on Windows `fw build` uses WSL for OpenSBI")
    cross = _probe_riscv_cross()
    probe("riscv cross-toolchain", cross[0] if cross else None,
          note=f"needed to build OpenSBI; run `g6q setup-host --toolchain` ({cross[1] if cross else 'none found'})")

    width = max(len(r[0]) for r in rows)
    print(f"[g6q] package root: {root}")
    for name, state, extra in rows:
        flag = "  " if state == "ok" else "! "
        print(f"{flag}{name.ljust(width)}  {state:<8} {extra}")

    missing_required = [r for r in rows if r[1] != "ok" and r[0] in ("python", "cargo")]
    if missing_required:
        err("required tooling missing; run `python tools/g6q.py setup`")
        return 1
    return 0


# ------------------------------------------------------------- build/test/check ---

def _cargo(args_list: list[str], *, check: bool = True) -> int:
    cargo = require_cargo()
    res = run([cargo, *args_list], cwd=package_root(), env=apply_env(), check=False)
    if check and res.returncode != 0:
        raise SystemExit(res.returncode)
    return res.returncode


def cmd_build(args: argparse.Namespace) -> int:
    extra = ["--release"] if args.release else []
    return _cargo(["build", "--workspace", *extra])


def cmd_test(args: argparse.Namespace) -> int:
    return _cargo(["test", "--workspace"])


def cmd_check(args: argparse.Namespace) -> int:
    """The green command."""
    steps: list[tuple[str, callable]] = [
        ("independence", lambda: _python([str(_TOOLS / "check_independence.py")])),
        ("independence selftest", lambda: _python([str(_TOOLS / "check_independence.py"), "--selftest"])),
        ("flist selftest", lambda: _python([str(_TOOLS / "flist_expand.py"), "--selftest"])),
        ("bridge selftest", lambda: _python([str(_TOOLS / "ai_tensor_bridge.py"), "selftest"])),
        ("fmt", lambda: _cargo(["fmt", "--all", "--check"], check=False)),
        ("clippy", lambda: _cargo(
            ["clippy", "--workspace", "--all-targets", "--", "-D", "warnings"], check=False)),
        ("test", lambda: _cargo(["test", "--workspace"], check=False)),
    ]
    failed: list[str] = []
    for name, fn in steps:
        log(f"--- {name} ---")
        rc = fn()
        if rc != 0:
            failed.append(name)
            if not args.keep_going:
                break
    if failed:
        err(f"check FAILED: {', '.join(failed)}")
        return 1
    log("check OK")
    return 0


def _python(argv: list[str]) -> int:
    res = run([sys.executable, *argv], cwd=package_root(), check=False)
    return res.returncode


# ------------------------------------------------------------------ run / cargo ---

def _extract_fw_options(rest: list[str]) -> list[str]:
    """Pull out the options shared by `fw fetch`/`fw build` and `run`."""
    opts: list[str] = []
    i = 0
    single = {
        "--fw-src", "--fw-mode", "--fw-platform", "--fw-text-start", "--fw-out",
        "--fw-fdt", "--fw-payload", "--fw-jump-addr", "--cross-compile", "--target",
        "--repo-root", "--dts",
    }
    repeatable = {"--fw-make", "--dts-overlay", "--dts-set", "--dts-del"}
    while i < len(rest):
        opt = rest[i]
        if opt in single:
            opts.append(opt)
            if i + 1 < len(rest) and not rest[i + 1].startswith("-"):
                opts.append(rest[i + 1])
                i += 1
        elif opt in repeatable:
            opts.append(opt)
            if i + 1 < len(rest) and not rest[i + 1].startswith("-"):
                opts.append(rest[i + 1])
                i += 1
        i += 1
    return opts


def cmd_run(args: argparse.Namespace) -> int:
    rest = list(args.rest)
    if "--build-fw" in rest:
        rest.remove("--build-fw")
        dry_run = "--dry-run" in rest
        if dry_run:
            rest.remove("--dry-run")
        fw_opts = _extract_fw_options(rest)
        if dry_run:
            fw_opts.append("--dry-run")
        rc = _fw_cli(["fw", "fetch", *fw_opts])
        if rc != 0:
            return rc
        rc = _fw_cli(["fw", "build", *fw_opts])
        if rc != 0:
            return rc
        if dry_run:
            rest.append("--dry-run")
    return _cargo(["run", "-p", "g6q-cli", "--", "run", *rest])


def cmd_cargo(args: argparse.Namespace) -> int:
    return _cargo(list(args.rest))


def cmd_flist(args: argparse.Namespace) -> int:
    return _python([str(_TOOLS / "flist_expand.py"), *args.rest])


def cmd_env(args: argparse.Namespace) -> int:
    env = apply_env()
    for key in ("RUSTUP_HOME", "CARGO_HOME", "PATH"):
        print(f"{key}={env.get(key, '')}")
    print(f"PACKAGE_ROOT={package_root()}")
    print(f"TOOLCHAIN={toolchain_channel()}")
    print(f"CARGO={resolve_cargo() or '(none)'}")
    return 0


# ------------------------------------------------------------------ fetch-qemu ---

def _pins_qemu() -> tuple[str, str]:
    """Read the [qemu] url and ref from pins.toml without an external TOML parser."""
    path = package_root() / "pins.toml"
    if not path.is_file():
        raise RuntimeError("pins.toml not found")
    text = path.read_text(encoding="utf-8")
    in_qemu = False
    url: str | None = None
    ref: str | None = None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_qemu = s[1:-1] == "qemu"
            continue
        if in_qemu and "=" in s:
            key, _, value = s.partition("=")
            key = key.strip()
            value = value.split("#", 1)[0].strip()
            value = value.strip('"').strip("'")
            if key == "url":
                url = value
            elif key == "ref":
                ref = value
    if not url or not ref:
        raise RuntimeError("pins.toml [qemu] section missing url or ref")
    return url, ref


def cmd_fetch_qemu(args: argparse.Namespace) -> int:
    git = shutil.which("git")
    if not git:
        err("git not found on PATH; cannot fetch QEMU")
        return 1
    qemu_dir = package_root() / "qemu"
    url, ref = _pins_qemu()
    url = args.url or url
    ref = args.ref or ref
    log(f"QEMU source pin: {ref} from {url}")

    if args.dry_run:
        log("dry-run: would clone/fetch and check out:")
        log(f"  git clone --branch {ref}{' --depth 1' if not args.full else ''} {url} {qemu_dir}")
        if qemu_dir.joinpath(".git").is_dir():
            log(f"  (existing {qemu_dir} would be updated)")
        log(f"  git -C {qemu_dir} checkout -f {ref}")
        log(f"  write {qemu_dir / '.g6lc_qemu_pin'} with ref + url")
        return 0

    if qemu_dir.joinpath(".git").is_dir():
        log(f"fetching into existing {qemu_dir}")
        run([git, "-C", qemu_dir, "fetch", "origin", ref], check=False)
    else:
        qemu_dir.mkdir(parents=True, exist_ok=True)
        log(f"cloning {url} into {qemu_dir}")
        # Clone with the right ref checked out immediately; depth 1 keeps the
        # first fetch fast.  A later full fetch is one command away if needed.
        clone_args = [git, "clone", "--branch", ref]
        if not args.full:
            clone_args += ["--depth", "1"]
        clone_args += ["--", url, str(qemu_dir)]
        res = run(clone_args, check=False)
        if res.returncode != 0:
            err("clone failed; if the ref is not a tag, use --full or a full clone manually")
            return res.returncode

    # Make sure the requested ref is actually checked out.
    res = run([git, "-C", qemu_dir, "checkout", "-f", ref], check=False)
    if res.returncode != 0:
        err(f"could not check out {ref}")
        return res.returncode

    # Record the pin so the workspace can see which source revision is being used.
    (qemu_dir / ".g6lc_qemu_pin").write_text(f"{ref}\n{url}\n", encoding="utf-8")
    log(f"QEMU ready at {qemu_dir} on ref {ref}")
    return 0


# ------------------------------------------------------------------ build-qemu ---

def _which_or_none(name: str) -> str | None:
    found = shutil.which(name)
    return found


def cmd_build_qemu(args: argparse.Namespace) -> int:
    qemu_dir = package_root() / "qemu"
    if not qemu_dir.joinpath(".git").is_dir():
        err("qemu/ is not present; run `python tools/g6q.py fetch-qemu` first")
        return 1

    build_dir = qemu_dir / "build"
    if args.clean and build_dir.exists():
        if args.dry_run:
            log(f"dry-run: would remove {build_dir}")
        else:
            log(f"removing {build_dir}")
            shutil.rmtree(build_dir, ignore_errors=True)

    python = _which_or_none("python3") or _which_or_none("python") or "python"
    bash = _which_or_none("bash") or "bash"
    ninja = _which_or_none("ninja") or _which_or_none("ninja-build") or "ninja"

    configure = qemu_dir / "configure"
    configure_cmd: list[str]
    # Out-of-tree build: run from qemu/build with ../configure.
    configure_args = f"--target-list={args.target}"
    # VDUSE/vhost-user subprojects create symlinks in the build tree. On Windows
    # filesystems accessed through WSL these symlinks often fail, so disable them
    # by default; they are not needed for the riscv64-softmmu boot gate.
    configure_args += " --disable-libvduse --disable-vduse-blk-export"
    configure_args += " --disable-vhost-user --disable-vhost-user-blk-server"
    if args.slirp:
        # libslirp gives us the 'user' netdev backend that B0 virtio-net wiring
        # expects. It is a meson wrap, so this is an opt-in fetch.
        configure_args += " --enable-slirp"
    if args.debug:
        configure_args += " --enable-debug"
    if args.mingw:
        configure_args += " --cross-prefix= --enable-mingw-w64"
    if _WINDOWS:
        # WSL/Cygwin bash cannot directly consume a Windows absolute path; run
        # configure through bash from the build directory.
        configure_cmd = [bash, "-c", f"../configure {configure_args}"]
    else:
        configure_cmd = [str(configure), *configure_args.split()]

    if args.dry_run:
        log("dry-run: would configure and build:")
        log(f"  cd {build_dir}")
        log(f"  mkdir -p {build_dir}")
        log(f"  {' '.join(configure_cmd)}")
        log(f"  {ninja}")
        if not args.configure_only:
            log(f"  {ninja} -C {build_dir} contrib-plugins")
        return 0

    if python == "python":
        err("python not found on PATH; cannot configure QEMU")
        return 1
    if _WINDOWS and bash == "bash":
        err("bash not found on PATH; QEMU configure is a POSIX script")
        return 1
    if ninja == "ninja":
        err("ninja not found on PATH; cannot build QEMU")
        return 1

    build_dir.mkdir(parents=True, exist_ok=True)
    res = run(configure_cmd, cwd=build_dir, check=False)
    if res.returncode != 0:
        err("QEMU configure failed")
        return res.returncode

    if args.configure_only:
        log(f"QEMU configured in {build_dir}")
        return 0

    if _WINDOWS:
        build_cmd = [bash, "-c", "ninja"]
    else:
        build_cmd = [ninja]
    res = run(build_cmd, cwd=build_dir, check=False)
    if res.returncode != 0:
        err("QEMU build failed")
        return res.returncode

    log(f"QEMU built in {build_dir}")
    return 0


# --------------------------------------------------------------------- fetch-fw ---

def _fw_cli(argv: list[str]) -> int:
    """Invoke `g6lc-qemu` through cargo run."""
    return _cargo(["run", "-p", "g6q-cli", "--", *argv], check=False)


def cmd_fetch_fw(args: argparse.Namespace) -> int:
    fw_args = ["fw", "fetch"]
    if args.fw_src:
        fw_args += ["--fw-src", args.fw_src]
    if args.dry_run:
        fw_args += ["--dry-run"]
    return _fw_cli(fw_args)


# ---------------------------------------------------------------------- build-fw ---

def cmd_build_fw(args: argparse.Namespace) -> int:
    fw_args = ["fw", "build"]
    if args.fw_src:
        fw_args += ["--fw-src", args.fw_src]
    if args.fw_mode:
        fw_args += ["--fw-mode", args.fw_mode]
    if args.fw_platform:
        fw_args += ["--fw-platform", args.fw_platform]
    if args.fw_text_start:
        fw_args += ["--fw-text-start", args.fw_text_start]
    if args.fw_out:
        fw_args += ["--fw-out", args.fw_out]
    if args.cross_compile:
        fw_args += ["--cross-compile", args.cross_compile]
    for make in args.fw_make:
        fw_args += ["--fw-make", make]
    if args.fw_fdt:
        fw_args += ["--fw-fdt", args.fw_fdt]
    if args.fw_payload:
        fw_args += ["--fw-payload", args.fw_payload]
    if args.fw_jump_addr:
        fw_args += ["--fw-jump-addr", args.fw_jump_addr]
    if args.target:
        fw_args += ["--target", args.target]
    if args.repo_root:
        fw_args += ["--repo-root", args.repo_root]
    if args.dts:
        fw_args += ["--dts", args.dts]
    for o in args.dts_overlay:
        fw_args += ["--dts-overlay", o]
    for s in args.dts_set:
        fw_args += ["--dts-set", s]
    for d in args.dts_del:
        fw_args += ["--dts-del", d]
    if args.dry_run:
        fw_args += ["--dry-run"]
    return _fw_cli(fw_args)


# ----------------------------------------------------------------- install-qemu ---

def _find_target_id(out_dir: Path) -> str | None:
    for d in out_dir.iterdir():
        if d.is_dir() and (d / "build").is_dir():
            wiring = list((d / "build").glob("build-wiring-*.txt"))
            if wiring:
                return d.name
    return None


def _wiring_sections(text: str) -> dict[str, str]:
    """Parse build-wiring-*.txt into {target_file: append_block}."""
    sections: dict[str, list[str]] = {}
    current: str | None = None
    header = re.compile(r"#\s*\d+\.\s*Append to\s+([^\s(]+(?:/[^\s(]+)*)")
    for line in text.splitlines():
        m = header.match(line)
        if m:
            current = m.group(1).strip()
            sections[current] = []
        elif current is not None:
            if line.startswith("#"):
                # Next prose section (e.g. "# 5. Plugin build wiring").
                m2 = header.match(line)
                if m2:
                    current = m2.group(1).strip()
                    sections[current] = []
                else:
                    current = None
            else:
                sections[current].append(line)
    return {p: "\n".join(lines).strip() for p, lines in sections.items() if lines}


def _add_contrib_plugin(qemu_dir: Path, target_id: str, suffix: str = "") -> None:
    """Ensure the generated plugin is listed in contrib/plugins/meson.build."""
    path = qemu_dir / "contrib" / "plugins" / "meson.build"
    if not path.is_file():
        return
    text = path.read_text(encoding="utf-8")
    # The emitted plugin file uses the C-sanitised target id (e.g. 'ai-soc' -> 'ai_soc').
    safe_id = target_id.replace('-', '_').replace('.', '_')
    name = f"g6lc-{safe_id}{suffix}"
    if name in text:
        log(f"already present in {path}: {name}")
        return
    # Insert before the 'if get_option('plugins')' block so the list is grown
    # before the foreach loop consumes it.
    marker = "if get_option('plugins')"
    if marker in text:
        before, sep, after = text.partition(marker)
        text = before + f"contrib_plugins += '{name}'\n\n" + sep + after
    else:
        text = text.rstrip() + f"\n\ncontrib_plugins += '{name}'\n"
    with path.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    log(f"added {name} to {path}")


def _is_repo_root(pkg: Path) -> bool:
    return (pkg / "core" / "include").is_dir() or (pkg / "core").is_dir()


def _find_one(pkg: Path, pattern: str) -> Path | None:
    found = sorted(pkg.glob(pattern))
    found = [p for p in found if not p.name.lower().startswith("manifest-nested")]
    return found[0] if found else None


def _gen_command(
    gen_bin: Path,
    pkg: Path,
    target: str | None,
    dts_overlay: str | None,
    machine: str | None = None,
    virtio_mmio: str | None = None,
) -> list[str]:
    if _is_repo_root(pkg):
        cmd = [str(gen_bin), "gen", "--emit", "qemu", "--repo-root", str(pkg)]
        if target:
            cmd.extend(["--target", target])
        if dts_overlay:
            cmd.extend(["--dts-overlay", dts_overlay])
        if machine:
            cmd.extend(["--machine", machine])
        if virtio_mmio:
            cmd.extend(["--virtio-mmio", virtio_mmio])
        return cmd

    cfg = _find_one(pkg, "*_config_pkg.sv")
    if not cfg:
        raise ValueError(f"no *_config_pkg.sv in {pkg}")
    flist = _find_one(pkg, "*.f")
    if not flist:
        raise ValueError(f"no flist in {pkg}")
    dts = _find_one(pkg, "*.dts")
    if not dts:
        raise ValueError(f"no .dts in {pkg}")
    resolved_target = target or cfg.stem.removesuffix("_config_pkg").removesuffix("_cfg_pkg")
    cmd = [
        str(gen_bin),
        "gen",
        "--emit",
        "qemu",
        "--config-pkg",
        str(cfg),
        "--flist",
        str(flist),
        "--dts",
        str(dts),
        "--target",
        resolved_target,
    ]
    if dts_overlay:
        cmd.extend(["--dts-overlay", dts_overlay])
    if machine:
        cmd.extend(["--machine", machine])
    if virtio_mmio:
        cmd.extend(["--virtio-mmio", virtio_mmio])
    return cmd


def cmd_install_qemu(args: argparse.Namespace) -> int:
    qemu_dir = package_root() / "qemu"
    if not qemu_dir.joinpath(".git").is_dir():
        err("qemu/ is not present; run `python tools/g6q.py fetch-qemu` first")
        return 1

    pkg = Path(args.package)
    if not pkg.is_dir():
        err(f"package is not a directory: {pkg}")
        return 1
    pkg = pkg.resolve()

    out_dir = package_root() / "out" / "emit"
    if out_dir.exists():
        shutil.rmtree(out_dir, ignore_errors=True)

    # Build the generator and emit B1/B2 sources.
    if not args.dry_run:
        res = _cargo(["build", "-p", "g6q-cli"])
        if res != 0:
            return res

    try:
        gen_cmd = _gen_command(
            package_root() / "target" / "debug" / "g6lc-qemu",
            pkg,
            args.target,
            args.dts_overlay,
            args.machine,
            args.virtio_mmio,
        )
    except ValueError as e:
        err(str(e))
        return 1

    if args.dry_run:
        log(f"dry-run: would run: {' '.join(gen_cmd)}")
        log("dry-run: would copy generated sources from out/emit/<target>/ to qemu/")
        log("dry-run: would append build-wiring fragments to qemu/hw/riscv/Kconfig, default-configs, meson.build")
        log("dry-run: plugin wiring requires manual edit of qemu/contrib/plugins/meson.build")
        return 0

    gen_bin = package_root() / "target" / "debug" / "g6lc-qemu"
    res = run(gen_cmd, check=False, capture_output=True, text=True)
    if res.returncode != 0:
        err(f"generation failed: {res.stderr}")
        return res.returncode

    target_id = _find_target_id(out_dir)
    if not target_id:
        err("could not find an emitted target under out/emit/")
        return 1
    emit_dir = out_dir / target_id

    # Copy generated source/headers into the QEMU tree.
    source_map = {
        emit_dir / "contrib/plugins": qemu_dir / "contrib/plugins",
        emit_dir / "hw/riscv": qemu_dir / "hw/riscv",
        emit_dir / "target/riscv": qemu_dir / "target/riscv",
    }
    for src_dir, dst_dir in source_map.items():
        if not src_dir.is_dir():
            continue
        dst_dir.mkdir(parents=True, exist_ok=True)
        for f in src_dir.iterdir():
            if f.is_file():
                if args.dry_run:
                    log(f"dry-run: would copy {f} -> {dst_dir / f.name}")
                else:
                    shutil.copy2(f, dst_dir / f.name)
                    log(f"copied {dst_dir / f.name}")

    # Apply build-wiring appends.
    wiring_files = list((emit_dir / "build").glob("build-wiring-*.txt"))
    if not wiring_files:
        if not args.dry_run:
            err("no build-wiring file found")
            return 1
        log("dry-run: no build-wiring file to parse")
        return 0
    wiring_text = wiring_files[0].read_text(encoding="utf-8")
    for rel_path, block in _wiring_sections(wiring_text).items():
        target_path = qemu_dir / rel_path
        if not target_path.is_file():
            err(f"QEMU file not found: {target_path}")
            continue
        if args.dry_run:
            log(f"dry-run: would append to {target_path}:\n{block}")
            continue
        existing = target_path.read_text(encoding="utf-8")
        if block in existing:
            log(f"already present in {target_path}: {block.splitlines()[0]}")
        else:
            with target_path.open("a", encoding="utf-8", newline="\n") as f:
                if existing and not existing.endswith("\n"):
                    f.write("\n")
                f.write("\n" + block + "\n")
            log(f"appended to {target_path}")

    if not args.dry_run:
        _add_contrib_plugin(qemu_dir, target_id)
        _add_contrib_plugin(qemu_dir, target_id, suffix="-pmu")
        with (qemu_dir / ".g6lc_qemu_install").open(
                "w", encoding="utf-8", newline="\n") as f:
            f.write(f"target: {target_id}\npackage: {args.package}\n")
        log(f"installed g6lc machine ({target_id}) into {qemu_dir}")
    return 0


# ----------------------------------------------------------------------- clean ---

def cmd_remote(args: argparse.Namespace) -> int:
    remote = package_root() / "tools" / "g6q_remote.py"
    rest = list(getattr(args, "rest", None) or [])
    if rest and rest[0] == "--":
        rest = rest[1:]
    cmd = [sys.executable, str(remote), *rest]
    return subprocess.run(cmd).returncode


def cmd_remote_build(args: argparse.Namespace) -> int:
    remote = package_root() / "tools" / "g6q_remote.py"
    rest = list(getattr(args, "rest", None) or [])
    if rest and rest[0] == "--":
        rest = rest[1:]
    cmd = [sys.executable, str(remote), "remote-build", *rest]
    return subprocess.run(cmd).returncode


def cmd_bridge(args: argparse.Namespace) -> int:
    """Thin wrapper to `tools/ai_tensor_bridge.py`."""
    return _python([str(_TOOLS / "ai_tensor_bridge.py"), *args.rest])


def cmd_clean(args: argparse.Namespace) -> int:
    victims = [target_dir(), out_dir()]
    if args.all:
        victims.append(tools_dir())
    for v in victims:
        if v.exists():
            log(f"removing {v}")
            shutil.rmtree(v, ignore_errors=True)
        else:
            log(f"absent    {v}")
    if args.all:
        log("removed .tools/ — run `python tools/g6q.py setup` before building again")
    return 0


# ------------------------------------------------------------------------- main ---

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="g6q", description="g6lc_qemu package automation (primary entry point).")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("setup", help="install a contained rustup/cargo under .tools/")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_setup)

    p = sub.add_parser("setup-riscv", help="install the pinned xPack RISC-V cross-toolchain under .tools/")
    p.add_argument("--ref", default=None, help="override the pinned toolchain release")
    p.add_argument("--force", action="store_true",
                   help="reinstall even if the toolchain is already present")
    p.add_argument("--dry-run", action="store_true",
                   help="print the download/extract plan and exit")
    p.set_defaults(fn=cmd_setup_riscv)

    p = sub.add_parser("setup-host", help="auto-install host tools using the detected package manager")
    p.add_argument("--toolchain", action="store_true", help="install the OpenSBI PIE toolchain")
    p.add_argument("--qemu", action="store_true", help="install qemu-system-riscv64")
    p.add_argument("--dtc", action="store_true", help="install the device-tree compiler")
    p.add_argument("--spike", action="store_true", help="show how to build Spike (no packaged build)")
    p.add_argument("--all", action="store_true", help="install all supported host tools")
    p.add_argument("--build-tools", nargs="*", default=None, metavar="TOOL",
                   help="install build tools (meson, ninja, cmake, bison, flex, make); "
                        "with no args, install all of them")
    p.add_argument("--standalone", action="store_true",
                   help="prefer standalone binary downloads over the package manager")
    p.add_argument("--force", action="store_true", help="reinstall even if already present")
    p.add_argument("--yes", "-y", action="store_true",
                   help="non-interactive: automatically install missing platform dependencies")
    p.add_argument("--vs-year", type=int, default=2022, choices=(2022, 2025, 2026),
                   help="Visual Studio / Build Tools year for Windows auto-install (default 2022)")
    p.add_argument("--dry-run", action="store_true", help="print the install plan and exit")
    p.set_defaults(fn=cmd_setup_host)

    p = sub.add_parser("doctor", help="probe host tooling")
    p.set_defaults(fn=cmd_doctor)

    p = sub.add_parser("build", help="cargo build --workspace")
    p.add_argument("--release", action="store_true")
    p.set_defaults(fn=cmd_build)

    p = sub.add_parser("test", help="cargo test --workspace")
    p.set_defaults(fn=cmd_test)

    p = sub.add_parser("check", help="GREEN: independence + fmt + clippy + test")
    p.add_argument("--keep-going", "-k", action="store_true",
                   help="run every step even after a failure")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("run", help="cargo run -p g6q-cli -- ...")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_run)

    p = sub.add_parser("cargo", help="raw cargo with the contained toolchain")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_cargo)

    p = sub.add_parser("flist", help="generic filelist expander")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_flist)

    p = sub.add_parser("env", help="print the contained-toolchain environment")
    p.set_defaults(fn=cmd_env)

    p = sub.add_parser("fetch-qemu", help="fetch the pinned QEMU source into qemu/")
    p.add_argument("--url", default=None, help="override the QEMU git URL from pins.toml")
    p.add_argument("--ref", default=None, help="override the QEMU ref from pins.toml")
    p.add_argument("--full", action="store_true", help="full clone instead of a shallow one")
    p.add_argument("--dry-run", action="store_true", help="print what would be run and exit")
    p.set_defaults(fn=cmd_fetch_qemu)

    p = sub.add_parser("build-qemu", help="configure and build the fetched QEMU source")
    p.add_argument("--target", default="riscv64-softmmu",
                   help="QEMU target list (default: riscv64-softmmu)")
    p.add_argument("--debug", action="store_true", help="pass --enable-debug to configure")
    p.add_argument("--slirp", action="store_true",
                   help="enable libslirp user-mode networking (requires network during configure)")
    p.add_argument("--mingw", action="store_true", help="hint a MinGW cross build")
    p.add_argument("--configure-only", action="store_true", help="configure, do not build")
    p.add_argument("--clean", action="store_true", help="remove the build directory first")
    p.add_argument("--dry-run", action="store_true",
                   help="print the configure/build commands and exit")
    p.set_defaults(fn=cmd_build_qemu)

    p = sub.add_parser("install-qemu", help="install generated B1/B2 sources into qemu/")
    p.add_argument("--package", default="fixtures/mini",
                   help="package directory to generate from (default: fixtures/mini)")
    p.add_argument("--target", default=None,
                   help="override the emitted target id")
    p.add_argument("--machine", default=None,
                   help="machine profile: g6lc-soc (default) or g6lc-virt")
    p.add_argument("--virtio-mmio", default=None,
                   help="number of virtio-mmio transports (g6lc-virt defaults to 8)")
    p.add_argument("--dts-overlay", default=None,
                   help="overlay .dts to apply before generation")
    p.add_argument("--dry-run", action="store_true",
                   help="print what would be copied/appended and exit")
    p.set_defaults(fn=cmd_install_qemu)

    p = sub.add_parser("bridge", help="host AI-tensor bridge (forwards to tools/ai_tensor_bridge.py)")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_bridge)

    p = sub.add_parser("fetch-fw", help="fetch the pinned OpenSBI firmware source into out/fw-src/")
    p.add_argument("--fw-src", default=None, help="source directory (default: out/fw-src/opensbi)")
    p.add_argument("--dry-run", action="store_true", help="print the planned clone command and exit")
    p.set_defaults(fn=cmd_fetch_fw)

    p = sub.add_parser("build-fw", help="build the fetched OpenSBI firmware")
    p.add_argument("--fw-src", default=None, help="source directory (default: out/fw-src/opensbi)")
    p.add_argument("--fw-mode", default=None, help="dynamic, jump, or payload (default: dynamic)")
    p.add_argument("--fw-platform", default=None, help="OpenSBI platform (default: generic)")
    p.add_argument("--fw-text-start", default=None, help="firmware link address (default: from pins.toml)")
    p.add_argument("--fw-out", default=None, help="output directory for built firmware (default: out/fw)")
    p.add_argument("--fw-make", action="append", default=[], help="extra VAR=VAL passed to make (repeatable)")
    p.add_argument("--fw-fdt", default=None, help="DTB path to embed (or 'auto' to generate from the resolved model)")
    p.add_argument("--fw-payload", default=None, help="kernel/payload for payload mode")
    p.add_argument("--fw-jump-addr", default=None, help="jump address for jump mode")
    p.add_argument("--cross-compile", default=None, help="toolchain prefix (default: CROSS_COMPILE env)")
    # Model resolution options, needed when --fw-fdt auto is requested.
    p.add_argument("--target", default=None, help="target id for model-driven DTB generation")
    p.add_argument("--repo-root", default=None, help="design root to search for config/flist/dts")
    p.add_argument("--dts", default=None, help="explicit device-tree source for --fw-fdt auto")
    p.add_argument("--dts-overlay", action="append", default=[], help="overlay .dts to apply before --fw-fdt auto")
    p.add_argument("--dts-set", action="append", default=[], help="PATH=VALUE DDT mutation for --fw-fdt auto")
    p.add_argument("--dts-del", action="append", default=[], help="PATH DDT property deletion for --fw-fdt auto")
    p.add_argument("--dry-run", action="store_true", help="print the planned make command and exit")
    p.set_defaults(fn=cmd_build_fw)

    p = sub.add_parser("remote", help="remote QEMU build/test proxy (forward to tools/g6q_remote.py)")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_remote)

    p = sub.add_parser("remote-build", help="convenience: sync, configure, build, pull, and optional smoke test on the remote builder")
    p.add_argument("rest", nargs=argparse.REMAINDER)
    p.set_defaults(fn=cmd_remote_build)

    p = sub.add_parser("clean", help="remove target/ and out/")
    p.add_argument("--all", action="store_true", help="also remove .tools/")
    p.set_defaults(fn=cmd_clean)

    args = ap.parse_args(argv)
    # `run`/`cargo`/`flist` accept a leading `--`; argparse leaves it in REMAINDER.
    rest = getattr(args, "rest", None)
    if rest and rest and rest[0] == "--":
        args.rest = rest[1:]
    try:
        return int(args.fn(args) or 0)
    except SystemExit as exc:
        return int(exc.code or 0)
    except KeyboardInterrupt:
        err("interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
