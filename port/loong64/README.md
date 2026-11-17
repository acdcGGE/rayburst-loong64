# Rayburst for LoongArch64

把 [AnInsomniacy/rayburst](https://github.com/AnInsomniacy/rayburst)（Tauri 2 + Vue 3 + Rust）移植到 **loongarch64 / Deepin 25** 的可复现构建配方。

上游只发布 6 个桌面目标二进制（macOS / Windows / Linux 各 x64+arm64），`aria2-next` sidecar 是仓库里 check-in 的预编译 ELF。本配方不改业务代码，用「本地工具链 + 最小补丁 + 旁路打包」让同一棵源码树在龙芯上产出可安装的 `.deb` 与 Arch Linux `.pkg.tar.zst`。

**仓库布局**：`acdcGGE/rayburst-loong64` 的 `main` 分支保持上游源码不变，配方在 **`port/loong64` 分支的 `port/loong64/` 目录**；也可把该目录单独复制出去当独立配方仓库用。

## 前置条件

| 项 | 要求 |
|---|---|
| CPU / OS | loongarch64，Deepin 25 / glibc ≥ 2.38（本机已验证 2.38） |
| Rust | rustup ≥ 1.90（本机 `1.93.0-loongarch64-unknown-linux-gnu`） |
| Node | ≥ 22.13（**apt 只有 20**，见下） |
| 构建 | CMake ≥ 3.25、Ninja、Perl、GCC C++20 |
| 系统包 | WebKitGTK 4.1 等开发头文件（一次性 `sudo apt install`） |
| 打包 | `bsdtar`(libarchive) + `zstd` + `gzip`（本机 3.7.4 / 1.5.7） |
| 磁盘 | 约 4 GiB（aria2-next superbuild + Rust target） |

## 快速开始

```
workspace/
├── rayburst/          # git clone https://github.com/AnInsomniacy/rayburst
├── aria2-next/        # 04-engine.sh 自动 clone
├── rayburst-loong64/  # 本配方目录（独立使用时）
└── .toolchain/        # 用户态 Node / pnpm / cargo-tauri，不污染系统
```

路径自动推断，可用 `SRC` / `ENGINE_SRC` / `WORKSPACE` 覆盖。

**方式 A — 在本 fork 的 `port/loong64` 分支里**（仓库根即源码树，补丁直接作用于它）：

```bash
git clone -b port/loong64 https://github.com/acdcGGE/rayburst-loong64.git
cd rayburst-loong64/port/loong64
export SRC="$(cd ../.. && pwd)"
./scripts/build-all.sh
```

**方式 B — 独立配方仓库**：按上面的工作区结构，把本目录 clone 到 `rayburst-loong64/`，再 clone 上游到 `rayburst/`。

系统开发头文件（唯一需要 root 的一步，连运行时库一起装齐）：

```bash
sudo apt-get update && sudo apt-get install -y \
  libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
  libayatana-appindicator3-dev librsvg2-dev \
  patchelf xdg-utils dpkg-dev
```

```bash
python3 tools/probe.py            # 环境体检 → report/probe.json
./scripts/build-all.sh            # 全流程（04 的 superbuild 最慢，3A5000 上约 1~2 小时）

# 单独跑某一步 / 只想验证前端
./scripts/03-frontend.sh
./scripts/04-engine.sh --fallback # 系统 aria2c 占位（功能降级，见 PORTING.md）
./scripts/06-package-deb.sh       # → dist/rayburst_<ver>_loong64.deb
./scripts/07-package-arch.sh      # → dist/rayburst-<pkgver>-1-loong64.pkg.tar.zst
```

产物：`dist/rayburst_<version>_loong64.deb`（90 MiB）与 `dist/rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst`（120 MiB），payload 字节级一致。

## 脚本

| 脚本 | 作用 |
|---|---|
| `tools/probe.py` | 无第三方依赖的环境/耦合探测 → `report/probe.json` |
| `00-system-deps.sh` | 只读检查 pkg-config 模块，缺则打印 sudo 命令（**不自动提权**） |
| `01-toolchain.sh` | 用户态安装 `loong64/node` 24 + pnpm 11.5.2 |
| `02-tauri-cli.sh` | 编译原生 `cargo-tauri`，注入 `node_modules/.bin/tauri` shim |
| `03-frontend.sh` | pnpm install + launcher + vite 构建 |
| `04-engine.sh` | 编译 aria2-next → `aria2-next-loongarch64-unknown-linux-gnu` |
| `05-build.sh` | `cargo-tauri build --no-bundle`（**必须** `--no-bundle`） |
| `06-package-deb.sh` | 按 tauri-bundler 布局生成 `Architecture: loong64` 的 deb |
| `07-package-arch.sh` | 复用同一 stage，生成带 `.PKGINFO` / `.MTREE` 的 pacman 包 |
| `arch/PKGBUILD` | 供 Loong Arch Linux 维护者 `makepkg` 重建的模板（本机未实跑） |
| `build-all.sh` | 串行执行全部，产出 deb + `.pkg.tar.zst` |

（脚本均在 `scripts/` 下。）

## Arch Linux 包

`07-package-arch.sh` 复用 `06-package-deb.sh` 的 `dist/deb-stage/`，两者 payload **字节级一致**（实测 13 个文件 sha256 全同）。

| 项 | 值 | 依据 |
|---|---|---|
| 文件名 | `rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst` | `pkgver` 不允许连字符：`4.1.2-beta.2` → `4.1.2_beta.2`，`pkgrel=1` |
| 架构 | `loong64` | Loong Arch Linux 的 pacman 把 `uname -m=loongarch64` 映射为 CARCH `loong64` |
| 元数据 | `.PKGINFO` + gzip 的 `.MTREE` | 与 makepkg 相同的字段与 mtree 关键字集 |
| `.BUILDINFO` | 不生成 | 它描述 PKGBUILD 构建环境；本配方归档已编译产物，pacman 不要求 |
| 属主/权限 | root:root；目录 755、文件 644、3 个可执行 755 | `bsdtar --uid 0 --gid 0`，mtree 与归档一致 |

```bash
sudo pacman -U rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst
```

`depend` 默认 `webkit2gtk-4.1 gtk3 libsoup3 librsvg libglvnd hicolor-icon-theme`，按主程序 `ldd` 的直接依赖映射。托盘走 Rust `ksni`/D-Bus、不链接 `libayatana-appindicator`，故与 deb 的 `Depends` 不同。包名有差异时用 `ARCH_DEPENDS="..." ./scripts/07-package-arch.sh` 覆盖。

## 为什么需要这些补丁

| 阻塞 | 解法 |
|---|---|
| Node 22：pnpm 11 import `node:sqlite`，apt 只有 20，Node.js 官方无 `linux-loong64` 包 | 龙芯官方预编译包，校验 SHA256 后解到 `.toolchain` |
| `@tauri-apps/cli` 11 个平台原生包无 loong64 → `Cannot find native binding` | `cargo install tauri-cli --locked` + shim |
| `supportedArchitectures.cpu` 写死 `[x64, arm64]`，vite 报 `Cannot find module @rollup/rollup-linux-loong64-gnu` | `patches/rayburst-pnpm-workspace-loong64.patch` + **全新 install** |
| tauri-cli 2.12.2 要求 rustc ≥ 1.90，默认 1.87 拒绝 | `RUSTUP_TOOLCHAIN=1.93.0` |
| aria2-next 的 OpenSSL target 对非 x86/arm 兜底 `linux-x86_64` | `patches/aria2-next-loongarch64-openssl.patch` |
| `externalBin` 按 target triple 找文件，上游只带 6 个 | 本地编译并放成 `binaries/aria2-next-<triple>` |
| tauri-bundler 2.10.2 的 `Arch` 无 LoongArch64，`binary_arch()` 直接 panic | `--no-bundle` + 自建 deb |

完整证据、验证记录与未解决风险见 **[PORTING.md](PORTING.md)**。

## 许可

本仓库脚本与文档可自由使用。上游 Rayburst 为 MIT；aria2-next 为 GPLv2，重新分发其编译产物时须遵守对应许可证。
