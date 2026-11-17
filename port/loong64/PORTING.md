# Rayburst → LoongArch64 移植分析

日期：2026-11-06 · 目标机 `Linux deepin-loong 6.18.48-loong64-desktop-rolling` / `loongarch64` / Deepin 25 (crimson) / glibc 2.38 / 4 核 15 GiB。

上游 rayburst 是 Tauri 2 / Vue 3 / Rust 桌面下载器，只发布 6 个桌面目标；本机为龙芯 Deepin，「移植」按**在本机从源码编译出可安装的 loong64 包**处理。工具链探测与耦合点清单对其它语言/框架的移植同样适用。

## 1. 环境基线（实测）

```
uname -m                          loongarch64
rustc --print host-tuple          loongarch64-unknown-linux-gnu
glibc                             2.38-6deepin30
rustup toolchains                 1.80.0 / 1.85.0 / 1.87.0(默认) / 1.93.0
apt nodejs                        20.15.1+dfsg-1（唯一可用版本）
cmake / ninja / perl              3.31.4 / 1.12.1 / 5.36.0
pkg-config (webkit2gtk-4.1 等 5 项)  移植前全部缺失，操作者已装齐 45 个包
```

Rust 的 loongarch64 target 完整存在（`target-list` 里有 5 个 loongarch 变体），**CPU 架构本身不是障碍**，障碍全在发行侧预编译产物与工具链版本。

## 2. 平台耦合点清单

| # | 耦合点 | 证据 | 后果 | 处置 |
|---|---|---|---|---|
| 1 | `externalBin` sidecar | `tauri.conf.json` 声明 `binaries/aria2-next` 等；`binaries/` 内 6 个 16–19 MiB 预编译 ELF/PE/Mach-O | 按 `<name>-<host triple>` 找 `aria2-next-loongarch64-unknown-linux-gnu`，缺失即构建失败 | 本地编译 aria2-next；launcher 由项目脚本生成 |
| 2 | Node / pnpm | `packageManager: pnpm@11.5.2`；pnpm 在 Node 20 抛 `ERR_UNKNOWN_BUILTIN_MODULE: node:sqlite`；`engines` 要求 `>=22.13` | 前端依赖装不上 | 龙芯官方 Node 24.22.2 loong64 预编译包（SHA256 校验） |
| 3 | `@tauri-apps/cli` 原生包 | 11 个 optionalDependencies 变体无 loong64；`tauri --version` → `Cannot find native binding` | `pnpm tauri dev/build` 不可用 | `cargo install tauri-cli --version 2.12.2 --locked` + shim |
| 4 | **pnpm cpu 白名单** | `pnpm-workspace.yaml` `supportedArchitectures.cpu: [x64, arm64]`；lockfile 里明明有 `@rollup/rollup-linux-loong64-gnu@4.59.0` | `pnpm build` 在 vue-tsc 后抛 `Cannot find module @rollup/rollup-linux-loong64-gnu` | 补丁加 `loong64`，并**删除 node_modules 重装** |
| 5 | Rust MSRV | `cargo install tauri-cli@2.12.2` on 1.87 → `requires rustc 1.90 or newer` | 默认工具链拒绝 | `RUSTUP_TOOLCHAIN=1.93.0` |
| 6 | WebKitGTK 开发头文件 | `webkit2gtk = "=2.0.2"`、`gtk = 0.18`、`ksni`、`gio`；5 个关键 `.pc` 与 3 个运行时库全缺 | 链接失败；装出的 deb 也跑不起来 | `00-system-deps.sh` 检查 + 一次性 `apt install` |
| 7 | aria2-next OpenSSL target | `Dependencies.cmake:121-125` 只识别 `arm64\|aarch64`，其余落到 `linux-x86_64`；vendored OpenSSL 的 `10-main.conf:834` 已有 `linux64-loongarch64` | Configure 生成 x86_64 汇编，龙芯汇编器无法处理 | 加 5 行 loong64 分支（见 3.1） |
| 8 | tauri-bundler deb/rpm | `settings.rs` 的 `Arch` 无 LoongArch64，`binary_arch()` else 分支 `panic!`；`debian.rs`/`rpm.rs` 返回 `Unsupported architecture` | `tauri build` 打包阶段 panic | `--no-bundle` + `06-package-deb.sh` 自建 deb |
| 9 | updater | `tauri.conf.json` 指向 GitHub Releases `latest.json`，上游无 loong64 产物 | 自动更新拿到不兼容包 | 发布时覆盖配置 / 独立渠道 |
| 10 | WebKit 渲染假设 | `webkit.rs` 默认软件渲染（`WEBKIT_SKIA_ENABLE_CPU_RENDERING`、`LIBGL_ALWAYS_SOFTWARE`），运行时 `dlsym` 关闭 `UseDamagingInformationForCompositing` | 龙芯 GPU/驱动行为差异 | 保持上游默认，移植层不改 |

**没发现的东西**：全仓库无 SIMD intrinsic、无内联汇编、无 `#[cfg(target_arch)]` 分支；Rust 依赖均架构无关（`rusqlite` 用 `bundled` 编译 C 源码，`reqwest` 用 `rustls`）。这是移植能收敛成「工具链 + 两个旁路」的根本原因。

### 原生 npm 包：lockfile 有，但被白名单挡住

lockfile 已解析好 loong64 变体（`@esbuild/linux-loong64@0.25.12`、`@rollup/rollup-linux-loong64-gnu@4.59.0` / `-musl`），但 `supportedArchitectures.cpu` 让 pnpm 11 在安装时把它们过滤掉。`pnpm install --frozen-lockfile` 会「成功」，直到 `pnpm build` 里 vite 加载 rollup 时才炸：

```
Error: Cannot find module @rollup/rollup-linux-loong64-gnu
 at requireWithFriendlyError (.../rollup/dist/native.js:115:9)
```

因此 vite / rollup / esbuild **不需要重编译**，只需解除白名单。另一个坑：pnpm 把 optional 依赖集合缓存在 `node_modules/.modules.yaml`，在已有安装树上改 `supportedArchitectures` 后再 install（即使 `--force` / `--no-frozen-lockfile`）仍报 `Already up to date`，必须删 `node_modules` 重装。`scripts/03-frontend.sh` 已自动处理。

## 3. 关键补丁

**3.1 aria2-next**（`patches/aria2-next-loongarch64-openssl.patch`，已应用到 OpenSSL 编译通过）

```cmake
 elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
   set(ARIA2_OPENSSL_TARGET linux-aarch64)
+elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(loongarch64|loong64)$")
+  set(ARIA2_OPENSSL_TARGET linux64-loongarch64)
 else()
   set(ARIA2_OPENSSL_TARGET linux-x86_64)
 endif()
```

验证：`cmake --preset default` 后 `build.ninja:440` 变为 `perl .../openssl/Configure linux64-loongarch64 no-shared ...`。无副作用的架构分支，可直接提上游。其余依赖（Boost header-only、curl、FFmpeg、GPAC、libtorrent、SQLite…）都是通用源码编译；`Media.cmake` 只在交叉编译时传 `--arch`，本机原生不触发。

**3.2 pnpm 白名单**（`patches/rayburst-pnpm-workspace-loong64.patch`，已应用并验证重装生效）：`cpu` 列表加一行 `- loong64`。纯构建配置，可无副作用提上游。验证：删 `node_modules` 重装后出现 `node_modules/.pnpm/@rollup+rollup-linux-loong64-gnu@4.59.0`。

**3.3 tauri-bundler**（v2.10.2，本地不改，建议提上游）

| 文件 | 改动 |
|---|---|
| `settings.rs:792` | `Arch` 枚举加 `LoongArch64` |
| `settings.rs:1035` | `binary_arch()` 加 `else if target.starts_with("loongarch64")` |
| `linux/debian.rs:47` | `Arch::LoongArch64 => "loong64"`（Debian 系用 `loong64`） |
| `linux/rpm.rs:28` | `Arch::LoongArch64 => "loongarch64"`（RPM 系用全称） |

不 patch registry 源码（劫持独立安装的 tauri-cli 需改 `cargo install` 依赖解析，得不偿失），改为复刻其目录约定自行打 deb。`--no-bundle` 安全：`build.rs:132` 的 `if !options.no_bundle` 是进入 bundler 的唯一入口，`binary_arch()`/`Arch` 只在 debian/rpm 的 bundle 阶段被调用。

已核对的 `debian.rs::generate_data()` 布局：`/usr/bin/rayburst`、`/usr/bin/aria2-next` 与 `rayburst-browser-launcher`（去掉 `-<triple>` 后缀）、`/usr/lib/Rayburst/<resources>`、`/usr/share/applications/rayburst.desktop`、`/usr/share/icons/hicolor/<size>/apps/rayburst.png`。

## 4. 实跑验证记录

| 步骤 | 结果 |
|---|---|
| Node 24 loong64 | ✅ `v24.22.2`，npm `11.19.1`；pnpm `11.5.2` 用户态安装 |
| `pnpm install`（首次 2m54s） | ✅ 依赖就位，但**未装** loong64 原生包 |
| `pnpm build`（第一次） | ❌ `Cannot find module @rollup/...loong64-gnu` → 暴露白名单问题 |
| 打补丁 + 删 node_modules 重装（35s） | ✅ rollup / esbuild 的 loong64 包到位 |
| `pnpm build`（修复后 13m14s） | ✅ `dist/index.html` + 全量 assets（vite 阶段 5m3s，仅 >500 kB chunk 常规警告） |
| `cargo install tauri-cli@2.12.2`（Rust 1.93，68 min） | ✅ 37 MiB loong64 原生，复跑命中缓存 |
| `pnpm build:native-launcher` | ✅ 699 KiB launcher |
| aria2-next `cmake --preset` / superbuild `-j4` | ✅ 11 个依赖 + 引擎完成；`aria2-next --version` 3.0.10，LoongArch PIE 379 MiB（未 strip） |
| Rust 主程序 + 真实 deb（增量 12m53s） | ✅ `rayburst` 43 MiB，`ldd` 无缺失库；`rayburst_4.1.2-beta.2_loong64.deb` 90 MiB，`Architecture: loong64`，布局与 tauri-bundler 一致 |
| `07-package-arch.sh`（21s） | ✅ `rayburst-4.1.2_beta.2-1-loong64.pkg.tar.zst` 120 MiB；33 个条目全部 root:root 755/644 |
| 真实 pacman 校验 | ✅ `-Qip` 字段正确、`-Qlp` 31 项、`-Qkp` 31/31 无缺失；与 deb 的 13 个 payload sha256 全同 |

**Arch 包三处格式适配**：① 版本 `4.1.2-beta.2` 的 `-` 在 `pkgver` 非法 → `4.1.2_beta.2`；② 架构取 Loong Arch Linux 的 `pacman-use-loong64.patch` 映射值 `loong64`；③ 依赖名换 Arch 官方名（`libwebkit2gtk-4.1-0` → `webkit2gtk-4.1`），只列 `ldd` 可见直接依赖，去掉 `libayatana-appindicator3-1`（`ksni` 走 D-Bus 不链接）。`.PKGINFO` 必需，`.MTREE` 用 makepkg 同款关键字集（`!all,use-set,type,uid,gid,mode,time,size,link,sha256digest`）并 gzip，`.BUILDINFO` 有意省略（pacman 不要求）。

校验证据来自实跑：从 Loong Arch Linux 镜像取官方 `pacman 7.1.0 / libalpm 16.0.1` loong64 二进制，补齐 libgpgme / libassuan、用系统 `libgpg-error` 绕开本机 glibc 2.38 < 2.42 的差异；另有 `zstd -t` 通过、解包后与 deb-stage sha256 逐个一致、三个 ELF 均为 LoongArch PIE。

结构化结果：`python3 tools/probe.py` → `report/probe.json`；包尺寸 / SHA256 → `report/packages.json`；45 个系统包分组 → `report/dependencies.json`。长时编译只需跑一次，产物留在 `.toolchain/` 与 `aria2-next/build/`，后续 `build-all.sh` 命中缓存。

## 5. 降级路径（可选）

`scripts/04-engine.sh --fallback` 把系统 `aria2c 1.37.0` 复制成 `aria2-next-loongarch64-unknown-linux-gnu`，让 UI 先起来验证界面：

| 能力 | aria2-next | 系统 aria2c 1.37 |
|---|---|---|
| HTTP/HTTPS、BT/magnet、JSON-RPC 基本接口 | ✅ | ✅ |
| 原生 ED2K / Kad、HLS/DASH | ✅ | ❌ |
| `--state-dir` 崩溃续传、SQLite 状态 | ✅ | ❌（`.aria2` 控制文件） |
| engine RPC 扩展、会话/进度语义 | ✅ | ❌ 部分不兼容 |
| Metalink 3、XML-RPC | 部分 | ✅ |

即**只适合验证 UI，不是可用的下载器**。

## 6. 未解决 / 需确认

1. **运行期行为未验证**：龙芯桌面会话里的托盘、updater、deep-link 与 WebKitGTK 软件渲染，属运行期范围（编译/链接已走标准系统路径，45 个开发包与 `ldconfig` 就位）。
2. **aria2-next 体积**：4 核 3A5000 上 superbuild 约 1–2 小时，产物链接 vendored 依赖、未 strip 时 379 MiB（上游预编译 sidecar 约 18 MiB），发布前建议 `strip` 或加 `-s`。
3. **分发**：deb 的 `Depends` 按 Deepin 25 包名写死、Arch 包按 Arch 官方包名写死；换发行版需改 `06-package-deb.sh` 或设 `ARCH_DEPENDS`。Arch 包未在真实 Loong Arch Linux 上 `pacman -U` 实装（本机是 Deepin），仅用其官方 pacman/libalpm 完成 `-Qip/-Qlp/-Qkp` 校验。
4. **上游同步**：补丁基于 rayburst 4.1.2-beta.2 / tauri-cli 2.12.2 / tauri-bundler 2.10.2 / aria2-next 3.0.10，升级后重跑 `probe.py` 对比。

## 7. 结论

**不需要改任何业务代码**，只需两个上游可接受的构建配置补丁（`pnpm-workspace.yaml` 加一行 `loong64`；aria2-next 的 OpenSSL target 加 5 行分支）。其余是补三块发行侧缺口——Node/pnpm 的 loong64 运行时、原生 tauri-cli、aria2-next sidecar——并绕过 tauri-bundler 不认识 LoongArch64 的限制（`--no-bundle` + 手工打 deb 与 `.pkg.tar.zst`）。唯一需要 root 的是 `apt install` 装 WebKitGTK 开发包（已完成）；之后 `./scripts/build-all.sh` 即可端到端产出两种安装包。未验证的只剩龙芯桌面会话里的运行期行为。
