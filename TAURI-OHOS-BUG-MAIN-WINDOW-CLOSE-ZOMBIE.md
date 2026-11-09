# Tauri OHOS 主窗关闭「僵尸态」Bug 报告

> 单行摘要：应用自绘关闭按钮（前端 JS `getCurrent().close()`）触发主窗关闭后，OS 窗口不关闭、进程存活、渲染正常，但 Rust 侧窗口记账已被删除——此后**所有窗口命令（min/max/close 及全部 getter）静默失效**，窗口进入"僵尸态"。
>
> 提交目的：请 fork 维护者确认根因分析并评估修复方案（见「修复建议」节，三选一均可讨论）。

## 1. 环境

| 项 | 值 |
|---|---|
| 设备 | HAD-W24 鸿蒙笔记本（OHOS 桌面 / 自由窗口形态） |
| 应用 | artcraft —— Tauri 2 桌面应用（React 前端 + Rust 后端，**单主窗 UIAbility** 形态，无 Float 子窗） |
| bundleName | com.egui.device_spike |
| fork 依赖 | `[patch.crates-io]` 引用，均为 `https://github.com/Eulogizethesun/{tauri,wry,tao,muda,openharmony-ability}` @ branch `ohdev-git` |
| Cargo.lock 锁定 rev | **tauri `46a19d8`** / tao `4c4f307` / **openharmony-ability `cdd3ef6`** / muda `7435fa5` |
| 分支时效性（2026-11-03 查证） | 上述 rev 即两主仓 `ohdev-git` 分支的**当前 GitHub tip**（tauri tip = `46a19d8`、openharmony-ability tip = `cdd3ef6`）——报告所有行号即 tip 上的行号，checkout `ohdev-git` 即可复核 |
| 版本面 | tauri 2.10.3 / wry 0.55.0 / tao 0.35.0 |
| 构建目标 | aarch64-unknown-linux-ohos |

## 2. 症状（用户视角）

1. **冷启动一切正常**。minimize 已端到端验证过健康链路：app 按钮 → 桥调用 `ohos.window/minimize` → WMS `Minimize: id: <windowId>` → 窗口收起。
2. 点一次 app 自绘 close（web TopBar 右上 ×）之后：
   - **窗口不关闭**，视觉一切正常，持续渲染；
   - 此后 **min / max / close 三钮全部点击无效**——点击事件能到达 web 层（IPC 流量正常），但 Rust 侧没有任何窗口命令被执行；
   - **进程不退出**；
   - 应用每秒约 4 条错误刷屏（app 自身的窗口尺寸轮询任务）：`Error persisting window size: runtime error: failed to receive message from webview`。
3. 只有重杀进程（force-stop）才能恢复。

## 3. 确定性复现（两轮独立实例确认，复现率 100%）

1. 冷启动 app；
2. 验证健康态：点 minimize，hilog 应出现 `[bridge] call_raw: ohos.window/minimize` 与 WMS `Minimize: id: ...`（对照组）；
3. 恢复窗口；
4. 点 app 自绘 close 按钮；
5. 观察：
   - hilog 出现 destroy 链（见 §4 逐字时间线）；
   - 窗口不关闭；
   - **34 秒后**再点 minimize：点击到达（`WindowManager: User interacted with window: id=0`），但整个捕获窗内 `ohos.window/minimize` 桥流量 = **0**、WMS `Minimize` = **0** —— 按钮已死。

## 4. 证据时间线（hilog 逐字摘录，2026-11-03 19:37，pid 14399）

```
19:37:19.956  WindowManager: User interacted with window: id=0                      ← 点击 app 自绘 close
19:37:20.408  OhGinJavascriptBridgeDispatcherHost::OnInvokeMethod: postMessage      ← 前端 close IPC 到达
19:37:20.445  [tauri_runtime_wry][INFO]  [wry] on_window_close: destroy_window ohos_id=0
19:37:20.453  [openharmony_ability::bridge][INFO] [bridge] call_raw: ohos.window/destroy-window
19:37:20.460  [tauri_runtime_wry][INFO]  [wry] ExitRequested (all windows closed) should_prevent: false   ← store 已被摘空
19:37:20.478  [tauri_runtime_wry][WARN]  [WRY] destroy_window failed: Error { status: "GenericFailure",
               reason: "Error: Cannot destroy the main Ability window (id 0)" }     ← ArkTS 拒绝销毁主窗
19:37:20.540  [artcraft...main_window_thread][ERROR] Error persisting window size:
               runtime error: failed to receive message from webview                ← 僵尸心跳开始，每秒 ~4 条
19:37:54.242  WindowManager: User interacted with window: id=0                      ← 34s 后点 minimize，点击到达
（此后整个捕获窗）ohos.window/minimize 桥流量 = 0，WMS Minimize = 0                 ← 按钮死亡实证
```

日志原文（可提供）：`repro3-hilog.log`、`repro4-after-minclick.log`（后者单个文件包含从 destroy 链到 minimize 死亡的完整过程）。

## 5. 根因分析

### 5.0 归因结论：缺陷 100% 在 fork 的 OHOS 专属代码，不在 app、不在 upstream tauri

三条独立证据：

1. **缺陷代码只存在于 fork 的 `#[cfg(target_env = "ohos")]` 函数里**。fork 自己的代码注释在同文件写明了与 upstream 的语义分界（`tauri-runtime-wry/src/lib.rs:4952-4956`）：
   > *"Non-OHOS platforms keep the upstream close/destroy lifecycle verbatim: CloseRequested/null-inner close here, and **the Destroyed event handler in `handle_event_loop` performs store removal + the all-windows-closed exit check**. The OHOS rework below (system-driven teardown, no reliable Destroyed event, ExitRequested dedup) lives in separate `_ohos` functions."*

   即 upstream 的记账摘除由 **OS 真实派发的 Destroyed 事件**驱动；OHOS 重构把摘除挪到了 close-request 时刻（lib.rs:5050），并把「真实关窗」替换成一个**可以失败且无人观察**的 fire-and-forget destroy——这正是缺陷引入点。主窗场景下该 destroy **必然失败**（ArkTS throw），于是「记账已删、窗口还在」成为确定性终态。

2. **app 侧 API 用法完全标准**。`on_close_requested_ohos`（lib.rs:5003-5036）完整实现了 `CloseRequested` + prevent channel 语义，与 upstream 一致；artcraft 前端调 `getCurrent().close()` 是文档化的标准 API，同样的代码在桌面平台走 upstream 路径可正常关窗。app 没有用错任何东西。

3. **ArkTS 侧拒绝主窗 destroy 本身合理**（主 UIAbility 窗不可当 sub-window 销毁，见 §5.1 第 6 条）。缺口纯在：close→destroy-window 链路没有为 id=0 路由到正确的终止能力，且 Rust 侧在失败无回滚的情况下先摘了记账。

### 5.1 代码链条（行号基于锁定 rev：tauri `46a19d8` / openharmony-ability `cdd3ef6`）

1. 前端 `close()` → `Message::Window(id, WindowMessage::Close)` → `on_close_requested_ohos` → **`on_window_close_ohos`**（`crates/tauri-runtime-wry/src/lib.rs:5043`）。该路径不走 drain（doc/OHOS窗口遗留问题.md 问题一的「三类关窗发起者」表第一行），是**主窗上最常见的关窗路径**。
2. **lib.rs:5050 —— 无条件先摘除 store 条目**（发生在 destroy 之前，且不看 destroy 结果）：
   ```rust
   // Remove window entry from WindowsStore (idempotent)
   let removed = windows.0.borrow_mut().remove(&window_id);
   ```
3. lib.rs:5069-5076 —— fire-and-forget 异步 `destroy_window(ohos_id)`：失败**无人观察、无人回滚**：
   ```rust
   ohos_window_spawn("destroy_window", async move {
     OHOS_WINDOW_CLIENT
       .get()
       .ok_or_else(|| napi_ohos::Error::from_reason("WindowClient not init"))?
       .clone()
       .destroy_window(ohos_id)
       .await
   });
   ```
4. lib.rs:5090-5093 —— 向 app 派发 `WindowEvent::Destroyed`（此时窗口实际还在 —— 事件内容与事实不符）。
5. lib.rs:5113-5117 —— 注释假设 *"On OHOS, the system has already started the destruction flow (LoopDestroyed)"*。当 destroy 失败时该假设不成立：LoopDestroyed 不会来，`ControlFlow::Exit` 不设置，进程不退出。
6. **ArkTS 侧**（`Eulogizethesun/openharmony-ability` @ `cdd3ef6`，`plugins/window/src/main/ets/WindowPlugin.ets:880-882`）对 `windowId === 0` **直接 throw**：
   ```typescript
   if (action === "destroy-window") {
     if (request.windowId === 0) {
       throw new Error("Cannot destroy the main Ability window (id 0)");
     }
   ```
   主 UIAbility 窗按设计不可当 sub-window 销毁——这本身合理；问题在 Rust 侧没有为此分支做任何处理。
7. 终态：**OS 窗口活着 + 渲染管线活着 + 进程活着，但 `WindowsStore` 已空**。
8. 此后所有 `Message::Window`（getter 与命令 alike）在 `handle_user_message`（lib.rs:3675-3684）lookup miss —— `if let Some((Some(window), ...))` 不命中，**tx 被静默 drop**。getter 侧表现为 `FailedToReceiveMessage`（`getter!` 宏 lib.rs:288-295：`send_user_message` 成功、`rx.recv()` 失败 = tx 被丢）；命令类消息（minimize 等）则**无声消失**——这正是"点击到达 web 但 Rust 侧无动作"的机制。

### 5.2 两边设计意图脱节（bug 的本质）

- Rust 侧注释（lib.rs:5056-5057）声称：*"destroy_window (NAPI→ArkHelper.closeWindow) actually destroys the OS window (Float: win.destroyWindow(); **UIAbility: context.terminateSelf()**)."*
- ArkTS 侧实际（openharmony-ability @ `cdd3ef6`）：destroy-window 分支 `id=0` 直接 throw，**注释声称的 terminateSelf 路径并未接在这条链上**。
- 补充事实：仓内其实已有主窗终止能力——`ohos.app-control` 插件的 `terminate` 动作（Rust 侧 `AppControlExt::terminate`，ArkTS 侧 `AppControlPlugin.ets:93`）。但注意两点：① 它**没有被 close→destroy-window 链路复用**；② 在锁定 rev `cdd3ef6` 里它的实现是 `process.ProcessManager.exit(code)`——openharmony-ability 更新的 revision 已将其替换为 graceful `ctx.terminateSelf()` 并注明 *"the previous implementation called process.ProcessManager.exit(code), which appspawn intercepts and converts to SIGABRT — every terminate left a cppcrash record"*。即主窗优雅退出的正确姿势在 fork 家族里已经演进出来，只是 close 链路没接上。
- 综上：Float 子窗的 close 路径完整闭环；**主 UIAbility 窗的 close 路径两边都没接通**，且失败后无任何回滚——store 摘除却先于一切发生了。

## 6. 修复建议（按优先级）

1. **destroy 成功后再摘 store（治本）**：把 lib.rs:5050 的无条件 `remove` 改为「先发 destroy、等待结果、成功才 remove + 派发 `Destroyed` + 判 all-closed」。失败则保留条目并记日志——窗口命令继续可用，本 bug 直接消失。需要把 fire-and-forget 的 `ohos_window_spawn` 换成可等待结果的形式（或经既有回执通道）。
2. **主窗 close 走 `terminateSelf()`（语义正确，且能力已在仓内）**：UIAbility 主窗（ohos_id=0）的 close 正道就是 Rust 注释里声称的 `context.terminateSelf()`。两条接线途径：① 在 openharmony-ability `WindowPlugin.ets` 的 `destroy-window` 分支为 `id=0` 增加 terminateSelf 路径；② tauri 侧对主窗 close 改发 `ohos.app-control/terminate` 桥命令（复用已有 `AppControlExt::terminate`）。**注意**：接线时需同步升级到已含 graceful terminateSelf 的 openharmony-ability revision——锁定 rev `cdd3ef6` 的 terminate 仍是 `ProcessManager.exit`（appspawn 转 SIGABRT，每次退出留 cppcrash 记录）。与方案 1 可叠加（先保证记账一致，再补主窗语义）。
3. **最小止血（回滚）**：保持现有执行顺序，但在 destroy 失败的回调里把窗口条目放回 `WindowsStore`。实现最小，但 `Destroyed` 事件已发出（app 侧状态机已被误导），只救后半场。

### 顺带发现（同一链路的相关缺口，建议一并看）

- `ExitRequested` 已触发且未 prevent，但进程不退出（tao-ohos 循环 exit 不生效）——与本 bug 叠加成「进程永远活着但窗口命令全死」的终态；
- destroy 失败时 `WindowEvent::Destroyed` 也已派发（lib.rs:5090）——app 侧（如窗口配置保存逻辑）被误导；
- `doc/OHOS窗口遗留问题.md` 问题一写「**单窗口应用完全不受影响**」——本 bug 恰是单主窗场景，建议收录为新问题（可引用本报告）。

## 7. 附：疑似第二触发路径（未定位，供参考）

同一应用实例（pid 7981）曾观测到一次**无 close 点击**的自发僵尸化：minimize/restore 后约 17 分钟空闲，再次探测时已处于僵尸态（错误环已运行）。已用隔离实验排除两个候选：
- minimize → `aa start` restore 循环：复现后 0 错误，**排除**；
- `power-shell suspend` → `wakeup`：复现后 0 错误，**排除**。

触发原因未定位。若修复方案 1 落地（destroy 成功才摘 store），该路径理论上也应一并免疫，但不排除另有入口。

## 8. 复现材料

- 应用：artcraft HAP（可提供）；亦可换任意「单主窗 + 前端调 `getCurrent().close()`」的 Tauri 应用验证；
- 判据：§3 五步 + §4 时间线；
- 日志原文、截图证据可提供。
