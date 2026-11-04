# TRY-GUIDE — artcraft / artcraftx 鸿蒙（OHOS）构建装机指南

Tauri 线应用无预构建鸿蒙包，需从源码构建。两应用流程同构，差异仅 4 处：

| | artcraft | artcraftx |
|---|---|---|
| clone 仓 | `ljy9812/artcraft` | `ljy9812/artcraftx` |
| init / build 目录 | `crates/desktop/artcraft` | `crates/artcraftx` |
| §6 bindgen 三 `-isystem` | 可省 | **必设** |
| 首启日志判据 | §9 左 | §9 右 |

> Windows 11 + DevEco Studio 5.x 验证。技术细节见各仓根 `OHOS-TAURI.md`。
> artcraft 仓的 `artcraft-native/` 不在本指南范围。

## 1. 环境（一次性）

```bash
# DevEco Studio（含 SDK/ohpm/hvigor/hdc），SDK 路径下文记 <SDK>，
# 默认 C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony
rustup target add aarch64-unknown-linux-ohos
cargo install ohrs --version 1.3.1
cargo install --git https://github.com/Eulogizethesun/tauri --branch ohdev-git --locked tauri-cli
node --version   # ≥ 20
```

tauri-cli 必须装 git 版（crates.io 版无 OHOS 支持）。核验：`cargo install --list`
来源为 `Eulogizethesun/tauri`。fork 模板更新后重装。

## 2. 获取代码

```bash
git clone -b ohos-tauri https://github.com/ljy9812/artcraft.git     # 或 artcraftx.git
```

Tauri 依赖 cargo 自动拉取（`[patch.crates-io]` → `Eulogizethesun/*` @ `ohdev-git`），无需手动克隆。

## 3. 构建前端（先于一切 cargo 命令，缺 dist 即构建失败）

```bash
cd frontend
npm install
printf 'n\n' | npx nx run artcraft:build    # 两仓 Nx 应用名同为 artcraft
```

nx 报缺 `@storyteller/*` 时：先 `bash build_modules.sh` 再重试。

## 4. 生成 OHOS 工程

```bash
cd crates/desktop/artcraft    # artcraftx: cd crates/artcraftx
cargo tauri ohos init --ci
```

生成 `gen/ohos/`（不入库）。bundleName `com.egui.device_spike`，真机单槽，自己设备可改 `tauri.ohos.conf.json`。

## 5. init 后手工修正（每次 init 重打）

```bash
# 5.1 注入 libc++_shared.so（缺 = 白屏）
mkdir -p gen/ohos/tauri/libs/arm64-v8a
cp "<SDK>/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so" gen/ohos/tauri/libs/arm64-v8a/
# 只放此目录；entry_desktop/libs/ 与 dialog/libs/ 会被构建删除

# 5.2 boring-sys2 空目录（缺 = 构建 panic；target/ 清理后重建）
mkdir -p ../../target/aarch64-unknown-linux-ohos/release/build/boring-sys2-*/out/build/crypto
mkdir -p ../../target/aarch64-unknown-linux-ohos/release/build/boring-sys2-*/out/build/ssl
```

## 6. 构建 HAP

在 §4 同一目录，PowerShell（`<SDK>` 替换为实际路径）：

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

- `BINDGEN_EXTRA_CLANG_ARGS` 带 `stddef.h` 报错时必查；空格路径须内层双引号；clang 版本号按 `<SDK>` 实际目录名调整
- 产物：`gen/ohos/entry_desktop/build/default/outputs/default/entry_desktop-default-signed.hap`（未设签名变量则 `-unsigned.hap`）
- 首次 30–60 分钟（全量编译）

## 7. 签名与装机

**路线 A（推荐）**：不设签名变量构建 → DevEco 打开 `gen/ohos` 工程 →
File → Project Structure → Signing Configs → 勾 **Automatically generate signature** → **Run**。

**路线 B（命令行）**：构建时同 shell 设齐 6 个变量（全设才生效）：
`OHOS_KEYSTORE_FILE`（p12）/ `OHOS_KEYSTORE_PASSWORD` / `OHOS_KEY_ALIAS` /
`OHOS_KEY_PASSWORD` / `OHOS_APP_CERT_FILE`（cer）/ `OHOS_PROFILE_FILE`（p7b）。

```bash
hdc install <signed.hap>
hdc shell "aa start -a EntryAbility -b com.egui.device_spike"
```

## 8. 症状 → 处理

| 症状 | 处理 |
|---|---|
| 装机后白屏 | libc++ 没注入或注入点错（§5.1） |
| 构建 panic 在 `ohrs`/canonicalize | boring-sys2 空目录（§5.2） |
| bindgen 找不到 `stddef.h` 等 | §6 三 `-isystem` 缺失 / 空格路径没内层引号 |
| cargo 失败找不到 dist | 前端没先构建（§3） |
| 装机报 `9568263 version downgrade` | 单槽互斥（姊妹应用装过即触发）：`hdc shell "bm uninstall -n com.egui.device_spike"` 后重装 |
| 装机报 `9568289 grant request permissions failed` | tauri-cli 非 git 版，重装 §1 |
| `aa start` 成功但界面没变 | 命中在跑实例；先 force-stop 再启动 |
| 看不到 Rust 日志 | hilog 过滤 tag `RustStdoutStderr`，`grep -vE 'audio_dump\|oh_gin\|nweb_handler\|arkweb_browser'` |

## 9. 验证判据

pid 存活、首屏深色工作台 UI（非白屏）、使用无崩溃（faultlog 无新增 cppcrash）。
启动日志（tag `RustStdoutStderr`）依次出现：

| artcraft | artcraftx |
|---|---|
| `OHOS filesDir base:` → 数据子目录 → `scheme_handler register custom schemes tauri` → ArkWeb 引擎初始化 | `OHOS filesDir base:` → `NativeAbility onCreate` → `scheme_handler register custom schemes tauri` → `OnFirstScreenPaint` → `get_app_info_command called` |
