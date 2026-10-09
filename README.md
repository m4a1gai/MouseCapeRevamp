# MouseCape Revamp

在 macOS 26 (Tahoe) / Apple Silicon 上重建的鼠标指针替换工具，是 [Mousecape](https://github.com/alexzielenski/Mousecape) 的现代重写版。

原版 Mousecape 在新系统上"失效"的原因很具体：macOS 26 把 `com.apple.coregraphics.Arrow` 和 `IBeam` 这两个旧标识符改成了**只读**——写入返回成功但数据被丢弃，所以没有任何报错，箭头却纹丝不动。而箭头恰好占了日常可见度的绝大部分，于是整个工具看起来像彻底挂了。

真正的箭头现在挂在新标识符 **`com.apple.coregraphics.ArrowS`（系统光标 ID 100）** 和 **`IBeamS`（ID 101）** 上，这两个可写，写进去就能换掉系统箭头。**所以箭头和文本光标都能换。**

> 完整的技术调查过程见 [`docs/FINDINGS.md`](docs/FINDINGS.md)。

## 能做什么

| | |
|---|---|
| ✅ 可替换 | **箭头、文本光标**、手型、抓取手、忙碌、禁止、十字、帮助、右键菜单、各种缩放/调整大小、拖拽、放大镜、沙滩球等 **50 个**光标 |
| ⚠️ 旧标识符 | `com.apple.coregraphics.Arrow` / `IBeam` 写入会被静默丢弃，程序会自动改写到 `ArrowS` / `IBeamS` |

社区现成的 `.cape` 主题都是按旧标识符写的，导入时会自动重定向到可写的变体，不用改文件。

### 还原机制（重要）

CoreGraphics 那几个系统光标**无法注销**——`CGSRemoveRegisteredCursor` 对它们报错 1000，`CoreCursorUnregisterAll` 也不管。一旦写进去，唯一的退路是**把原图写回去**。

所以程序在第一次改某个系统光标之前，会先把它的原始图像存到 `~/Library/Application Support/MouseCapeRevamp/Stock.cape`，「还原默认」就是从这里写回。

如果你的备份是在已经换过光标的状态下抓的，可以先注销重登（系统光标回到原始状态），再执行 `mousecape resnapshot` 重新抓一份干净的基准。

### 各个光标在哪出现

| 指针 | 什么时候出现 |
|---|---|
| 手型 | 鼠标悬停在**链接、按钮**上 |
| 忙碌 | App 正在加载 |
| 禁止 | 拖拽到无效位置 |
| 抓取手 | 按住拖动内容时 |
| 左右 / 上下箭头 | 拖拽窗口边缘、分隔线、表格列宽 |
| 十字 | 截图框选、部分编辑器 |
| 放大镜 | 预览、地图里缩放 |

App 里的**「测试指针」**标签页把当前生效的指针全部列出来，鼠标移上去就能直接看到真实效果，省得满系统找。

## 支持的素材格式

直接把文件夹拖进窗口即可，会自动按名字匹配：

- **Windows `.ani`** 动态光标（含热点与帧率）
- **动图 GIF**（逐帧与延时自动解析）
- **编号帧序列文件夹**，如 `frame_00_delay-0.01s.gif`
- **`.cape`** 原版 Mousecape 主题文件
- `.cur` / `.png` / `.ico`

名字匹配同时支持 Windows 方案名（`Link`、`Busy`、`Unavailable`…）和中文名（`链接选择`、`忙`、`不可用`、`精准选择`…），也能处理 `帮助1`、`正常选择-重制` 这类带后缀的命名。

## 多配置切换

左侧栏管理配置，点一下即切换，切换时会先清掉上一套再应用，不会混在一起。

- **macOS 默认指针** 是内置项，永远在第一位，点它即还原系统默认。
- 导入一套指针后点「保存为配置…」存下来，之后随时切回。
- 右键配置可删除。

配置以 `.cape` 格式存放在 `~/Library/Application Support/MouseCapeRevamp/Profiles/`，和社区主题同格式，可以直接拷出去分享。

## 调整大小

顶部有大小滑块，范围 16–64 pt。拖动时：

- **实际大小**方块按真实点数渲染，旁边并排放了**系统箭头**作参照，所以看到的就是最终落到屏幕上的尺寸；
- 松手约 0.25 秒后会自动重新应用，真实指针当场变大变小，不用反复点「应用」。

大小设置和当前配置由 App 与命令行共用（存在 `com.mousecaperevamp` 偏好域），所以两边看到的状态一致。命令行可以 `mousecape use <名称> --size 48`。

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

mousecape profiles              # 列出所有配置
mousecape save <文件夹> <名称>   # 把文件夹存成一个配置
mousecape use <名称>            # 切换到某个配置（含「macOS 默认指针」）
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
- **保持源图宽高比**：按最长边缩放到 32pt，不会把 96×96 的方图压成 28×40。
- `.ani` / `.cur` 自带热点就用它自带的；GIF 和帧序列没有热点信息，则按该指针在 macOS 上的热点比例推算（这样缩放、十字这类指针才会对准中心）。

## 已知限制

- 箭头和文本光标无法替换，这是系统层面的限制，任何 App 都绕不过（已逐一验证，见调查文档）。
- 光标替换不会自动持久化到下次登录，需要时可把 `mousecape use <配置名>` 做成登录项。
- 少数自绘指针的 App（部分游戏、远程桌面）不走系统指针，不受影响。
