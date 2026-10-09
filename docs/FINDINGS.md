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

---

## 第二轮：还有没有别的路子换箭头

既然注册路径是死的，就换个思路——不改箭头的图，而是**让系统箭头消失，自己画一个**。这条路也堵死了，证据如下。

### 缩小到看不见？不行

`CGSSetCursorScale` 有下限：

| 设置值 | 结果 |
|---|---|
| 0.10 | 错误 1000 |
| 0.25 | 错误 1000 |
| 0.50 | 接受 |
| 2.00 / 4.00 | 接受 |

最小只能到 0.5×，28×40 的箭头缩成 14×20，依然清晰可见。而且这是**全局**缩放，会把换好的主题指针一起缩小。

### 隐藏系统光标？只在自己 App 前台时有效

这是最关键的一条。测了两种情况，截图用 `screencapture -C`（带光标）：

| App 状态 | CGDisplayHideCursor / CGSHideCursor / [NSCursor hide] | 截图结果 |
|---|---|---|
| 后台（Accessory，点击穿透） | 全部返回 0（成功） | 三张截图 **MD5 完全相同**，光标根本没隐藏 |
| 前台（Regular + activate） | 全部返回 0 | 隐藏那张**确实没有光标** |

结论：**隐藏光标的作用域是"当前活跃 App"**。而覆盖层要可用就必须点击穿透 + 不抢焦点，一旦那样就隐藏不了系统光标。

两者不可兼得：

- 抢焦点 → 能隐藏光标，但所有别的 App 都没法用了
- 不抢焦点 → 别的 App 正常，但系统箭头还在，屏幕上会出现**两个光标**

所以覆盖层方案在 macOS 26 上不成立。

### 辅助功能的指针颜色？只能改色，且不是 defaults 能驱动的

`defaults write com.apple.universalaccess cursorFillColor` 写进去之后，回读 `com.apple.coregraphics.Arrow` 的图像哈希**没有变化**——光写偏好不生效，得走系统设置界面或通知 `universalaccessd`。而且就算走通，也只能改填充色/描边色/大小，改不了形状。

## 最终结论

箭头和文本光标在 macOS 26 上**无法替换**，这不是实现问题，是系统限制。已逐一验证并排除：

1. 两个未公开参数的全部组合
2. 先 `CGSRemoveRegisteredCursor` 再注册（删除本身报错 1000）
3. `setGlobally` / `instantly` 各种组合
4. 补齐 4 个代表图、对齐原生尺寸
5. 缩放到不可见（下限 0.5×）
6. 覆盖层自绘（无法在后台隐藏系统光标）

唯一剩下的是辅助功能的颜色/大小设置，改色不改形。


---

# 更正：箭头其实能换（ArrowS / IBeamS）

> 上面两轮的结论「箭头和文本光标无法替换」**是错的**，这里更正。

错在一个很蠢的地方：我扫 `CGSCursorNameForSystemCursor` 时只扫到 ID 45 就停了，因为 9 以后连续全是 `NULL`，我以为到头了。实际上后面还有：

```
  0 -> com.apple.coregraphics.Arrow      ← 写入被静默丢弃
  1 -> com.apple.coregraphics.IBeam      ← 写入被静默丢弃
  2..8 -> IBeamXOR / Alias / Copy / Move / ArrowCtx / Wait / Empty
100 -> com.apple.coregraphics.ArrowS     ← 可写
101 -> com.apple.coregraphics.IBeamS     ← 可写
```

（线索来自 sdmj76/Mousecape-swiftUI，它扫到 128 并按名字里含 "arrow"/"ibeam" 收集同义词。）

## 实测结果

对全部 11 个名字逐个写入品红测试图再回读：

| 标识符 | 结果 |
|---|---|
| `com.apple.coregraphics.Arrow` | 忽略 |
| `com.apple.coregraphics.IBeam` | 忽略 |
| **`com.apple.coregraphics.ArrowS`** | **可写** |
| **`com.apple.coregraphics.IBeamS`** | **可写** |
| 其余 7 个 coregraphics | 可写 |

所以第一轮「9 个系统光标全部锁死」也是错的——实际只有 2 个旧名字只读。

写 `ArrowS` 之后回读 `Arrow` 会返回**新写入的图**，说明两者指向同一个光标，`ArrowS` 是可写别名。屏幕截图确认：系统箭头确实变成了自定义图像。

之前那次「写 ArrowS 没反应」的测试是我自己的测试工具有问题——`CGWarpMouseCursorPosition` 移动鼠标不触发光标刷新，和测悬停时踩的是同一个坑。改用真实 mouse-moved 事件后立刻就看到了。

## 新的坑：这几个光标无法注销

| 操作 | 结果 |
|---|---|
| `CGSRemoveRegisteredCursor(ArrowS)` | 错误 1000 |
| `CoreCursorUnregisterAll()` | 返回 0，但 ArrowS 不受影响 |
| `CoreCursorCopyImages(0)` | 返回的也是被覆盖后的图，拿不到原始副本 |

**也就是说：改了就回不去，除非把原图写回。** 所以必须在第一次写入前备份原图，这正是原版 Mousecape `backup.m` 的作用。

另外 `Wait`（沙滩球）系统原版是 30 帧，但注册接口上限 24 帧，所以还原时只能恢复 24 帧。

彻底干净的还原方式仍然是**注销重登或重启**。
