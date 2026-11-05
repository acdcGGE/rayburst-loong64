# Rayburst → LoongArch64 移植分析

日期：2026-11-06 · 目标机：`Linux deepin-loong 6.18.48-loong64-desktop-rolling`，
`loongarch64`，Deepin 25 (crimson)，glibc 2.38，4 核 / 15 GiB。

> **目标判定**：上游 rayburst 是 Tauri 2 / Vue 3 / Rust 桌面下载器，只发布 6 个
> 桌面目标。结合本机是龙芯 Deepin 且用户常做 loong64 本地编译，「移植」按
> **在本机从源码编译出可安装的 loong64 包** 处理。若实际意图是移植到别的
> 语言/框架，本文的工具链探测与耦合点清单仍然适用。

---

## 1. 环境基线（实测，非推测）

```
uname -m              loongarch64
rustc --print host-tuple   loongarch64-unknown-linux-gnu
glibc                 2.38-6deepin30
rustup toolchains     1.80.0 / 1.85.0 / 1.87.0(默认) / 1.93.0  (均为 loongarch64-unknown-linux-gnu)
apt nodejs            20.15.1+dfsg-1（唯一可用版本）
cmake / ninja / perl  3.31.4 / 1.12.1 / 5.36.0
pkg-config            webkit2gtk-4.1 / gtk+-3.0 / libsoup-3.0 / javascriptcoregtk-4.1：全部缺失
apt install 实际      操作者已装齐 WebKitGTK 开发链 45 个包；5 个 pkg-config 模块与运行时库全部就位
```

Rust 的 loongarch64 target 已完整存在（`rustc --print target-list` 里有 5 个
loongarch 变体），**CPU 架构本身不是障碍**。障碍全在发行侧的预编译产物与
工具链版本。

---

## 2. 平台耦合点清单

| # | 耦合点 | 证据（文件 / 命令） | 后果 | 处置 |
| --- | --- | --- | --- | --- |
| 1 | `externalBin` sidecar | `src-tauri/tauri.conf.json`: `["binaries/aria2-next", "generated-binaries/rayburst-browser-launcher"]`；`binaries/` 里 6 个 16–19 MiB 预编译 ELF/PE/Mach-O | Tauri 按 `<name>-<host triple>` 找 `aria2-next-loongarch64-unknown-linux-gnu`，缺失则构建失败 | 本地编译 aria2-next；launcher 由项目脚本自动生成 |
| 2 | Node / pnpm | `package.json`: `packageManager: pnpm@11.5.2`；实测 `pnpm 11.5.2` 在 Node 20 上抛 `ERR_UNKNOWN_BUILTIN_MODULE: node:sqlite`；`npm view pnpm@11.5.2 engines` → `>=22.13` | 前端依赖无法安装 | 龙芯官方 Node 24.22.2 loong64 预编译包（SHA256 校验） |
| 3 | `@tauri-apps/cli` 原生包 | `npm view @tauri-apps/cli@2.12.2 optionalDependencies` 共 11 个变体，无 loong64；实测 `./node_modules/.bin/tauri --version` → `Error: Cannot find native binding` | `pnpm tauri dev/build` 不可用 | `cargo install tauri-cli --version 2.12.2 --locked`，注入 shim |
| 4 | **pnpm cpu 白名单** | `pnpm-workspace.yaml:17-21` `supportedArchitectures.cpu: [x64, arm64]`；`pnpm-lock.yaml:642` 明明有 `@rollup/rollup-linux-loong64-gnu@4.59.0`（`cpu: [loong64]`, `libc: [glibc]`），但安装后 `node_modules/.pnpm` 里只有 x64/arm64 两个 | `pnpm build` 在 vue-tsc 之后抛 `Cannot find module @rollup/rollup-linux-loong64-gnu` | `patches/rayburst-pnpm-workspace-loong64.patch` 加 `loong64`；已存在的 node_modules 需删除重装（pnpm 把解析结果缓存在 `.modules.yaml`，改配置后仍报 `Already up to date`） |
| 5 | Rust MSRV | `cargo install tauri-cli@2.12.2` on 1.87 → `requires rustc 1.90 or newer` | 默认工具链直接拒绝 | `RUSTUP_TOOLCHAIN=1.93.0` |
| 6 | WebKitGTK 开发头文件 | `Cargo.toml`: `gtk = 0.18`、`webkit2gtk = "=2.0.2"`、`ksni`、`gio`；移植前 5 个关键 `.pc` 与 3 个运行时库全缺 | Rust 主程序链接失败；装出的 deb 也跑不起来 | `00-system-deps.sh` 检查 + 一次性 `sudo apt install`（操作者已完成） |
| 7 | aria2-next OpenSSL target | `cmake/superbuild/Dependencies.cmake:121-125` 只识别 `arm64|aarch64`，其余一律 `linux-x86_64`；vendored OpenSSL 3.5.6 的 `Configurations/10-main.conf:834` 其实已提供 `linux64-loongarch64` | OpenSSL Configure 生成 x86_64 汇编，龙芯汇编器无法处理 | `patches/aria2-next-loongarch64-openssl.patch` |
| 8 | tauri-bundler deb/rpm | `tauri-bundler-2.10.2/src/bundle/settings.rs:792` `Arch` 枚举无 LoongArch64；`:1035 binary_arch()` 的 else 分支 `panic!("Unexpected target triple")`；`debian.rs:47` / `rpm.rs:28` 的 match 均返回 `Unsupported architecture` | `tauri build` 在打包阶段 panic | `--no-bundle` + `06-package-deb.sh` 自建 deb |
| 9 | updater | `tauri.conf.json` → GitHub Releases 的 `latest.json`，上游无 loong64 产物 | 自动更新拿到不兼容包 | 发布时覆盖配置 / 独立渠道 |
| 10 | WebKit 渲染假设 | `src-tauri/src/webkit.rs`：默认软件渲染（`WEBKIT_SKIA_ENABLE_CPU_RENDERING`、`LIBGL_ALWAYS_SOFTWARE`），运行时 `dlsym` 关闭 `UseDamagingInformationForCompositing` | 龙芯 GPU/驱动行为差异 | 保持上游默认软件渲染路径，不在移植层改动 |

**没发现的东西**：全仓库无 SIMD intrinsic、无内联汇编、无 `#[cfg(target_arch = ...)]`
分支（`grep` 过 `src-tauri/src`、CMake、CI）。Rust 侧依赖均为架构无关 crate
（`rusqlite` 用 `bundled` 编译 SQLite C 源码，`reqwest` 用 `rustls`）。
这是本次移植能收敛成「工具链 + 两个旁路」的根本原因。

### 原生 npm 包：lockfile 有，但被白名单挡住

`pnpm-lock.yaml` 里确实已经解析好 loong64 变体：

- `@esbuild/linux-loong64@0.25.12`
- `@rollup/rollup-linux-loong64-gnu@4.59.0` / `-musl`

但 `pnpm-workspace.yaml` 的 `supportedArchitectures.cpu: [x64, arm64]` 让 pnpm 11
在安装时把它们过滤掉（实测 `.pnpm` 里只有 x64 与 arm64 两个 rollup 包）。
`pnpm install --frozen-lockfile` 本身会「成功」，直到 `pnpm build` 的 vue-tsc
通过后、vite 加载 rollup 时才炸：

```
Error: Cannot find module @rollup/rollup-linux-loong64-gnu
  at requireWithFriendlyError (.../rollup@4.59.0/node_modules/rollup/dist/native.js:115:9)
```

因此 vite / rollup / esbuild **不需要重编译**，但必须解除白名单。
另一个坑：pnpm 把已解析的 optional 依赖集合缓存在 `node_modules/.modules.yaml`，
在已有安装树上改 `supportedArchitectures` 后再 `pnpm install`（哪怕加 `--force`
或 `--no-frozen-lockfile`）仍会报 `Already up to date` 而不补装；必须删除
`node_modules` 重装。`scripts/03-frontend.sh` 已自动处理这个分支。

---

## 3. 关键补丁

### 3.1 aria2-next（已应用、已验证到 OpenSSL 编译完成）

`patches/aria2-next-loongarch64-openssl.patch`：

```diff
 elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$")
   set(ARIA2_OPENSSL_TARGET linux-aarch64)
+elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(loongarch64|loong64)$")
+  set(ARIA2_OPENSSL_TARGET linux64-loongarch64)
 else()
   set(ARIA2_OPENSSL_TARGET linux-x86_64)
 endif()
```

验证方式：`cmake --preset default` 后读 `build/default/build.ninja:440`，
生成的是

```
perl .../openssl/Configure linux64-loongarch64 no-shared ...
```

而不是 `linux-x86_64`。这是可以直接提给上游的、无副作用的架构分支。

其余依赖（Boost 1.91 header-only、curl 8.21、FFmpeg 8.1、GPAC 26.07、
libtorrent 2.1.1、SQLite、zlib、expat…）都在 `third_party/` 里以通用 C/C++
源码编译；`cmake/superbuild/Media.cmake` 只在 `CMAKE_CROSSCOMPILING` 时才传
`--arch`，本机原生编译不触发，无需额外补丁。

### 3.2 Rayburst 的 pnpm 白名单（已应用、已验证重新安装生效）

`patches/rayburst-pnpm-workspace-loong64.patch`：

```diff
 supportedArchitectures:
   os:
     - current
   cpu:
     - x64
     - arm64
+    - loong64
```

这是纯构建配置改动，不影响运行时；同样可以无副作用地提给上游。
验证：删除 `node_modules` 后重新 `pnpm install --frozen-lockfile`，
`node_modules/.pnpm/@rollup+rollup-linux-loong64-gnu@4.59.0` 出现。

### 3.3 tauri-bundler（**不在本地改**，建议提上游）

要让 `tauri build` 原生产出 loong64 deb，需要 4 处改动（v2.10.2）：

| 文件 | 改动 |
| --- | --- |
| `src/bundle/settings.rs:792` | `Arch` 枚举加 `LoongArch64` |
| `src/bundle/settings.rs:1035` | `binary_arch()` 加 `else if self.target.starts_with("loongarch64") { Arch::LoongArch64 }` |
| `src/bundle/linux/debian.rs:47` | 加 `Arch::LoongArch64 => "loong64"`（Debian/Deepin 的架构名是 `loong64`） |
| `src/bundle/linux/rpm.rs:28` | 加 `Arch::LoongArch64 => "loongarch64"`（RPM 系用全称） |

本配方不 patch registry 源码（tauri-cli 是独立安装的二进制，劫持它要改
`cargo install` 的依赖解析，得不偿失），改为复刻 bundler 的目录约定自行打
deb。`--no-bundle` 是安全的：`tauri-cli-2.12.2/src/build.rs:132` 里
`if !options.no_bundle && (...) { crate::bundle::bundle(...) }` 是唯一进入
bundler 的入口，而 `binary_arch()` / `Arch` 只在 `debian.rs`、`rpm.rs` 的
bundle 阶段被调用；全仓库 grep 确认 build 路径没有其他 `binary_arch()` 调用点。

已核对 `debian.rs::generate_data()` 的布局：

```
/usr/bin/rayburst                        主程序
/usr/bin/aria2-next                      sidecar（去掉 -<triple> 后缀）
/usr/bin/rayburst-browser-launcher       sidecar
/usr/lib/Rayburst/<resources 相对路径>   bundle.resources
/usr/share/applications/rayburst.desktop
/usr/share/icons/hicolor/<size>/apps/rayburst.png
```

---

## 4. 实跑验证记录

| 步骤 | 命令 | 结果 |
| --- | --- | --- |
| 环境探测 | `uname -m` / `apt-cache policy` / `npm view` | ✅ 见第 1 节 |
| Node 24 loong64 | 下载 + SHA256 校验 + 解包 | ✅ `v24.22.2`，npm `11.19.1` |
| pnpm 11.5.2 | 用户态安装 | ✅ `11.5.2` |
| `pnpm install --frozen-lockfile` | 首次 2m54s | ✅ 依赖就位，但**未装** loong64 原生包（第 4 项） |
| npm tauri CLI | `./node_modules/.bin/tauri --version` | ❌ `Cannot find native binding`（预期，由 shim 绕过） |
| `pnpm build:native-launcher` | Rust 1.93.0 | ✅ `generated-binaries/rayburst-browser-launcher-loongarch64-unknown-linux-gnu`（699 KiB） |
| `pnpm build`（第一次） | vue-tsc 通过后 | ❌ `Cannot find module @rollup/rollup-linux-loong64-gnu` → 暴露 pnpm 白名单问题 |
| 应用补丁 + `rm -rf node_modules` + 重装 | 35s | ✅ `@rollup+rollup-linux-loong64-gnu@4.59.0` 与 `@esbuild+linux-loong64@0.25.12` 到位 |
| `pnpm build`（修复后） | vue-tsc + vite，13m14s | ✅ `dist/index.html` + 全量 assets 生成（vite 阶段 5m3s，仅有 chunk >500 kB 的常规警告） |
| `cargo install tauri-cli@2.12.2` | Rust 1.93.0，68 min | ✅ `.toolchain/cargo-root/bin/cargo-tauri`（37 MiB loong64 原生），`02-tauri-cli.sh` 复跑命中缓存 |
| aria2-next `cmake --preset default` | — | ✅ 3.9s，`build.ninja:440` 确认 `Configure linux64-loongarch64` |
| aria2-next superbuild | `-j4` | ✅ 11 个依赖 + 引擎本体全部完成；`aria2-next --version` → 3.0.10，ELF 64-bit LSB PIE / LoongArch / 379 MiB（未 strip） |
| `04-engine.sh` | 增量 | ✅ sidecar 落位 `binaries/aria2-next-loongarch64-unknown-linux-gnu` |
| `06-package-deb.sh` 布局自测 | 占位二进制 | ✅ 生成 `Architecture: loong64` 的 deb，`dpkg-deb -c` 核对 `/usr/bin/*` 与 `/usr/lib/Rayburst/*` 布局与 tauri-bundler 一致；自测产物已清除 |
| Rust 主程序 / 真实 deb | 系统 WebKitGTK 4.1 | 🔄 `05-build.sh` 增量重链中 |

详细结构化结果由 `python3 tools/probe.py` 生成到 `report/probe.json`；
系统依赖的 45 个包分组与安装命令记录在 `report/dependencies.json`。
所有长时编译（tauri-cli、aria2-next superbuild）都只需跑一次，产物留在
`.toolchain/` 与 `aria2-next/build/`，后续 `build-all.sh` 会命中缓存。

---

## 5. 降级路径（可选）

`scripts/04-engine.sh --fallback` 会把系统 `aria2c 1.37.0` 复制成
`aria2-next-loongarch64-unknown-linux-gnu`，让 UI 能起来以便先验证界面/渲染。
必须清楚它的能力差异：

| 能力 | aria2-next（推荐） | 系统 aria2c 1.37 |
| --- | --- | --- |
| HTTP/HTTPS、BT/magnet、JSON-RPC 基本接口 | ✅ | ✅ |
| 原生 ED2K / Kad、HLS/DASH | ✅ | ❌（ED2K 需 aMule 补丁版，HLS 无） |
| `--state-dir` 崩溃续传、SQLite 状态 | ✅ | ❌（`.aria2` 控制文件） |
| Rayburst 的 engine RPC 扩展、会话/进度语义 | ✅ | ❌ 部分不兼容 |
| Metalink 3、XML-RPC | 部分 | ✅ |

即：**降级路径只适合验证 UI，不是可用的下载器**。

---

## 6. 未解决 / 需操作者确认的事项

1. **系统开发包已由操作者装齐**（45 个包，含 3 个运行时库），5 个
   pkg-config 模块与 `ldconfig` 全部就位，编译/链接走标准系统路径。
   唯一未验证的是应用实跑：龙芯桌面会话里的托盘、updater、deep-link 与
   WebKitGTK 软件渲染行为，属于运行期验证范围。
2. **Updater / deep-link / 托盘** 等非编译期功能未在龙芯桌面会话里实跑，
   属于运行期验证范围。
3. **aria2-next 全量 superbuild 耗时**：4 核 3A5000 量级上约 1–2 小时；
   产物是链接了 vendored 依赖的单文件，未 strip 时 379 MiB（对比上游预编译
   sidecar 约 18 MiB，发布前建议 `strip` 或加 `-s`）。
4. **分发**：deb 的 `Depends` 按 Deepin 25 的包名写死；换发行版需按实际包名
   调整 `06-package-deb.sh`。
5. **上游同步**：补丁基于 rayburst 4.1.2-beta.2 / tauri-cli 2.12.2 /
   tauri-bundler 2.10.2 / aria2-next 3.0.10。升级后需重新跑 `probe.py` 对比。

---

## 7. 结论

本次移植 **不需要改任何业务代码**，只需要两个上游可接受的构建配置补丁：
`pnpm-workspace.yaml` 加一行 `loong64`，`aria2-next` 的 OpenSSL target 加 5 行分支。
其余工作是补 **三块发行侧缺口** —— Node/pnpm 的 loong64 运行时、原生 tauri-cli、
aria2-next sidecar —— 并绕过 **tauri-bundler 不认识 LoongArch64** 这一处上游限制
（`--no-bundle` + 手工打 `loong64` deb）。唯一需要 root 的一步是
`sudo apt install` 装 WebKitGTK 开发包，操作者已经完成；之后
`./scripts/build-all.sh` 即可端到端产出安装包。尚未验证的只剩龙芯桌面会话里
的运行期行为（托盘 / updater / deep-link / 软件渲染）。
