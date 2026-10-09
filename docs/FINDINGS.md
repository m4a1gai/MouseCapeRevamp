# Mousecape 在 macOS 26 上到底坏在哪

实测环境：macOS 26.6.2 (25G83)，Apple Silicon (arm64)，Command Line Tools 26.5。

## 结论先说

机制没坏。**只有 9 个 `com.apple.coregraphics.*` 系统光标被锁死**，其中实际有美术资源、用户看得见的是 **Arrow（箭头）** 和 **IBeam（文本光标）**。因为箭头占了日常可见度的绝大部分，锁掉它就让整个 Mousecape 看起来"完全没反应"。

其余 41 个 `com.apple.cursor.N` 光标**完全可以替换**，并且是全局、跨进程、进程退出后依然生效的。

## 排查过程

### 1. 私有接口还在

`CGSRegisterCursorWithImages` 等符号在 CoreGraphics 中仍然存在（实际 re-export 到 `SkyLight.framework` 的 `SLSRegisterCursorWithImages`）。`CoreCursor*` 系列在 `HIServices`（经 ApplicationServices）中，不在 SkyLight——这也是最初探测时误判"丢失"的原因。

原版头文件里的函数签名在 macOS 26 上**依然正确**：

```c
CGError CGSRegisterCursorWithImages(CGSConnectionID cid, char *cursorName,
    bool setGlobally, bool instantly, CGSize cursorSize, CGPoint hotspot,
    NSUInteger frameCount, CGFloat frameDuration, CFArrayRef imageArray, int *seed);
```

注意参数顺序与常见的猜测不同（size/hotspot 在 frameCount 之前）；用错顺序会直接段错误。

### 2. 调用"成功"但什么都没发生

对 `com.apple.coregraphics.Arrow` 注册新图像：

- 返回值 `kCGErrorSuccess`（0）
- `seed` 出参没被写入，保留着 `0xAAAAAAAA` 毒值
- `CGSCurrentCursorSeed()` 不变
- 回读 `CGSCopyRegisteredCursorImages` 仍是原版 28x40 箭头

**无声失败**——这正是"没有任何报错但就是不生效"的来源。

### 3. 不是 stub，也不是客户端拦截

反汇编 `SLSRegisterCursorWithImages`：它是个薄包装，把 x7 和一个栈参数置 0 后尾调 `SLSRegisterCursorWithImages2`，后者真实地做色彩空间转换、位图绘制，然后通过 MIG 发给 WindowServer。客户端没有任何名字校验，**拦截发生在 WindowServer 内部**。

穷举那两个额外参数（x7 × stack 各 5 个取值，共 25 组，逐个独立进程执行避免崩溃传染）全部无效；同一套代码对 `com.apple.cursor.13` 做对照则每次都成功。

### 4. 锁定范围的精确边界

`CGSRemoveRegisteredCursor` 给出了最干净的证据：

| 目标 | 删除结果 | 注册结果 |
|---|---|---|
| `com.apple.coregraphics.Arrow` | 错误 **1000** | 静默忽略 |
| `com.apple.cursor.13` | 成功，大小归 0 | **生效** |

被锁的恰好是 `CGSCursorNameForSystemCursor(0...8)` 返回的那 9 个名字，即"系统定义光标"。规则很干净：**系统定义的锁死，其余自由**。

### 5. AppKit 的实际解析路径

断点追踪 `SLSSetRegisteredCursor`，得到 NSCursor → 注册名的真实映射：

```
arrowCursor                  -> com.apple.coregraphics.Arrow    🔒
IBeamCursor                  -> com.apple.coregraphics.IBeam    🔒
pointingHandCursor           -> com.apple.cursor.13             ✅
closedHandCursor             -> com.apple.cursor.11             ✅
openHandCursor               -> com.apple.cursor.12             ✅
crosshairCursor              -> com.apple.cursor.20             ✅
operationNotAllowedCursor    -> com.apple.cursor.3              ✅
dragLinkCursor               -> com.apple.cursor.2              ✅
dragCopyCursor               -> com.apple.cursor.5              ✅
contextualMenuCursor         -> com.apple.cursor.24             ✅
disappearingItemCursor       -> com.apple.cursor.25             ✅
IBeamCursorForVerticalLayout -> com.apple.cursor.26             ✅
resizeLeft/Right/LeftRight   -> com.apple.cursor.17/18/19       ✅
resizeUp/Down/UpDown         -> com.apple.cursor.21/22/23       ✅
```

只有前两行是锁的。

### 6. 端到端验证

注册自定义图像到 `com.apple.cursor.13`，在真实窗口上悬停并截图（`screencapture -C` 带光标），确认屏幕上渲染的就是自定义图像。随后用真实素材重复验证通过。

## 其他实测结论

- **代表图数量变了**：现代 macOS 的箭头有 **4 个代表图（1x / 2x / 5x / 10x）**，为的是"辅助功能 → 指针大小"滑块。Mousecape 时代只有 1x/2x，所以老主题在放大指针时会糊。本项目会按源图分辨率额外生成原生倍率代表图。
- **帧数上限**：系统自带 Wait 光标有 30 帧，说明原版代码里 24 帧的硬限制偏保守；但为稳妥仍按 24 帧抽样。
- **持久性**：注册是全局的，注册进程退出后依然生效（已用独立 writer/reader 进程验证），但不跨注销/重启。
- **还原**：`CoreCursorUnregisterAll` 可干净清除全部替换，包括自定义名字的注册。
- **全局隐藏光标不可行**：后台进程调用 `CGSHideCursor` 返回 0 但截图逐字节相同，所以"隐藏系统箭头 + 覆盖层自绘"这条替代路线并不可靠。

## 对"能不能救回箭头"的回答

不能，至少不能用这套机制。已验证排除的路线：

1. 两个未公开参数的全部组合 — 无效
2. 先 `CGSRemoveRegisteredCursor` 再注册 — 删除本身就被拒绝（错误 1000）
3. `setGlobally` / `instantly` 的各种组合 — 无效
4. 补齐 4 个代表图、对齐原生尺寸 28x40 — 无效
5. 覆盖层方案 — 无法全局隐藏系统光标，且在截图、登录窗口、部分全屏应用中会失效

能改箭头的只剩系统自带的「辅助功能 → 显示 → 指针」填充色/描边色/大小，那只能改颜色和尺寸，改不了形状。
