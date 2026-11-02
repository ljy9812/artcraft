# OHOS (HarmonyOS) Tauri 适配 — ohos-tauri 分支

artcraft（Tauri 应用，`crates/desktop/artcraft`）在 OpenHarmony 真机（HAD-W24 鸿蒙 PC）
上运行的适配分支。**真机首启链已贯通**：前端构建 → `cargo tauri ohos init` → HAP 构建+签名
→ 装机 → 启动 → 首屏渲染（深色工作台 UI 完整呈现）。

> 本分支不含 `artcraft-native`（仓内另一 egui 纯 Rust 变体）的适配——Tauri 应用的
> UI 是 Web 前端（React），在 OHOS 上由 ArkWeb 渲染，**不依赖 egui**；egui 线不需要动。

## 前置依赖

| 依赖 | 说明 |
|---|---|
| Tauri OHOS fork | 兄弟团队仓，需 checkout 到 `../../tauri-3.0`（相对本仓根），**只消费不修改**。根 `Cargo.toml` 的 `[patch.crates-io]` 14 条 path 重定向已按此相对路径写死 |
| DevEco Studio | 取 SDK clang（`CC/CXX_aarch64_unknown_linux_ohos`）与 NDK `libc++_shared.so` |
| OHOS 签名物料 | DevEco auto-sign 产出的 p12/cer/p7b + 解出的口令（本机 `.ohos/config/`，不入库） |

## 本分支的源码改动（全量）

1. **依赖挂载**（根 `Cargo.toml` + `Cargo.lock`）：`[patch.crates-io]` → fork；
   版本对齐 fork 实值（tauri 2.11.2→2.10.3 / tauri-build 2.6.2→2.5.6 / tauri-plugin 2.6.2→2.5.4）。
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
   `napi-ohos` / `napi-derive-ohos`（入口宏展开会引用，app 侧必须自带）。
7. **vendor 对齐**（`crates/vendor/tauri-plugin-http`）：版本对齐 + 权限文件重生成。
8. `tauri.ohos.conf.json`：identifier（真机判据用单槽 bundleName）+ 空
   `beforeBuildCommand`。

## 构建配方

```bash
cd crates/desktop/artcraft

CI=true SQLX_OFFLINE=true CMAKE_GENERATOR=Ninja BORING_BSSL_RUST_CPPLIB=c++ \
CC_aarch64_unknown_linux_ohos="<SDK>/llvm/bin/clang.exe" \
CXX_aarch64_unknown_linux_ohos="<SDK>/llvm/bin/clang++.exe" \
TAURI_WORKSPACE_ROOT="<tauri-3.0 绝对路径>" \
OHOS_KEYSTORE_FILE=<p12> OHOS_KEYSTORE_PASSWORD=<口令> \
OHOS_KEY_ALIAS=<别名> OHOS_KEY_PASSWORD=<口令> \
OHOS_APP_CERT_FILE=<cer> OHOS_PROFILE_FILE=<p7b> \
cargo tauri ohos build --device-type desktop --ci -t aarch64
```

前端 dist 由 tauri-codegen 嵌进 `.so`（不进 HAP），webview 走 `tauri://localhost`。

### 构建后必做：注入 libc++_shared.so（白屏根因）

`libartcraft_app_lib.so` 因 `BORING_BSSL_RUST_CPPLIB=c++`（boring-sys2）带
`DT_NEEDED libc++_shared.so`，而 OHOS 不随包提供（系统 `lib64/ndk/` 没有）→ 缺库
= 模块加载失败 = 白屏。注入点必须选 **`gen/ohos/tauri/libs/arm64-v8a/`**（@tauri/app
HAR 模块目录，经 HAR 依赖链随 entry 打进 HAP）：

```bash
cp "<SDK>/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so" \
   gen/ohos/tauri/libs/arm64-v8a/
```

`gen/ohos/` 是 `cargo tauri ohos init` 的产物（不入库，`.gitignore` 已忽略），init
重建后需重打此注入。**不要**放进 `entry_desktop/libs/`（每次构建被 `ohrs --dist`
同步删除）或 `dialog/libs/`（被 tauri-cli 重建删除）。

## 真机验证

`verify-launch.ps1`（仓根）：bm uninstall → hdc install → hilog -r → aa start →
pidof → hilog 启动链 → faultlog 检查 → snapshot_display 截图。判据：

- pid 存活 + `:gpu` 子进程、无新 cppcrash
- hilog `RustStdoutStderr`：`OHOS filesDir base:` → 六数据子目录 →
  `scheme_handler register custom schemes tauri` → ArkWeb 引擎初始化
- 首屏截图非白（完整工作台 UI）

注意：`hilog -x` 里混有 ArkWeb C++ 内部日志（`audio_dump` 每 40ms 一条），过滤：
`grep -vE 'audio_dump|oh_gin|nweb_handler|arkweb_browser'`。
