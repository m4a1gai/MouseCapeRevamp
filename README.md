# MouseCape Revamp

在 macOS 26 (Tahoe) / Apple Silicon 上重建的鼠标指针替换工具，是 [Mousecape](https://github.com/alexzielenski/Mousecape) 的现代重写版。

原版 Mousecape 在新系统上"失效"的真正原因不是整个机制挂了，而是**只有箭头和文本光标被系统锁死了**——而这两个恰好是最显眼的，所以看起来像完全不工作。其余约 40 个光标至今仍可正常替换，本项目就是把这部分做扎实。

> 完整的技术调查过程见 [`docs/FINDINGS.md`](docs/FINDINGS.md)。

## 能做什么

| | |
|---|---|
| ✅ 可替换 | 手型、抓取手、忙碌、禁止、十字、帮助、右键菜单、各种缩放/调整大小、拖拽、放大镜等 **41 个**光标 |
| ❌ 不可替换 | **箭头 (Arrow)** 和 **文本光标 (I-Beam)**，外加沙滩球等 9 个系统保留光标 |

被锁的光标在界面里会标成 🔒，应用时自动跳过，不会静默失败。

## 支持的素材格式

直接把文件夹拖进窗口即可，会自动按名字匹配：

- **Windows `.ani`** 动态光标（含热点与帧率）
- **动图 GIF**（逐帧与延时自动解析）
- **编号帧序列文件夹**，如 `frame_00_delay-0.01s.gif`
- **`.cape`** 原版 Mousecape 主题文件
- `.cur` / `.png` / `.ico`

名字匹配同时支持 Windows 方案名（`Link`、`Busy`、`Unavailable`…）和中文名（`链接选择`、`忙`、`不可用`、`精准选择`…），也能处理 `帮助1`、`正常选择-重制` 这类带后缀的命名。

## 构建

只需要 Command Line Tools，不需要完整 Xcode：

```sh
make          # 构建 App 和命令行工具
make run      # 构建并打开 App
```

产物：`MouseCape.app` 和 `build/mousecape`。

## 使用

### 图形界面

```sh
open MouseCape.app
```

把素材文件夹拖进窗口 → 确认匹配结果（每行都有动画预览）→ **Apply**。
随时按 **Restore All** 一键还原。

### 命令行

```sh
mousecape list                  # 列出所有光标槽位及当前状态
mousecape apply <文件夹>         # 按名字批量应用
mousecape apply a.gif --to com.apple.cursor.13   # 指定单个光标
mousecape export <文件夹> out.cape               # 打包成 .cape
mousecape status                # 查看当前生效的替换
mousecape restore               # 还原全部系统光标
```

## 还原

替换是**全局且跨进程持久**的，但不写入磁盘——所以出问题时有三条退路：

1. 界面里点 **Restore All**，或执行 `mousecape restore`
2. 注销再登录
3. 重启

## 实现要点

- 走 `CGSRegisterCursorWithImages` 私有接口，与原版机制相同，签名已在 macOS 26 上逐个实测校对。
- **每次写入后都会回读校验**。这一点很关键：系统对被锁光标会返回"成功"然后把数据丢掉，只看返回值会被骗。
- 代表图按 1x / 2x / 原生分辨率生成，所以在"辅助功能 → 指针大小"调大时依然清晰（原版只有 1x/2x）。
- 超过 24 帧的素材会等间隔抽帧并保持总时长不变。

## 已知限制

- 箭头和文本光标无法替换，这是系统层面的限制，任何 App 都绕不过（已逐一验证，见调查文档）。
- 光标替换不会自动持久化到下次登录，需要时可把 `mousecape apply` 做成登录项。
