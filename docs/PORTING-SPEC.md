# Windows 11 移植规格

> 这份文档回答一个问题：**macOS 版 RedmiGallery 能不能在 Windows 11 上做出来？怎么搬？**

---

## 0. 结论先行

| 问题 | 答案 |
|---|---|
| 能不能实现？ | **能，功能可以 1:1 复刻。** 整条链路（adb → MediaStore → 按需拉原图 → 原生渲染）在 Windows 上全都有等价物，而且 adb 在 Windows 上是官方一等公民。 |
| 代码能直接搬吗？ | **不能，一行都不行。** Swift + AppKit 在 Windows 上没有运行时，`main.swift` 无法编译，UI 层的每个类都要换实现。 |
| 那搬什么？ | **搬规格。** 这个项目 80% 的难度不在写代码，在于「锚点缩放不漂移」「备份优先删除」「两级解码不闪」这些踩出来的结论。它们与平台无关，就是这份文档。 |
| 让大模型重写靠谱吗？ | **靠谱 —— 但前提是喂规格，而不是喂 Swift 源码。** 详见第 6 节。 |

推荐技术栈：**C# / .NET 8 + WPF**（理由见第 2 节）。

---

## 1. 三层架构（平台上唯一不变的东西）

```
┌─────────────────────────────────────────────────┐
│  视图层  单张查看 + 虚拟列表 + 缩放/平移 + 输入映射  │  ← 100% 重写
├─────────────────────────────────────────────────┤
│  解码层  两级解码 / 预读队列 / LRU 缓存 / 视频抽帧   │  ← 概念照搬，API 换
├─────────────────────────────────────────────────┤
│  数据层  adb 进程管理 / MediaStore 查询 / 流式拉取   │  ← 逻辑照抄，改动最小
└─────────────────────────────────────────────────┘
```

**数据层几乎可以逐行翻译**。它只做四件事，全都是「起一个 adb 子进程，读它的输出」：

1. `adb devices` 找设备
2. `adb shell content query --uri content://media/external/{images,video}/media --projection _id:date_modified:_size:duration:_data --sort "date_modified DESC"` 拿列表
3. `adb exec-out cat '<path>'` 拿原图字节
4. `adb shell dd if='<path>' bs=1048576 count=3` 拿视频头部

第 2 步的输出格式是 `Row: 0 _id=123, date_modified=1700000000, _size=2048000, _data=/storage/emulated/0/DCIM/Camera/IMG_1.jpg`，
解析规则：`_data=` 必须放在 projection 最后（它的值里可能含逗号），按 `_data=` 切一刀取到行尾就是路径。

---

## 2. 技术选型：为什么是 WPF 而不是别的

| 方案 | 翻页性能 | 大图缩放 | 开发成本 | 8 GB 机器内存 | 结论 |
|---|---|---|---|---|---|
| **C# / .NET 8 + WPF** | 好（WIC 硬件解码） | 好（`ScrollViewer` + 尺寸缩放，几何可控） | 中 | ~600 MB | **推荐** |
| WinUI 3 | 好 | 一般（`ScrollViewer` 行为不如 WPF 可控） | 中高（Windows App SDK 工具链） | ~700 MB | 可用但没必要 |
| Electron + `<img>` | 一般 | 差（超大图会撞 GPU 纹理上限） | 低 | 800 MB+ | 不推荐 |
| Tauri + WebView2 | 一般 | 差（同上） | 低 | 400 MB | 原型可以，量产后悔 |
| Python + PyQt | 差（GIL + PIL 解码慢） | 一般 | 低 | 700 MB+ | 不推荐 |
| C++ + Qt | 最好 | 最好 | 高（3 倍工作量） | 300 MB | 只有追求极致才选 |

WPF 的关键优势是 **`ScrollViewer` 的 offset 是设备无关单位、可精确读写**，
这让 macOS 版那套「算出的 origin == 显示的 origin」的锚点公式可以原样落地 —— 见 3.2。

---

## 3. 逐模块映射

### 3.1 数据层：adb 进程

| macOS（Swift） | Windows（C#） | 注意 |
|---|---|---|
| `Process()` + `executableURL` | `new Process { StartInfo = new ProcessStartInfo { FileName = "adb.exe", RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true } }` | `CreateNoWindow = true` 必须加，否则每次拉图闪黑框 |
| `FileHandle.readDataToEndOfFile()` | `p.StandardOutput.BaseStream.CopyToAsync(memStream)` | **绝对不能用 `StreamReader`**。它会按 UTF-8 解码二进制，PNG/JPEG 直接被破坏成乱码 |
| `DispatchSemaphore.wait(timeout:)` | `await p.WaitForExitAsync(cts.Token)` + `p.Kill(entireProcessTree: true)` | 超时必须 `Kill` 并 `await WaitForExitAsync()` 回收，否则每超时一次留一个僵尸 adb（macOS 版在这上面栽过） |
| `Adb.bin` 探测路径 | 按序找：`%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` → `C:\platform-tools\adb.exe` → `PATH` 里的 `adb` | 建议同时允许配置项 `adb_path` 覆盖 |
| `exec-out cat '<path>'` | 完全相同 | 路径里的空格靠单引号，Android shell 认 |

**Windows 特有的两个坑：**

- adb server 首次启动会弹 Windows 防火墙授权框。程序启动时如果 `adb devices` 卡住 > 5 s，
  应提示「请在弹窗里允许 adb 访问网络」。这不是 bug。
- `adb.exe` 路径含空格时，`FileName` 不要带引号（`ProcessStartInfo` 自己处理），
  但 `Arguments` 里传的 Android 侧路径要带引号。

### 3.2 视图层：缩放与锚点（**整个移植最容易翻车的地方**）

macOS 版用的是 `NSScrollView.magnification` + 自定义 `NSClipView`。WPF 没有 magnification，
对应做法是 **改 `Image` 的 `Width/Height`（布局尺寸），让 `ScrollViewer` 的 `Extent` 跟着变**。

几何关系：

```
Extent   = 图像逻辑尺寸 × scale          // WPF 自动
Viewport = ScrollViewer 可视区尺寸        // 固定
Offset   = 当前可见区左上角在内容中的位置
```

由 `Offset + viewportPoint = imagePoint × scale` 可得锚点不变量：

```csharp
// anchor 是相对 ScrollViewer 视口的点（鼠标位置）
// oldScale / newScale 是缩放前后的 scale
double imgX = (sv.HorizontalOffset + anchor.X) / oldScale;
double imgY = (sv.VerticalOffset   + anchor.Y) / oldScale;

ApplyScale(newScale);              // 改 Image.Width/Height
sv.UpdateLayout();                 // ★ 必须，否则 Extent 还是旧的

sv.ScrollToHorizontalOffset(Clamp(imgX * newScale - anchor.X, 0, extentW - viewportW));
sv.ScrollToVerticalOffset  (Clamp(imgY * newScale - anchor.Y, 0, extentH - viewportH));
```

**四个必须做的细节：**

1. `ScrollViewer.CanContentScroll = false`。默认的 `true` 是「按项滚动」，offset 单位是项而不是像素，
   公式里的除法全错。
2. `UpdateLayout()` 不能省。WPF 是延迟布局，改完 `Width` 立刻读 `ExtentWidth` 拿到的还是旧值，
   算出来的 offset 会偏一个「上一次缩放量」。
3. 夹取要在 `ScrollToXxxOffset` **之前**做。让 WPF 自己夹会有一次可见的回弹，
   在四角连续缩放时表现为「图抖一下」。
4. 居中不能靠 `HorizontalAlignment=Center` 一层搞定：内容小于视口时它生效，
   大于视口时失效。正确做法是 `fitScale = min(viewportW/imgW, viewportH/imgH)`，
   内容尺寸 = `imgSize × scale`，并在内容小于视口时把 offset 显式设为 0。

缩放上限/下限、到边界直接 `return` 不重算 —— 照抄 macOS 版的做法，
否则在 `zoom_min`/`zoom_max` 处每次滚轮都会产生一次无效几何变更，肉眼是抖动。

### 3.3 视图层：滚轮

| 概念 | macOS | Windows / WPF |
|---|---|---|
| 事件 | `scrollWheel(with:)` | `PreviewMouseWheel`（要 `e.Handled = true` 才不会被 `ScrollViewer` 吃掉） |
| 增量 | `deltaY`（行）/ `scrollingDeltaY`（像素） | `e.Delta`，恒为 120 的倍数（一档 120） |
| 精度 | 有精确滚动（触控板） | **没有等价物**。驱动只给 120 粒度 |
| Shift+滚轮 | 系统转成水平滚动（`deltaY=0, deltaX≠0`） | 不转换，`deltaY` 照常 |

这带来一个必须接受的差异：**Windows 上滚轮只能是「一档一跳」，做不到 macOS 那种连续顺滑**。
补偿办法是把灵敏度调大，让一档的视觉变化量接近触控板连续滚动的效果：

```ini
# 每档 120 视为 1.0 个单位
# 目标倍率 = 当前倍率 × exp(1.0 × sensitivity)
wheel_zoom_sensitivity = 0.15    # macOS 默认 0.01，因为那边单位是「行」
```

如果想要更顺滑，可以拦截 `WM_MOUSEWHEEL`（`HwndSource.AddHook`），
但拿到的 wParam 高 16 位同样是 120 粒度 —— 提升有限，不值得。

`sensitivity` 之外的三条规则原样保留：死区（`|delta| < 1` 忽略）、单次限幅、**缩放时绝不累加翻页计数**。

### 3.4 解码层：两级解码

| 概念 | macOS | WPF |
|---|---|---|
| 快速解码 | `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize = quick_px` | `new BitmapImage { DecodePixelWidth = quickPx, CacheOption = BitmapCacheOption.OnLoad }` |
| 全分辨率 | `kCGImageSourceCreateImageAtIndex` | 同上去掉 `DecodePixelWidth`，再用 `decode_max_px` 夹一次 |
| 从内存解码 | `CGImageSourceCreateWithData` | `BitmapImage.StreamSource = new MemoryStream(bytes)` |
| 跨线程使用 | `CGImage` 本身线程安全 | **必须 `Freeze()`**，否则跨线程访问抛 `InvalidOperationException` |

三个 WPF 专属坑：

1. `BitmapImage` 默认 `CacheOption = OnDemand`，流被 `Dispose` 后图像就白了。
   一律 `OnLoad`，且 `EndInit()` 之后再关流。
2. 不给 `DecodePixelWidth/Height` 时，**宽高都要给**才能保证不放大。
   只给宽度，窄长图会被等比拉大。
3. 先拿尺寸再决定解码参数：`BitmapDecoder.Create(ms, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0].PixelWidth`
   只解析 header，不分配像素内存。

### 3.5 解码层：格式支持（**Windows 的真实短板**）

| 格式 | macOS | Windows 11 原生 |
|---|---|---|
| JPEG / PNG / BMP / GIF / TIFF | ✅ | ✅ |
| **HEIC / HEIF** | ✅ 系统内置 | ❌ **需要用户装「HEIF 图像扩展」**（Microsoft Store，免费） |
| WebP | ✅ | ⚠️ 需要「Webp 图像扩展」 |
| DNG | ✅（RAW） | ❌ 基本不可用 |

小米手机默认拍 HEIF，这一条不解决，**Windows 版会有一半照片打不开**。三个方案：

- **A（推荐）**：随包分发 `SkiaSharp`（NuGet，~8 MB），自己解 HEIC/WebP。
  代价是放弃 WIC 的硬件加速，但 `DecodePixelWidth` 的降采样仍可自己做。
- **B**：启动时检测 `BitmapDecoder` 能否解 HEIC，不能则弹提示引导装 HEIF 扩展，
  并提供一个「跳过无法解码的文件」开关。
- **C**：只支持 JPEG —— 不现实，等于砍掉半个功能。

无论选哪个，都要有一条「解码失败 → 显示占位卡 + 不阻塞队列」的路径。
macOS 版这块是隐式的（系统全能解），移植时容易漏。

### 3.6 视频

| 概念 | macOS | Windows |
|---|---|---|
| 播放 | `AVPlayer` + `AVPlayerView` | `LibVLCSharp.WPF`（推荐）或 `MediaElement` |
| 抽首帧 | `AVAssetImageGenerator` | 随包 `ffmpeg.exe -ss 0 -i in.mp4 -frames:v 1 -vf scale=800:-1 out.jpg` |
| 编解码 | 系统全支持 | `MediaElement` 依赖 Media Foundation，HEVC 需付费扩展；**LibVLCSharp 自带解码器，无需系统扩展** |

`LibVLCSharp` 的代价是安装包 +40 MB。如果视频不是核心场景，`MediaElement` + 提示用户装
「HEVC 视频扩展」也能用。

抽帧这件事，Windows 上**用 ffmpeg 比用 Media Foundation API 简单一个数量级**，
别去碰 `IMFSourceReader`。

### 3.7 「先备份再删除」状态机（**照抄，一行都别改**）

这是整个项目最重要的业务约束，与平台无关：

```csharp
enum DeleteOutcome { Done, BackupFailed, DeleteFailed }

async Task<DeleteOutcome> DeleteAsync(MediaItem item)
{
    // 1. 备份。backup_video=false 时视频可跳过，但图片永远备份
    if (!await BackupAsync(item))
        return DeleteOutcome.BackupFailed;      // ← 到此为止，绝不往下走

    // 2. 主路径：MediaStore 删除
    var (outText, _) = await Adb.RunAsync($"shell content delete --uri {UriOf(item)} --where _id={item.Id}");
    bool removed = outText.Contains("Deleted 1");

    // 3. 兜底：rm -f + 通知媒体扫描
    if (!removed) { /* rm -f + am broadcast MEDIA_SCANNER_SCAN_FILE */ }

    // 4. 复查！rm -f 对「文件本来就不存在」也返回 0
    var (chk, _) = await Adb.RunAsync($"shell test -e '{item.Path}' && echo STILL || echo GONE");
    if (chk.Contains("STILL")) return DeleteOutcome.DeleteFailed;

    return DeleteOutcome.Done;
}
```

UI 侧配套：删除是**乐观**的 —— 第二次按 `Del` 立刻切下一张、把当前项从列表移除，
后台跑上面的流程；返回 `BackupFailed` / `DeleteFailed` 时把项插回原位并提示。
「立刻切下一张」和「备份成功才删」并不矛盾：前者是 UI 先行，后者是数据铁律。

### 3.8 虚拟列表

```xml
<ListView VirtualizingStackPanel.IsVirtualizing="True"
          VirtualizingStackPanel.VirtualizationMode="Recycling"
          ScrollViewer.IsDeferredScrollingEnabled="False"
          ScrollViewer.CanContentScroll="True">
```

- 缩略图长边 `list_thumb_px`（默认 96），解码时给 `DecodePixelWidth`
- `Recycling` 模式下容器复用会导致**图片错位**：异步回调里必须校验
  `if (img.DataContext != capturedItem) return;` 再赋值 `Source`
- 16000 项只绘可见行，内存与 47 项一致 —— 这是硬指标，验收时用 16000 张的相册量

### 3.9 配置

配置文件格式**完全复用**（键值 + `#` 注释 + `~/` 展开），只换路径：

```
%APPDATA%\RedmiGallery\redmi-gallery.conf
```

- 读写必须显式 UTF-8（`new UTF8Encoding(false)`），默认备份目录含中文
  （`我的图片\红米相册回收站`），编码错了会创建出一堆问号目录
- `~` 展开改成 `%USERPROFILE%`
- 默认 `backup_dir` → `%USERPROFILE%\Pictures\红米相册回收站`

### 3.10 DPI 与窗口

`app.manifest` 里必须写：

```xml
<dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
```

不写的话，在 4K 屏 + 150% 缩放上，WPF 会把整个窗口按位图放大 —— 字体发虚，
而且 `PreviewMouseWheel` 拿到的坐标和实际像素差一个缩放比，**锚点会偏**。

---

## 4. 平台差异清单（做不到 1:1 的地方）

| 项 | macOS 行为 | Windows 现实 | 处理 |
|---|---|---|---|
| 滚轮平滑度 | 触控板连续像素级 | 120 粒度档位 | 调大 `sensitivity`，接受档位感 |
| Shift+滚轮 | 系统转成水平滚动 | 不转换 | `主导轴` 逻辑可简化，保留也无害 |
| ⌘ 归一 | ⌘ 归一为 Ctrl | Win 键不参与 | `wheel_cmd_as_ctrl` 在 Windows 上无意义，删掉或恒为 1 |
| HEIC | 系统内置 | 需扩展或自带解码库 | 见 3.5，**必做决策** |
| 视频解码 | 系统全支持 | 需 LibVLC 或付费扩展 | 见 3.6 |
| 窗口圆角/毛玻璃 | 原生 | Win11 有 Mica，WPF 需 P/Invoke | 可选，不影响功能 |
| 三指/触控板手势 | 系统级 | 无等价 | 不做 |

---

## 5. 工作量拆解

一个人、熟悉 C# 的前提下（括号内是「从零摸索」的倍数）：

| 模块 | 估时 | 说明 |
|---|---|---|
| adb 层 + MediaStore 解析 | 0.5 天 | 逻辑简单，主要处理进程超时回收 |
| 文件格式探测 + 解码（含 HEIC） | 1 天 | 选 SkiaSharp 的话半天 |
| 单张视图 + 缩放锚点 | **2 天** | 最容易反复的地方，见 3.2 四个细节 |
| 输入映射表（7×15）+ 冲突规则 | 1 天 | 纯逻辑，照 INPUT-MAP.md 抄 |
| 虚拟列表 + 缩略图缓存 | 1.5 天 | 回收错位是主要坑 |
| 视频播放 + 抽帧 | 1 天 | 用 ffmpeg 抽帧的话半天 |
| 备份优先删除 + 乐观 UI | 1 天 | 状态机照抄，重点在回滚 |
| 设置窗口 | 1.5 天 | 控件多但机械 |
| 自检用例移植 | 2 天 | 见第 7 节，**建议先写这个** |
| 打包 / 签名 / 首次运行引导 | 0.5 天 | adb 缺失、HEIF 缺失的引导 |
| **合计** | **约 12 人日** | 有本 spec 的前提下；没有 spec 从零设计，×2.5 |

---

## 6. 怎么让大模型写：喂规格，别喂 Swift

这是最容易被搞错的一步。

**❌ 错误做法**：「这是 4285 行 Swift，请翻译成 C# WPF」。
模型会把 AppKit 的语义硬套到 WPF 上 —— `NSClipView` 的 `bounds.size = 屏幕尺寸/magnification`
这种反直觉关系在 WPF 里根本不存在，模型会造出一个四不像的 `ScrollViewer` 子类，
然后在锚点上百般打补丁。

**✅ 正确做法**：分三轮，每轮给「规格 + 验收」：

1. **第一轮：数据层**。给第 1 节 + 3.1 节，要求实现 `AdbService`、`MediaStore`，
   验收 = `adb exec-out cat` 一个 5 MB 的 JPG 到本地，字节数与手机一致（`adb shell stat -c %s`）。
2. **第二轮：视图层**。给 3.2 / 3.3 / 3.4，要求实现缩放锚点、滚轮、两级解码，
   验收 = 第 7 节里 `zoom-test` 的 111 项、`wheel-zoom-test` 的 69 项，**先写测试再写实现**。
3. **第三轮：业务层**。给 3.7 / 3.8 / INPUT-MAP.md，
   验收 = 事件序列断言（备份失败时序列里只有 `backup`）。

现成的提示词：**[../prompts/windows-rewrite.md](../prompts/windows-rewrite.md)**，
已经按这三轮切好，可以直接贴。

一句经验：**测试用例比源码更能约束模型。** 111 项缩放自检里有一半是「边缘/四角/上下限处
锚点不漂移」，这类断言一旦写死，模型就很难糊弄过去；只给源码反而它会挑简单的路走。

---

## 7. 验收标准（可移植的部分）

macOS 版的 10 套自检里，**有 7 套是纯逻辑，可以 1:1 移植成 xUnit / NUnit**：

| 自检 | 项数 | 移植难度 | 断言什么 |
|---|---|---|---|
| `--zoom-test` | 111 | 中（依赖 WPF 度量） | 缩放后锚点屏幕坐标不变、边界夹取、fit 计算 |
| `--wheel-zoom-test` | 69 | **低（纯函数）** | 方向、限幅、死区、不触发翻页 |
| `--input-map` | 32 | **低（纯函数）** | R1~R8 八条冲突规则 |
| `--filter-test` | 20 | **低（纯函数）** | `media_filter` 真值表 |
| `--backup-test` | 6 | 低 | 备份失败时删除不被调用 |
| `--delete-ux-test` | 24 | 中 | 乐观删除、失败回滚、索引修正 |
| `--prefetch-test` | 6 | 低 | 预读窗口随索引滑动、不越界 |

不可直接移植的 3 套（`--config-ui-test` / `--list-test` / `--zoom-probe`）依赖 AppKit 的
离屏渲染与几何查询，Windows 上要重写成 UI 自动化测试或直接人工验收。

验收的**硬指标**（与平台无关，必须达到）：

- 16000 张相册，连续翻 200 次，平均每张 < 60 ms，0 次超过 300 ms
- 冷启动 20 次，0 崩溃
- 内存峰值 < 800 MB（`cache_img_mb=600` 生效时）
- 备份失败场景下，手机侧文件数量不变

---

## 8. 不要做的事

- **不要为了「跨平台」引入 Avalonia 然后两边都做不好**。这个程序的快全靠贴着原生 API 走；
  Avalonia 的 `ScrollViewer` 语义又是一套，等于再踩一遍坑。
- **不要用 `RenderTransform` 做缩放**。它不参与布局，`ScrollViewer.Extent` 不变，
  滚动条和 offset 全乱，最后一定要手写一套滚动逻辑 —— 直接改 `Width/Height` 更省事。
- **不要在前台线程做 `adb` 拉取**。一条 `exec-out cat` 在大视频上是几十秒级别的阻塞。
- **不要跳过 `Freeze()`**。跨线程 `BitmapImage` 偶发崩溃极难复现。
- **不要在 UI 线程解码全分辨率大图**。4096 px 的 PNG 解码 200 ms，翻页会明显卡顿。
