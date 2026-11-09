# OHOS (HarmonyOS) Tauri 适配 — ohos-tauri 分支

artcraft（Tauri 应用，`crates/desktop/artcraft`）在 OpenHarmony 真机（HAD-W24 鸿蒙 PC）
上运行的适配分支。**真机首启链已贯通**：前端构建 → `cargo tauri ohos init` → HAP 构建+签名
→ 装机 → 启动 → 首屏渲染（深色工作台 UI 完整呈现）+ 主窗关闭干净退出。

> 2026-11-09 重锁 fork `ohdev-git` 至 `73bffac6f`（自 `46a19d8d`）并全链重验：
> HAP 双 `.so` 齐、冷启/首屏/关闭退出链全过。fork 新增 `sync_ohos_tauri_module`
> 与主窗 close 修复（见下文两节）。

> 本分支不含 `artcraft-native`（仓内另一 egui 纯 Rust 变体）的适配——Tauri 应用的
> UI 是 Web 前端（React），在 OHOS 上由 ArkWeb 渲染，**不依赖 egui**；egui 线不需要动。

## 前置依赖

| 依赖 | 说明 |
|---|---|
| Tauri OHOS fork | 兄弟团队仓（GitHub `Eulogizethesun` 系十仓，外发分支统一 `ohdev-git`），**只消费不修改**。根 `Cargo.toml` 的 `[patch.crates-io]` 16 条 git 重定向——cargo 自动拉取，**无需本地 tauri 源码树**。当前锁 `73bffac6f`（内部提速备选：换 path 指向 `../../tauri-3.0` checkout，版本面与 ohdev-git 分支一致） |
| tauri-cli（OHOS 版） | `cargo install --git https://github.com/Eulogizethesun/tauri --branch ohdev-git --locked tauri-cli`（crates.io 发行版无 OHOS 支持） |
| ohrs | `cargo install ohrs --version 1.3.1`（tauri-cli 内部调用它编 `.so`） |
| DevEco Studio | 取 SDK clang（`CC/CXX_aarch64_unknown_linux_ohos`）与 NDK `libc++_shared.so` |
| OHOS 签名物料 | DevEco auto-sign 产出的 p12/cer/p7b + 解出的口令（本机 `.ohos/config/`，不入库） |

## 本分支的源码改动（全量）

1. **依赖挂载**（根 `Cargo.toml` + `Cargo.lock`）：`[patch.crates-io]` 16 条 → fork 的
   `ohdev-git` 分支（git 依赖，无需本地 tauri 树；artcraftx 仓已以同形态真机端到端验证，
   版本面对齐——两仓 fork 实值相同）。版本对齐 fork 实值
   （tauri 2.11.2→2.10.3 / tauri-build 2.6.2→2.5.6 / tauri-plugin 2.6.2→2.5.4）。
   锁 source 形态切换用 `cargo fetch`（`cargo update -p` 在 patch source 变更后报
   "did not match any packages"）；patch 生效判据 =
   `grep -c '^\[\[patch.unused\]\]' Cargo.lock` 为 0。
1a. **dialog 插件 HAR 入仓**（`crates/desktop/artcraft/plugins/dialog/openharmony/`，
   6 文件 + `libs/arm64-v8a/libc++_shared.so` 注入位）：
   tauri-cli 找插件 OHOS HAR 只认 `<project_dir>/plugins/<name>/openharmony`（本方案）、
   plugins-workspace 兄弟目录上溯、`TAURI_WORKSPACE_ROOT` 三处——git 依赖模式下后两处
   不存在，dialog HAR 拷入仓内即自动发现（fs/log/upload/opener 无 OHOS HAR，Warn 跳过
   属预期）。`libs/` 子目录 = libc++ 注入通道（见构建配方节，白屏根因修复）。
2. **入口条件**（`src/lib.rs`）：`cfg_attr` 加 `target_env = "ohos"`——OHOS 上
   `cfg(mobile)` 恒 false，不并入则 `mobile_entry_point` 不展开。
3. **OHOS 数据根**（`src/lib.rs` `run()`）：`AppDataRoot` 不再走 `UserDirs`（OHOS
   沙箱无 `$HOME`，`.expect` 即启动 SIGABRT），改用 `tauri::ohos::APP` 的 Ability
   `filesDir` + `"artcraft"`，与 tauri path resolver 同源。
4. **hilog 可见性**（`src/lib.rs` + `Cargo.toml`）：`ohos-hilog-binding` 的 `redirect`
   特性，`run()` 头部 `forward_stdio_to_hilog()` 把 Rust stdout/stderr 转进 hilog
   （tag `RustStdoutStderr`）——否则 `println!` 与 panic 消息在 OHOS app 进程全丢。
5. **cfg 垫片**（`src/core/ohos_compat.rs` 新文件 + 7 个登录窗 import）：
   `DesktopOnlyBuilderCompat` 给 `fullscreen/always_on_top/center` 等桌面专属 builder
   方法提供 ohos 面空操作；desktop 面零影响。
6. **ohos deps**（`crates/desktop/artcraft/Cargo.toml`）：`openharmony-ability` /
   `napi-ohos` / `napi-derive-ohos`（入口宏展开会引用，app 侧必须自带）+
   `log = "0.4"` 直依赖（app 源码用 `use log::` 宏，desktop 面走
   `log.workspace = true`；ohos/ohrs 构建链下以直依赖形态最稳，2026-11-09
   重锁 `73bffac6f` 时实证必需——新 tip 的 openharmony-ability 新引 `hilog`/
   `hilog-sys` 两个 log 消费者，依赖图改面）。
   **坑**：`[target.'cfg(target_env = "ohos")'.dependencies]` 段必须放在文件里
   **vendor 两行（`tauri-plugin-http` / `tauri-plugin-opener`）之后**——TOML 靠表头分段，
   注释和空行不结束上一段；插在其前会把这两条 upstream 无条件依赖吞进 ohos 专属段，
   host/desktop 构建面直接损坏（依赖不在图里 → capabilities 引用的 `http:*` / `opener:*`
   权限解析不到 → app build.rs 报 "Permission http:allow-fetch not found"）。OHOS 面恰好
   不触发（cfg 匹配），属「只在对照平台显形」型回归。
7. **vendor 对齐**（`crates/vendor/tauri-plugin-http`）：版本对齐 + 权限文件重生成。
8. `tauri.ohos.conf.json`：identifier（真机判据用单槽 bundleName）+ 空
   `beforeBuildCommand`。

## 构建配方

```bash
cd crates/desktop/artcraft

CI=true SQLX_OFFLINE=true CMAKE_GENERATOR=Ninja BORING_BSSL_RUST_CPPLIB=c++ \
CC_aarch64_unknown_linux_ohos="<SDK>/llvm/bin/clang.exe" \
CXX_aarch64_unknown_linux_ohos="<SDK>/llvm/bin/clang++.exe" \
OHOS_KEYSTORE_FILE=<p12> OHOS_KEYSTORE_PASSWORD=<口令> \
OHOS_KEY_ALIAS=<别名> OHOS_KEY_PASSWORD=<口令> \
OHOS_APP_CERT_FILE=<cer> OHOS_PROFILE_FILE=<p7b> \
cargo tauri ohos build --device-type desktop --ci -t aarch64
```

前端 dist 由 tauri-codegen 嵌进 `.so`（不进 HAP），webview 走 `tauri://localhost`。

### 构建后必做：注入 libc++_shared.so（白屏根因）

`libartcraft_app_lib.so` 因 `BORING_BSSL_RUST_CPPLIB=c++`（boring-sys2）带
`DT_NEEDED libc++_shared.so`，而 OHOS 不随包提供（系统 `lib64/ndk/` 没有）→ 缺库
= 模块加载失败 = 白屏。**注入点必须选 dialog 插件【源】目录**：

```bash
cp "<SDK>/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so" \
   crates/desktop/artcraft/plugins/dialog/openharmony/libs/arm64-v8a/
```

本仓已带该文件（git 可跟踪）。原理：tauri-cli 每次构建把 dialog 插件源目录
`plugins/dialog/openharmony/` 整树重拷到 `gen/ohos/dialog/`（只跳 `.tauri`/`target`），
HAR 模块根的 `libs/arm64-v8a/` 是 hvigor 自动打包约定——两条路径叠加后 libc++
随 HAR 依赖链打进 HAP，对任何 tauri-build 同步行为免疫。

**`gen/ohos/tauri/libs/` 通道已失效**（2026-11-09 实证）：fork `73bffac6f` 起
tauri-build 的 `sync_ohos_tauri_module` 在**每次 Rust 构建**把 `gen/ohos/tauri`
严格镜像到 `crates/tauri/mobile/ohos` 模板并剪枝多余文件——git 依赖模式同样触发
（旧结论「git 模式无 sync」作废），注入即被清 = 装机白屏。`entry_desktop/libs/`
（`ohrs --dist` 同步删除）与 gen 侧 `dialog/libs/`（整树重拷覆盖）同样不可用。

复核：`unzip -l <hap> | grep libc++` 应见 `libc++_shared.so`（1,262,504 B）与
`libartcraft_app_lib.so` 并存。

## 真机验证

`verify-launch.ps1`（仓根）：bm uninstall → hdc install → hilog -r → aa start →
pidof → hilog 启动链 → faultlog 检查 → snapshot_display 截图。判据（2026-11-09
全过，fork `73bffac6f`）：

- pid 存活 + `:gpu` 子进程、无新 cppcrash
- hilog `RustStdoutStderr`：`OHOS filesDir base:` → 六数据子目录 →
  `scheme_handler register custom schemes tauri` → ArkWeb 引擎初始化
- 首屏截图非白（完整工作台 UI；深色页为预期——welcome 页即深色设计）
- 主窗关闭干净退出（下节）

注意：`hilog -x` 里混有 ArkWeb C++ 内部日志（`audio_dump` 每 40ms 一条），过滤：
`grep -vE 'audio_dump|oh_gin|nweb_handler|arkweb_browser'`。

### 主窗关闭（close 僵尸修复）复验

fork 在 `73bffac6f` 链上带主窗 close 修复（runtime-wry `6a7d99c5a` + tao
`3b91165`/`545698d7`）：主窗关闭改走 `RunEvent::ExitRequested` → 窗口表移除 →
单次 Destroyed → `ControlFlow::Exit`，修复旧版「窗口已关但进程/窗口残留」僵尸。
OHOS 侧配套：`onWindowStageDestroy` → CloseRequested+Destroyed、
`onPrepareToTerminateAsync`（PC/2in1 关窗按钮探测）。

artcraft 主窗 `decorations(false)`（`setup_main_window.rs`，跨平台自绘标题栏）→
**OS 层无 −/□/× 按钮**；自绘窗口控制在登录后 TopBar 右上。OS 层标准关闭触发 =
Alt+F4：

```bash
hdc shell "uitest uiInput keyEvent 2045 2093"    # AltLeft=2045, F4=2093（组合键语法）
```

判据（2026-11-09 实测，12:55:51 发键 → 12:55:53 全清，~2s）：

- hilog 退出链依序：`web was hidden:1` → `NWebDelegate::OnWindowHide` →
  `~WindowScene: winId 1600 destructor!`（窗口场景析构）→
  `[ARR1101] terminate EntryAbility` → `[ARM992] terminate isLast:1,keepAlive:0`
  → `[ARR1719] Application terminated` → `OnProcessDied`（主 + `:gpu`/`:render` 全部）
- `pidof com.egui.device_spike` 为空；WMS 查询该 WinId 失效（窗口已注销）
- faultlog 无新增 cppcrash（干净退出而非崩溃）

### 调试通道（附带）

ArkWeb devtools socket 常开（release 亦然）：`hdc shell "cat /proc/net/unix |
grep devtools"` 可见 `@webview_devtools_remote_<pid>`，可用于 CDP 注入 JS
（`withGlobalTauri: true` 下 `window.__TAURI__` 可达，例如
`window.__TAURI__.window.getCurrentWindow().close()` 走与应用自绘 × 相同的关闭路径）。
