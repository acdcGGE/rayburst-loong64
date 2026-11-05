#!/usr/bin/env python3
"""rayburst loongarch64 port: environment / coupling probe.

No third-party dependencies. Collects machine facts and emits a structured
report so the port recipe can be reproduced (and diffed) on another LoongArch
box.

Usage:
  python3 tools/probe.py [--src ../rayburst] [--engine-src ../aria2-next]
                         [--out report/probe.json] [--quiet]
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PORT_ROOT = Path(__file__).resolve().parent.parent

TRIPLE = "loongarch64-unknown-linux-gnu"

# pkg-config modules the Tauri/wry Linux backend needs to *compile* against.
PKG_MODULES = [
    "webkit2gtk-4.1",
    "javascriptcoregtk-4.1",
    "gtk+-3.0",
    "libsoup-3.0",
    "ayatana-appindicator3-0.1",
    "librsvg-2.0",
]

TOOLS = [
    "node", "npm", "pnpm", "rustc", "cargo", "rustup", "gcc", "g++",
    "pkg-config", "cmake", "ninja", "make", "perl", "git", "curl",
    "patchelf", "dpkg-deb", "ar",
]


def run(cmd: list[str], timeout: int = 20) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out = (p.stdout + p.stderr).strip()
        return p.returncode, out
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, str(exc)


def first_line(text: str) -> str:
    return text.splitlines()[0].strip() if text.strip() else ""


def tool_versions() -> dict:
    result = {}
    for name in TOOLS:
        path = shutil.which(name)
        entry = {"path": path, "version": None}
        if path:
            rc, out = run([name, "--version"])
            if rc != 0 or not out:
                rc, out = run([name, "-v"])
            entry["version"] = first_line(out) or None
        result[name] = entry
    return result


def pkg_modules() -> dict:
    result = {}
    for module in PKG_MODULES:
        rc, out = run(["pkg-config", "--modversion", module])
        result[module] = {"found": rc == 0, "version": first_line(out) if rc == 0 else None}
    return result


def os_info() -> dict:
    info = {}
    os_release = Path("/etc/os-release")
    if os_release.exists():
        for line in os_release.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                info[k] = v.strip().strip('"')
    _, ldd = run(["ldd", "--version"])
    info["glibc"] = first_line(ldd)
    info["kernel"] = platform.release()
    info["machine"] = platform.machine()
    info["python"] = platform.python_version()
    return info


def rust_info() -> dict:
    result = {"host_tuple": None, "toolchains": [], "installed_targets": [], "targets_with_loongarch": []}
    _, host = run(["rustc", "--print", "host-tuple"])
    result["host_tuple"] = first_line(host) or None
    _, tl = run(["rustup", "toolchain", "list"])
    result["toolchains"] = [line.split(" ")[0].strip() for line in tl.splitlines() if line.strip()]
    _, it = run(["rustup", "target", "list", "--installed"])
    result["installed_targets"] = [line.strip() for line in it.splitlines() if line.strip()]
    _, targets = run(["rustc", "--print", "target-list"])
    result["targets_with_loongarch"] = [
        line.strip() for line in targets.splitlines() if "loongarch" in line
    ]
    return result


def inspect_sources(src: Path, engine_src: Path) -> dict:
    out: dict = {"rayburst": {"path": str(src), "exists": src.is_dir()},
                 "aria2_next": {"path": str(engine_src), "exists": engine_src.is_dir()}}
    if src.is_dir():
        conf = src / "src-tauri" / "tauri.conf.json"
        pkg = src / "package.json"
        if conf.exists():
            data = json.loads(conf.read_text())
            out["rayburst"]["externalBin"] = data.get("bundle", {}).get("externalBin", [])
            out["rayburst"]["bundle_targets"] = data.get("bundle", {}).get("targets")
        if pkg.exists():
            data = json.loads(pkg.read_text())
            out["rayburst"]["packageManager"] = data.get("packageManager")
            out["rayburst"]["version"] = data.get("version")
        bins = sorted(p.name for p in (src / "src-tauri" / "binaries").glob("aria2-next-*")) \
            if (src / "src-tauri" / "binaries").is_dir() else []
        out["rayburst"]["shipped_sidecars"] = bins
        out["rayburst"]["loong64_sidecar_present"] = any(TRIPLE in b for b in bins)
        gen = sorted(p.name for p in (src / "src-tauri" / "generated-binaries").iterdir()) \
            if (src / "src-tauri" / "generated-binaries").is_dir() else []
        out["rayburst"]["generated_binaries"] = gen
        out["rayburst"]["lockfile_version"] = (src / "pnpm-lock.yaml").read_text().splitlines()[0] \
            if (src / "pnpm-lock.yaml").exists() else None
        ws = src / "pnpm-workspace.yaml"
        if ws.exists():
            text = ws.read_text()
            out["rayburst"]["supportedArchitectures_cpu"] = (
                text.split("cpu:", 1)[1].strip().splitlines()[:6] if "cpu:" in text else []
            )
            out["rayburst"]["loong64_cpu_allowed"] = bool(
                re.search(r"^\s*-\s*loong64\s*$", text, re.M)
            )
            out["rayburst"]["loong64_native_pkgs_installed"] = sorted(
                p.name for p in (src / "node_modules" / ".pnpm").glob(
                    "*rollup-linux-loong64*") if p.is_dir()
            ) if (src / "node_modules" / ".pnpm").is_dir() else []
        out["rayburst"]["dist_built"] = (src / "dist" / "index.html").exists()
        out["rayburst"]["node_modules_present"] = (src / "node_modules").is_dir()
    if engine_src.is_dir():
        out["aria2_next"]["third_party"] = sorted(
            p.name for p in (engine_src / "third_party").iterdir() if p.is_dir()
        ) if (engine_src / "third_party").is_dir() else []
        dep = engine_src / "cmake" / "superbuild" / "Dependencies.cmake"
        if dep.exists():
            text = dep.read_text()
            out["aria2_next"]["openssl_targets"] = sorted(set(
                line.strip() for line in text.splitlines() if "ARIA2_OPENSSL_TARGET" in line and "set(" in line
            ))
            out["aria2_next"]["loongarch_branch_present"] = "linux64-loongarch64" in text
        out["aria2_next"]["configured"] = (engine_src / "build" / "default" / "build.ninja").exists()
    return out


def npm_native_support() -> dict:
    """Which platform-specific npm binaries exist upstream for this architecture."""
    # Verified against npm registry on 2026-11-05 for the pinned versions.
    return {
        "@tauri-apps/cli": {
            "loong64_variant": False,
            "known_variants": ["linux-x64-gnu", "linux-x64-musl", "linux-arm64-gnu",
                               "linux-arm64-musl", "linux-arm-gnueabihf",
                               "linux-riscv64-gnu", "darwin-x64", "darwin-arm64",
                               "win32-x64-msvc", "win32-ia32-msvc", "win32-arm64-msvc"],
            "workaround": "cargo install tauri-cli --version 2.12.2 --locked",
        },
        "@esbuild/linux-loong64": {"loong64_variant": True, "version": "0.25.12"},
        "@rollup/rollup-linux-loong64-gnu": {"loong64_variant": True, "version": "4.59.0"},
    }


def build_gaps(report: dict) -> list[dict]:
    tools = report["toolchain"]
    rust = report["rust"]
    pkgs = report["pkg_config"]
    src = report["sources"]["rayburst"]
    eng = report["sources"]["aria2_next"]

    def node_major(entry) -> int:
        v = (entry.get("version") or "").lstrip("v")
        try:
            return int(v.split(".")[0])
        except ValueError:
            return 0

    gaps = []

    npm_node = tools.get("node", {})
    pnpm = tools.get("pnpm", {})
    gaps.append({
        "id": "node>=22.13-for-pnpm11",
        "severity": "blocker",
        "status": "resolved" if node_major(npm_node) >= 22 and pnpm.get("path") else "open",
        "evidence": f"system node={npm_node.get('version')}, pnpm={pnpm.get('version')}, "
                    f"packageManager={src.get('packageManager')}",
        "remedy": "install loong64/node userland toolchain (scripts/01-toolchain.sh)",
        "detail": "pnpm 11 requires node:sqlite (Node >= 22.13); apt on Deepin 25 ships Node 20 only",
    })
    cargo_tauri = PORT_ROOT.parent / ".toolchain" / "cargo-root" / "bin" / "cargo-tauri"
    shim = Path(src.get("path", "")) / "node_modules" / ".bin" / "tauri"
    cli_worked_around = cargo_tauri.is_file() and shim.is_file()
    installed_native = src.get("loong64_native_pkgs_installed", [])
    gaps.append({
        "id": "pnpm-supportedArchitectures-cpu",
        "severity": "blocker",
        "status": "resolved" if src.get("loong64_cpu_allowed") and installed_native else "open",
        "evidence": f"pnpm-workspace.yaml cpu={src.get('supportedArchitectures_cpu')}; "
                    f"installed loong64 native pkgs={installed_native}; "
                    "vite build fails with 'Cannot find module @rollup/rollup-linux-loong64-gnu' otherwise",
        "remedy": "git apply patches/rayburst-pnpm-workspace-loong64.patch, "
                  "then re-run pnpm install (a fresh install / lockfile re-resolution may be needed)",
    })
    gaps.append({
        "id": "tauri-cli-native-binary",
        "severity": "blocker",
        "status": "resolved" if cli_worked_around else "open",
        "resolution": "workaround" if cli_worked_around else None,
        "evidence": "@tauri-apps/cli 2.12.2 optionalDependencies has no loong64 variant; "
                    f"local cargo-tauri={'present' if cargo_tauri.is_file() else 'absent'}, "
                    f"shim={'present' if shim.is_file() else 'absent'}",
        "remedy": "build tauri-cli from crates.io with cargo +1.93.0, shim node_modules/.bin/tauri",
    })
    rustc = tools.get("rustc", {}).get("version") or ""
    try:
        active = float(".".join(rustc.split()[1].split(".")[:2])) if "rustc" in rustc else 0.0
    except (IndexError, ValueError):
        active = 0.0
    gaps.append({
        "id": "rustc>=1.90-for-tauri-cli-2.12",
        "severity": "blocker",
        "status": "resolved" if any(t.startswith("1.9") for t in rust["toolchains"]) else "open",
        "evidence": f"active rustc={rustc}; toolchains={rust['toolchains']}; "
                    f"tauri-cli 2.12.2 requires rustc >= 1.90 (1.11.5 supports 1.77.2)",
        "remedy": "use `cargo +1.93.0` / rustup override for the port",
    })
    missing = [k for k, v in pkgs.items() if not v["found"]]
    gaps.append({
        "id": "webkit2gtk-dev-headers",
        "severity": "blocker",
        "status": "open" if missing else "resolved",
        "evidence": f"missing pkg-config modules: {missing}; apt simulation requires 45 packages",
        "remedy": "sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev "
                  "libayatana-appindicator3-dev librsvg2-dev patchelf xdg-utils",
    })
    gaps.append({
        "id": "aria2-next-loong64-sidecar",
        "severity": "blocker",
        "status": "resolved" if src.get("loong64_sidecar_present") else "open",
        "evidence": f"shipped sidecars={src.get('shipped_sidecars')}; "
                    f"tauri needs binaries/aria2-next-{TRIPLE}",
        "remedy": "build aria2-next superbuild with patches/aria2-next-loongarch64-openssl.patch",
    })
    gaps.append({
        "id": "aria2-next-openssl-target",
        "severity": "blocker",
        "status": "resolved" if eng.get("loongarch_branch_present") else "open",
        "evidence": "cmake/superbuild/Dependencies.cmake falls back to linux-x86_64 for "
                    "CMAKE_SYSTEM_PROCESSOR=loongarch64; OpenSSL 3.5.6 provides linux64-loongarch64",
        "remedy": "git apply patches/aria2-next-loongarch64-openssl.patch",
    })
    deb_ready = list((PORT_ROOT / "dist").glob("*_loong64.deb"))
    gaps.append({
        "id": "tauri-bundler-deb-arch",
        "severity": "blocker",
        "status": "resolved" if deb_ready else "open",
        "resolution": "workaround" if deb_ready else None,
        "evidence": "tauri-bundler 2.10.2 Arch enum has no LoongArch64; binary_arch() "
                    "panics on loongarch64-*; debian.rs/rpm.rs reject the target",
        "remedy": "build with --no-bundle and create the .deb with scripts/06-package-deb.sh "
                  "(Architecture: loong64). Upstream patch is documented in PORTING.md",
    })
    gaps.append({
        "id": "updater-endpoints",
        "severity": "warning",
        "status": "open",
        "evidence": "tauri.conf.json updater endpoint points at upstream releases which have "
                    "no loong64 artifacts",
        "remedy": "ship a loong64-specific config with createUpdaterArtifacts=false / "
                  "disable updater, or host a separate channel",
    })
    return gaps


def augment_path() -> None:
    """Make the userland toolchain visible so the report reflects what the
    port scripts actually built, not just the bare apt baseline."""
    tc = PORT_ROOT.parent / ".toolchain"
    extra = []
    extra.extend(str(p / "bin") for p in sorted(tc.glob("node-v*-linux-loong64")) if p.is_dir())
    extra.extend([str(tc / "cargo-root" / "bin"),
                  str(tc / "pnpm" / "node_modules" / ".bin")])
    os.environ["PATH"] = os.pathsep.join([p for p in extra if Path(p).is_dir()] +
                                         [os.environ.get("PATH", "")])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(PORT_ROOT.parent / "rayburst"))
    ap.add_argument("--engine-src", default=str(PORT_ROOT.parent / "aria2-next"))
    ap.add_argument("--out", default=str(PORT_ROOT / "report" / "probe.json"))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    augment_path()

    _, eff = run(["rustup", "run", "1.93.0", "rustc", "--version"])

    report = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "target_triple": TRIPLE,
        "rustc_used_by_build_scripts": first_line(eff) or None,
        "os": os_info(),
        "toolchain": tool_versions(),
        "rust": rust_info(),
        "pkg_config": pkg_modules(),
        "native_support": npm_native_support(),
        "sources": inspect_sources(Path(args.src), Path(args.engine_src)),
    }
    report["gaps"] = build_gaps(report)
    report["summary"] = {
        "blockers_open": sum(1 for g in report["gaps"]
                             if g["severity"] == "blocker" and g["status"] == "open"),
        "blockers_resolved": sum(1 for g in report["gaps"]
                                 if g["severity"] == "blocker" and g["status"] == "resolved"),
        "warnings": sum(1 for g in report["gaps"] if g["severity"] == "warning"),
    }

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    if not args.quiet:
        print(f"target      : {report['target_triple']}")
        print(f"os          : {report['os'].get('PRETTY_NAME')} / {report['os'].get('glibc')}")
        print(f"node        : {report['toolchain']['node']['version']}")
        print(f"rustc       : {report['toolchain']['rustc']['version']}")
        print("pkg-config  : " + ", ".join(
            f"{k}={'OK' if v['found'] else 'MISSING'}" for k, v in report["pkg_config"].items()))
        print("\ngaps:")
        for g in report["gaps"]:
            mark = {"resolved": "[x]", "open": "[ ]"}[g["status"]]
            print(f"  {mark} {g['severity']:<8} {g['id']}")
        print(f"\nreport -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
