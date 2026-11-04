# TRY-GUIDE — artcraft / artcraftx 鸿蒙（OHOS）试用指南（双应用单份）

artcraft 与 artcraftx 是姊妹 **Tauri 2 桌面应用**（React 前端 + Rust 后端），在鸿蒙上由
ArkWeb 渲染前端。两者 OHOS 构建流程**完全同构**，本指南一份通用，差异集中在下表：

| 变量 | artcraft | artcraftx |
|---|---|---|
| fork 仓（clone 用） | `https://github.com/ljy9812/artcraft.git` | `https://github.com/ljy9812/artcraftx.git` |
| `cargo tauri ohos init` / build 目录 | `crates/desktop/artcraft` | `crates/artcraftx` |
| §6 的 bindgen 三 `-isystem` | 保险项（本仓实测可不设） | **刚需**（缺即失败） |
| 首启判据日志（§9） | 见 §9 左列 | 见 §9 右列（多 IPC 回环验证） |

与其他 14 个 craft 应用的试用方式**不同**：

| | 其他 14 个 craft 应用（web 壳） | artcraft / artcraftx（Tauri 线） |
|---|---|---|
| 形态 | 官方 web 版装进 ArkWeb 壳，零 Rust | **从源码构建**（Tauri 应用无预构建鸿蒙包） |
| 工具链 | 只需 DevEco Studio | DevEco + Rust + Node + ohrs + OHOS 版 tauri-cli |
| Tauri 依赖 | 无 | 兄弟团队 fork（GitHub `Eulogizethesun` 系十仓，`ohdev-git` 分支），**cargo 自动拉取，无需手动克隆** |
| 签名装机 | DevEco 自动签名 + Run | 同左（或命令行签名，见 §7） |

> 本指南在 Windows 11 + DevEco Studio 5.x + Rust stable 上验证。
> 技术配方细节见各仓根 `OHOS-TAURI.md`；本文件面向第一次跑通的同事。
> artcraft 仓内另有 `artcraft-native`（egui 纯 Rust 变体）——**不在本指南范围**，Tauri 线不依赖 egui。

## 1. 前置环境（一次性安装）

| # | 装 | 验证 |
|---|---|---|
| 1 | [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 OpenHarmony SDK / ohpm / hvigor / hdc） | 装完记下 SDK 路径，下文记作 `<SDK>`，默认 `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony` |
| 2 | [Rust](https://rustup.rs/) + 交叉目标 | `rustup target add aarch64-unknown-linux-ohos` |
| 3 | `ohrs` 构建工具 | `cargo install ohrs --version 1.3.1`（crates.io；tauri-cli 内部调用它编 `.so`） |
| 4 | **OHOS 版 tauri-cli（必须）** | `cargo install --git https://github.com/Eulogizethesun/tauri --branch ohdev-git --locked tauri-cli` |
| 5 | Node.js ≥ 20（含 npm） | `node --version` |

**第 4 步是关键**：crates.io 发行版 tauri-cli **没有** OHOS 支持。装完用
`cargo install --list` 核验来源是 `Eulogizethesun/tauri`（git）而非 registry。
若以后 fork 更新过模板，重装一次即可（模板编译进二进制）。

## 2. 获取代码

```bash
# 二选一
git clone -b ohos-tauri https://github.com/ljy9812/artcraft.git
git clone -b ohos-tauri https://github.com/ljy9812/artcraftx.git
```

依赖全部走 git（`Cargo.toml` 的 `[patch.crates-io]` 指向 `Eulogizethesun/*` 各仓的
`ohdev-git` 分支），首次构建时 cargo 自动拉取——**不需要**手动下载任何 Tauri 源码。

## 3. 构建前端（必须先于一切 cargo 命令）

tauri-codegen 嵌入前端产物时要求 `frontend/apps/artcraft/dist` 已存在，缺失则构建直接失败
（**两仓的 Nx 应用名同名，都是 `artcraft`**，无需替换）：

```bash
cd frontend
npm install
printf 'n\n' | npx nx run artcraft:build
```

`printf 'n\n'` 用于应答 Nx 的交互提示（无人值守环境会卡死）。
若 nx 报找不到 `@storyteller/*` 内部包，先跑一遍 `bash build_modules.sh` 再重试。

## 4. 生成 OHOS 工程

```bash
cd crates/desktop/artcraft    # artcraftx 仓则为：cd crates/artcraftx
cargo tauri ohos init --ci
```

生成 `gen/ohos/`（DevEco 工程，不入库）。包名等已由仓内 `tauri.ohos.conf.json` 定死
（bundleName `com.egui.device_spike`，真机判据单槽——自己设备上可改成任意 identifier）。

## 5. init 后的两处手工修正

`gen/` 每次重新 init 都要重打：

1. **注入 libc++_shared.so（白屏根因）**。app 的 `.so` 带 `DT_NEEDED libc++_shared.so`
   而鸿蒙不随包提供，缺库 = 模块加载失败 = 白屏。注入点必须是
   `gen/ohos/tauri/libs/arm64-v8a/`（@tauri/app HAR 模块目录，随 entry 打进 HAP）：

   ```bash
   mkdir -p gen/ohos/tauri/libs/arm64-v8a
   cp "<SDK>/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so" gen/ohos/tauri/libs/arm64-v8a/
   ```

   不要放 `entry_desktop/libs/`（每次构建被同步删除）或 `dialog/libs/`（被 tauri-cli 重建删除）。

2. **补 boring-sys2 幽灵目录（构建 panic 根因）**。boring-sys2 声明的两个 `-L` 目录在
   全新 `target/` 上从不存在，`ohrs` 对其做 canonicalize 时目录缺失即 panic。空目录即可：

   ```bash
   mkdir -p ../../target/aarch64-unknown-linux-ohos/release/build/boring-sys2-*/out/build/crypto
   mkdir -p ../../target/aarch64-unknown-linux-ohos/release/build/boring-sys2-*/out/build/ssl
   ```

   （首次构建跑出 boring-sys2 的 out 目录后才能对上 hash；`target/` 清理后需重建。）

## 6. 构建 HAP

在 §4 的同一目录下（artcraft：`crates/desktop/artcraft`；artcraftx：`crates/artcraftx`；
PowerShell 形态，占位符替换成自己的路径）：

```powershell
$envs = @{
  CI='true'; SQLX_OFFLINE='true'; CMAKE_GENERATOR='Ninja'; BORING_BSSL_RUST_CPPLIB='c++'
  OHOS_DEVICE_TYPE='desktop'
  LIBCLANG_PATH='<SDK>/native/llvm/bin'
  BINDGEN_EXTRA_CLANG_ARGS='-isystem "<SDK>/native/llvm/lib/clang/15.0.4/include" -isystem "<SDK>/native/sysroot/usr/include/aarch64-linux-ohos" -isystem "<SDK>/native/sysroot/usr/include"'
  CC_aarch64_unknown_linux_ohos='<SDK>/native/llvm/bin/clang.exe'
  CXX_aarch64_unknown_linux_ohos='<SDK>/native/llvm/bin/clang++.exe'
}
foreach ($k in $envs.Keys) { Set-Item -Path "Env:$k" -Value $envs[$k] }
cargo tauri ohos build --device-type desktop --ci -t aarch64
```

说明：
- `LIBCLANG_PATH` / `BINDGEN_EXTRA_CLANG_ARGS`（三 `-isystem`，带空格路径内层双引号）：
  **artcraftx 为刚需**（boring-sys2 等 bindgen 面在 OHOS 交叉目标下 Windows libclang 的
  resource-dir 解析会静默失败）；artcraft 实测可不设——**建议无论如何设全**，免排查。
- `OHOS_DEVICE_TYPE=desktop` 对应鸿蒙 PC / 2-in-1（两应用的目标形态）。
- 产物：`gen/ohos/entry_desktop/build/default/outputs/default/entry_desktop-default-signed.hap`
  （设了 §7 的签名环境变量时；未设则为 `-unsigned.hap` 并警告）。
- 首次构建约 30–60 分钟（全量编译，artcraft 约 430 个 crate）；clang 版本号按实际 `<SDK>` 内目录名调整。

## 7. 签名与装机运行

**路线 A（推荐，与其他 14 个应用同款操作）**：
1. `cargo tauri ohos build` 不设签名变量 → 产出 unsigned HAP（`.so` 与工程全部就位）；
2. DevEco Studio 打开 `gen/ohos` 工程（路径见 §6 开头）→
   File → Project Structure → Signing Configs → 勾 **Automatically generate signature**；
3. 直接点 **Run**——DevEco 自动签名、装机、拉起。

**路线 B（命令行，CI/脚本用）**：构建时同 shell 设齐六个变量（全设才生效）：
`OHOS_KEYSTORE_FILE`（p12）/ `OHOS_KEYSTORE_PASSWORD` / `OHOS_KEY_ALIAS` /
`OHOS_KEY_PASSWORD` / `OHOS_APP_CERT_FILE`（cer）/ `OHOS_PROFILE_FILE`（p7b），
材料来自 DevEco 自动签名产物。装机运行：

```bash
hdc install <上述 signed.hap>
hdc shell "aa start -a EntryAbility -b com.egui.device_spike"
```

## 8. 常见问题

| 症状 | 根因与处理 |
|---|---|
| 装机后白屏 | libc++_shared.so 没注入（§5.1）或注入点选错 |
| 构建 panic 在 `ohrs`/canonicalize | boring-sys2 幽灵目录（§5.2） |
| bindgen 报找不到 `stddef.h` 等 | `BINDGEN_EXTRA_CLANG_ARGS` 三 `-isystem` 缺失或路径带空格没内层引号（§6） |
| cargo 一上来就失败找不到 dist | 前端没先构建（§3） |
| 装机报 `9568263 version downgrade` | 槽里有更高版本号的旧包（姊妹应用先装过即触发——两者同 bundleName 单槽互斥），先 `hdc shell "bm uninstall -n com.egui.device_spike"` |
| 装机报 `9568289 grant request permissions failed` | tauri-cli 不是 `ohdev-git` 版（旧二进制模板带受限权限条目）——`cargo install --list` 核验后重装 §1.4 |
| `aa start` 返回成功但界面没变 | 命中了已在跑的实例（onNewWant 拉前台）；先 force-stop 再启动 |
| 看不到 Rust 日志 | hilog 过滤 tag `RustStdoutStderr`；ArkWeb 噪声用 `grep -vE 'audio_dump\|oh_gin\|nweb_handler\|arkweb_browser'` 剥掉 |

## 9. 预期结果（验证判据）

冷启动公共判据：pid 存活，首屏为深色工作台 UI（非白屏），持续使用无崩溃
（faultlog 无新增 cppcrash）。hilog `RustStdoutStderr` 启动序列两应用略有差异：

| artcraft | artcraftx |
|---|---|
| `OHOS filesDir base:` → 数据子目录 → `scheme_handler register custom schemes tauri` → ArkWeb 引擎初始化 | `OHOS filesDir base:` → `NativeAbility onCreate` → `scheme_handler register custom schemes tauri` → `OnFirstScreenPaint` → `get_app_info_command called`（前端↔Rust IPC 回环） |
