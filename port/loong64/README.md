# Rayburst for LoongArch64

把 [AnInsomniacy/rayburst](https://github.com/AnInsomniacy/rayburst) (Tauri 2 +
Vue 3 + Rust) 移植到 **loongarch64 / Deepin 25** 的可复现构建配方。

上游只发布 6 个桌面目标的二进制（macOS x64/arm64、Windows x64/arm64、Linux
x64/arm64），其中 `aria2-next` sidecar 是仓库里直接 check-in 的预编译 ELF。
本配方不改业务代码，用「本地工具链 + 最小补丁 + 旁路打包」的方式让同一棵
源码树在龙芯上编译出可安装的 `.deb` 与 Arch Linux `.pkg.tar.zst`。

> **本仓库布局**：`acdcGGE/rayburst-loong64` 的 `main` 分支保持上游源码不变；
> 移植配方放在 **`port/loong64` 分支的 `port/loong64/` 目录**。也可以把本目录
> 单独复制出去当作独立配方仓库使用（见下）。

## 前置条件

| 项 | 要求 |
| --- | --- |
| CPU / OS | loongarch64，Deepin 25 / glibc >= 2.38（本机已验证 2.38） |
| Rust | rustup 工具链 >= 1.90（本机用 `1.93.0-loongarch64-unknown-linux-gnu`） |
| Node | >= 22.13（**apt 只有 20**，见下） |
| CMake | >= 3.25、Ninja、Perl、GCC C++20 |
| 系统包 | WebKitGTK 4.1 等开发头文件（一次性 `sudo apt install`，本机已装齐） |
| 打包工具 | `bsdtar`(libarchive) + `zstd` + `gzip`；本机 3.7.4 / 1.5.7 已具备 |
| 磁盘 | 约 4 GiB（aria2-next 全量 superbuild + Rust target） |

## 快速开始

脚本按下面的目录推断路径，可用 `SRC` / `ENGINE_SRC` / `WORKSPACE` 环境变量覆盖：

```
workspace/
├── rayburst/            # git clone https://github.com/AnInsomniacy/rayburst
├── aria2-next/          # 04-engine.sh 会自动 clone
├── rayburst-loong64/    # 本配方目录（独立使用时）
└── .toolchain/          # 用户态 Node / pnpm / cargo-tauri，不污染系统
```

**方式 A — 在本 fork 的 `port/loong64` 分支里**（仓库根本身就是 rayburst 源码树，
`03-frontend.sh` 的补丁直接作用于它）：

```bash
git clone -b port/loong64 https://github.com/acdcGGE/rayburst-loong64.git
cd rayburst-loong64/port/loong64
export SRC="$(cd ../.. && pwd)"       # 指向仓库根
./scripts/build-all.sh
```

**方式 B — 独立配方仓库**（工作区结构如上，把本目录单独 clone 到
`rayburst-loong64/`，再 `git clone` 上游 rayburst 到 `rayburst/`）。

系统开发头文件（唯一需要 root 的一步，会连运行时库一起装齐）：

```bash
sudo apt-get update && sudo apt-get install -y \
  libwebkit2gtk-4.1-dev libgtk-3-dev libsoup-3.0-dev \
  libayatana-appindicator3-dev librsvg2-dev \
  patchelf xdg-utils dpkg-dev
```

```bash
# 环境体检（输出结构化 JSON，用来对比另一台龙芯机器）
python3 tools/probe.py

# 全流程（04 的 aria2-next superbuild 最慢，3A5000 上约 1~2 小时）
./scripts/build-all.sh

# 只想验证前端 / 单独跑某一步
./scripts/03-frontend.sh
./scripts/04-engine.sh --fallback    # 用系统 aria2c 占位（功能降级，见 PORTING.md）
./scripts/06-package-deb.sh          # 产出 dist/rayburst_<ver>_loong64.deb
./scripts/07-package-arch.sh        # 产出 dist/rayburst-<pkgver>-1-loong64.pkg.tar.zst
```

产物：`dist/rayburst_<version>_loong64.deb`（90 MiB）与
`dist/rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst`（120 MiB），两者 payload 字节级一致。

## 脚本

| 脚本 | 作用 |
| --- | --- |
| `tools/probe.py` | 无第三方依赖的环境/耦合探测 → `report/probe.json` |
| `scripts/00-system-deps.sh` | 只读检查 pkg-config 模块，缺则打印 sudo 命令（**不自动提权**） |
| `scripts/01-toolchain.sh` | 用户态安装 [loong64/node](https://github.com/loong64/node) 24 + pnpm 11.5.2 |
| `scripts/02-tauri-cli.sh` | 从 crates.io 编译原生 `cargo-tauri`，注入 `node_modules/.bin/tauri` shim |
| `scripts/03-frontend.sh` | `pnpm install` + native-messaging launcher + vite 构建 |
| `scripts/04-engine.sh` | 编译 aria2-next 并安装成 `aria2-next-loongarch64-unknown-linux-gnu` |
| `scripts/05-build.sh` | `cargo-tauri build --no-bundle`（**必须** `--no-bundle`） |
| `scripts/06-package-deb.sh` | 按 tauri-bundler 的布局手工生成 `Architecture: loong64` 的 deb |
| `scripts/07-package-arch.sh` | 复用同一 stage，生成带 `.PKGINFO` / `.MTREE` 的 pacman 包 |
| `arch/PKGBUILD` | 给 Loong Arch Linux 维护者用 `makepkg` 重建的等价模板（本机未实跑） |
| `scripts/build-all.sh` | 串行执行以上全部，产出 deb + `.pkg.tar.zst` |

## Arch Linux 包（Loong Arch Linux）

`07-package-arch.sh` 复用 `06-package-deb.sh` 的 `dist/deb-stage/`，所以 deb 与
`.pkg.tar.zst` 的 payload **字节级一致**（实测 13 个文件 sha256 全部相同）。

| 项 | 值 | 依据 |
| --- | --- | --- |
| 文件名 | `rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst` | Arch `pkgver` 不允许连字符：上游 `4.1.2-beta.2` → `4.1.2_beta.2`；`pkgrel=1` |
| 架构 | `loong64` | Loong Arch Linux 的 pacman 把 `uname -m=loongarch64` 映射为 CARCH `loong64` |
| 元数据 | `.PKGINFO` + `.MTREE`（gzip 的 mtree） | 与 makepkg 相同的字段与 mtree 关键字集 |
| `.BUILDINFO` | 不生成 | 它描述 PKGBUILD 构建环境；本配方归档已编译产物，pacman 不要求此文件 |
| 属主 / 权限 | root:root；目录 755、文件 644、3 个可执行文件 755 | `bsdtar --uid 0 --gid 0`，mtree 与归档一致 |

在 Loong Arch Linux 上安装：

```bash
sudo pacman -U rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst
```

`depend` 默认 `webkit2gtk-4.1 gtk3 libsoup3 librsvg libglvnd hicolor-icon-theme`，
按 `ldd` 主程序的直接依赖映射。托盘走 Rust `ksni`/D-Bus，不链接
`libayatana-appindicator`，所以与 deb 的 `Depends` 不同。移植仓库包名有差异时覆盖：

```bash
ARCH_DEPENDS="webkit2gtk-4.1 gtk3 libsoup3 ..." ./scripts/07-package-arch.sh
```

## 为什么需要这些补丁

| 阻塞 | 原因 | 解法 |
| --- | --- | --- |
| Node 22 | pnpm 11 import `node:sqlite`；apt 源只有 Node 20；Node.js 官方无 `linux-loong64` 包 | 用龙芯官方预编译包，校验 SHA256 后解到 `.toolchain` |
| `@tauri-apps/cli` | 11 个平台原生包里没有 loong64，npm shim 抛 `Cannot find native binding` | `cargo install tauri-cli --locked` + shim |
| pnpm cpu 白名单 | `pnpm-workspace.yaml` 把 `supportedArchitectures.cpu` 写死 `[x64, arm64]`，pnpm 跳过 loong64 原生包，vite 报 `Cannot find module @rollup/rollup-linux-loong64-gnu` | `patches/rayburst-pnpm-workspace-loong64.patch` + 全新 install |
| Rust MSRV | tauri-cli 2.12.2 要求 rustc >= 1.90，默认 1.87 直接拒绝 | `RUSTUP_TOOLCHAIN=1.93.0` |
| aria2-next | OpenSSL target 对非 x86/arm 一律兜底 `linux-x86_64` | `patches/aria2-next-loongarch64-openssl.patch` |
| sidecar | `externalBin` 按 target triple 找文件，上游只带 6 个 | 本地编译并放成 `binaries/aria2-next-<triple>` |
| deb 打包 | tauri-bundler 2.10.2 的 `Arch` 枚举无 LoongArch64，`binary_arch()` 直接 panic | `--no-bundle` + 自建 deb |

完整的证据、验证记录和未解决风险见 **[PORTING.md](PORTING.md)**。

## 许可

本仓库的脚本与文档可自由使用。上游 Rayburst 为 MIT；aria2-next 为 GPLv2，
重新分发其编译产物时遵守对应许可证。
