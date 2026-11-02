//! 桌面专属 `WebviewWindowBuilder` 方法在 mobile/OHOS 编译面的空操作垫片（OHOS 穿刺用）。
//!
//! Tauri 的 `fullscreen` / `always_on_top` 等 builder 方法带 `#[cfg(desktop)]`，
//! mobile/ohos 编译面上不存在（artcraft 原本只编过桌面面）。本 trait 在该面提供
//! 同名空操作：`fullscreen(false)` / `always_on_top(false)` 本就是默认值语义，
//! sora 登录窗的 `always_on_top(true)` 属可让渡项。desktop 编译面本 trait 无任何
//! 方法，调用点自动回落到固有方法，零行为影响。

use tauri::{Manager, Runtime, WebviewWindowBuilder};

pub trait DesktopOnlyBuilderCompat: Sized {
  #[cfg(any(mobile, target_env = "ohos"))]
  fn fullscreen(self, fullscreen: bool) -> Self {
    let _ = fullscreen;
    self
  }

  #[cfg(any(mobile, target_env = "ohos"))]
  fn always_on_top(self, always_on_top: bool) -> Self {
    let _ = always_on_top;
    self
  }

  #[cfg(any(mobile, target_env = "ohos"))]
  fn center(self) -> Self {
    self
  }
}

impl<'a, R: Runtime, M: Manager<R>> DesktopOnlyBuilderCompat for WebviewWindowBuilder<'a, R, M> {}
