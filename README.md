# RedmiGallery

用 Mac 直连安卓手机看照片：**插上数据线就能翻，不拷贝整个相册，不装手机助手。**

纯键盘操作 —— 方向键翻页、`Del` 删除（先备份再删）、`+/-` 缩放、`L` 开列表。
16 000 张照片的相册翻页平均 **33 ms**，冷启动 0 崩溃，内存恒定。

> macOS / Swift / AppKit 实现。Windows 11 移植请见 [docs/PORTING-SPEC.md](docs/PORTING-SPEC.md)。

---

## 它解决什么问题

macOS 上看安卓手机的照片通常只有两条路：装厂商的手机助手（体积大、后台常驻、广告），
或者把整个相册同步到「照片」App（几万张 HEIC 拷一遍，硬盘直接少几十 GB）。

RedmiGallery 走第三条路：**通过 adb 只读地按需取图**。缩略图不用手机生成，
列表直接从 Android 的 `MediaStore` 数据库查出来，原图用 `exec-out cat` 流式拉取，
看完的图片只在内存/本地缓存里留一份。手机那头一个字节都不改。

## 特性

- **只读默认**：除删除动作外不向手机写任何东西；删除也强制「先备份、备份失败绝不删」
- **两级解码**：浏览时用低分辨率快速出图，停留 0.8 s 或放大时才补全分辨率，切换时视觉不跳
- **虚拟列表**：侧栏照片列表只绘可见行，16 000 张与 47 张内存占用一致
- **视频直出**：不用静态缩略图，先拉文件头 3 MB 抽首帧，够用就不拉全文件
- **输入全可配**：7 个指针事件 × 15 个动作的独立映射表，含冲突检测
- **FSViewer 风格滚轮缩放**：向上放大、向下缩小、以指针为锚点、平滑无限级
- **10 套内置自检**：`--zoom-test` 等，改完代码跑一遍就知道有没有退化

## 快速开始

前置：macOS 12+、[adb](https://developer.android.com/tools/releases/platform-tools)（`brew install android-platform-tools`）、
手机开启「开发者选项 → USB 调试」，插线后在手机上点「允许」。

```bash
git clone <this-repo> redmi-gallery
cd redmi-gallery/macos
./build.sh --install       # 编译 + 装到 ~/Applications + 建命令
redmi-gallery              # 启动
```

也可以直接用仓库里预编译好的 `macos/RedmiGallery.app`（通用二进制 arm64 + x86_64，ad-hoc 签名，
首次打开需在「系统设置 → 隐私与安全性」里点「仍要打开」）。

## 键盘与鼠标

| 操作 | 默认行为 |
|---|---|
| `←` `→` / `↑` `↓` | 上一张 / 下一张 |
| `Home` / `End` | 第一张 / 最后一张 |
| `Del`（连按两次） | 删除当前：先备份到回收站，成功后立刻跳下一张 |
| `+` `-` / `=` | 按 `zoom_step` 放大 / 缩小（指针为锚点） |
| `0` | 适配窗口 |
| 双击图片 | 放大到原图 100% |
| 双击后再次双击 | 还原为全图 |
| 右击 | 还原为全图 |
| 滚轮 | 向上放大 / 向下缩小（指针为锚点，不翻页） |
| `Shift` / `Alt` + 滚轮 | 未放大时翻页，放大后平移 |
| `L` | 显示 / 隐藏照片列表 |
| `F` / `⌃⌘F` | 全屏 |
| `Space` / `P` | 视频播放 / 暂停 |
| `,` | 打开设置窗口 |

所有指针事件都可以在设置里重新映射（见 [docs/INPUT-MAP.md](docs/INPUT-MAP.md)）。

## 配置

配置文件 `~/.config/redmi-gallery.conf`，程序内 `,` 键打开的设置窗口会写同一份文件。
完整键值说明见 [docs/CONFIG.md](docs/CONFIG.md)，默认值样例见
[`macos/config.sample.conf`](macos/config.sample.conf)。

常改的几个：

```ini
prefetch = 5            # 预读前后各几张（0~10）
media_filter = all      # all / images / videos
wheel_zoom_sensitivity = 0.01
backup_dir = ~/Pictures/红米相册回收站
delete_confirm = 2.5    # 两次 Del 之间的等待秒数
```

## 自检

```bash
bin=~/Applications/RedmiGallery.app/Contents/MacOS/RedmiGallery
$bin --filter-test        # 20 项：media_filter 真值表
$bin --zoom-test          # 111 项：缩放几何、锚点不漂移、边界夹取
$bin --wheel-zoom-test    # 69 项：滚轮方向、限幅、死区、不触发翻页
$bin --input-map          # 控制台打印完整映射表与冲突报告
$bin --config-ui-test     # 59 项：设置窗口控件与配置一致
$bin --list-test          # 18 项：虚拟列表行高、命中、滚动
$bin --backup-test        # 6 项：备份失败绝不删除
$bin --delete-ux-test     # 24 项：乐观删除与回滚
$bin --prefetch-test      # 6 项：预读窗口随索引滑动
$bin --dump               # 列出设备、张数、过滤结果
```

## 关于 Windows 11

**代码不能直接搬，但设计可以整套搬。**

- Swift + AppKit 在 Windows 上没有运行时，`main.swift` 一行都编译不过；
- 真正值钱的是**已经跑通的规格**：锚点缩放公式、两级解码的时序、备份优先的删除状态机、
  7×15 的输入映射、10 套验收标准 —— 这些与平台无关，全部整理在
  [docs/PORTING-SPEC.md](docs/PORTING-SPEC.md)；
- 推荐做法是 **C# / .NET 8 + WPF 重写界面层，按 spec 逐条对齐**，而不是让模型「照着 Swift 瞎猜」。
  现成的提示词在 [prompts/windows-rewrite.md](prompts/windows-rewrite.md)，可直接粘给任意大模型。

## 许可

MIT。见 [LICENSE](LICENSE)。
