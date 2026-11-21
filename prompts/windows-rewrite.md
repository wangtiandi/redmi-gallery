# 给大模型的提示词：macOS → Windows 11 重写

## 用法

在 Windows 机器上把本仓库放到工作目录，按 **R1 → R2 → R3** 的顺序分三轮喂给模型。
每轮结束先跑验收再进下一轮，**不要一次性把三轮合成一段**——合成后模型会先赶 UI，
把最容易出错的缩放几何糊过去。

每一轮都要求模型「先把测试写完，再写实现」。这是这份提示词里最重要的一句话。

可用模型：Claude / GPT / DeepSeek / Qwen 均可，差别不大，关键是规格给全。

---

## 总纲（每一轮都先贴这段）

```text
你要把仓库里的 RedmiGallery（macOS / Swift / AppKit 实现，4285 行）重写成
Windows 11 桌面程序，技术栈固定为 C# / .NET 8 + WPF，不要换框架，不要提议 Avalonia/MAUI/Electron。

先读这两份文档，它们比源码重要：
- docs/PORTING-SPEC.md   ← 平台映射、每个坑的具体做法
- docs/CONFIG.md         ← 配置项定义（格式必须在 Windows 上完全兼容）

源码 macos/main.swift 只作为「参考实现」看待，不要逐行翻译：
AppKit 的 NSScrollView/NSClipView 语义在 WPF 里没有对应物，
照抄会造出一个错误的 ScrollViewer 子类。

硬约束（违反任何一条都算失败）：
1. 只读手机。除「删除」动作外，不向手机写任何数据。
2. 删除必须先备份；备份失败时绝不调用删除。代码里不允许存在
   「删除成功但备份失败」这个状态。
3. 所有 adb 调用走异步 + 超时 + 杀进程树回收，不允许无限等待。
4. 跨线程使用的 BitmapImage 必须 Freeze()。
5. 配置文件格式与 macOS 版完全兼容（同一个 .conf 语法），只换存放路径。

输出要求：完整可编译的代码，不要省略号，不要「此处略」。
每个文件给出完整路径。写完一个模块就说明它的验收方式。
```

---

## R1 · 数据层

```text
本轮只做数据层，不做任何 UI。

实现：
1. AdbService
   - 自动探测 adb.exe：%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe
     → C:\platform-tools\adb.exe → PATH
   - RunAsync(args, timeout) 返回 (stdout bytes, exitCode)
   - 二进制读取必须用 Process.StandardOutput.BaseStream，
     禁止使用 StreamReader（会破坏 JPEG/PNG 字节）
   - 超时后 Kill(entireProcessTree: true) 并 await WaitForExitAsync 回收
   - ListDevicesAsync() 解析 adb devices，取状态为 device 的第一个序列号
2. MediaStore
   - QueryAsync(serial, kind)：
     adb shell content query --uri content://media/external/{images|video}/media
         --projection _id:date_modified:_size:duration:_data
         --sort "date_modified DESC"
   - 解析 "Row: N _id=.., date_modified=.., _size=.., duration=.., _data=/path"
     注意 _data 必须最后解析：它的值里可能含逗号，按 "_data=" 切一刀取到行尾
   - 返回 List<MediaItem> { Kind, Id, Path, Name, Date, SizeBytes, DurationMs }
   - 按 media_filter 过滤（all / images / videos），写成纯函数，便于单测
3. StreamService
   - PullBytesAsync(path, timeout)：exec-out cat '<path>' 读进 MemoryStream
   - PullHeadAsync(path, mb, dest)：exec-out dd if='<path>' bs=1048576 count=<mb>
   - PullToFileAsync(path, dest, IProgress<double>)：流式写盘，不整块进内存
   - DeleteAsync(item)：见 PORTING-SPEC 3.7，返回 DeleteOutcome 三态枚举

配置：读 %APPDATA%\RedmiGallery\redmi-gallery.conf，语法与 macos/config.sample.conf 一致
（键 = 值，# 注释，~/ 展开为 %USERPROFILE%，布尔接受 1/0/true/false/on/off/yes/no）。
必须显式 UTF-8（new UTF8Encoding(false)），默认 backup_dir 含中文。

验收（必须给出可运行的单元测试或控制台命令）：
- 拉一张 5 MB 的 JPG，落地字节数 == adb shell stat -c %s 的结果
- 断网/拔线时 PullBytesAsync 在 pull_timeout 秒内返回失败，且 Tasklist 里没有残留 adb.exe
- 16000 项的 QueryAsync 在 3 秒内返回
- 配置里写 media_filter=videos，过滤后只剩视频
```

---

## R2 · 视图层（最难，单独一轮）

```text
本轮只做单张查看：图像显示、缩放锚点、滚轮、两级解码。不做列表、不做视频、不做输入映射表。

结构：
MainWindow
└ ScrollViewer (CanContentScroll=false, HorizontalScrollBarVisibility=Auto, ...)
  └ Image (Stretch=None, 尺寸由代码控制)

缩放核心（严格按 PORTING-SPEC 3.2 实现，四个细节一个都不能少）：
- scale 是相对原图 1:1 的倍率；Image.Width = imgW * scale，Height = imgH * scale
- fitScale = min(viewportW / imgW, viewportH / imgH)
- 锚点缩放：
    imgX = (sv.HorizontalOffset + anchor.X) / oldScale
    imgY = (sv.VerticalOffset   + anchor.Y) / oldScale
    ApplyScale(newScale);
    sv.UpdateLayout();                                  // 必须
    sv.ScrollToHorizontalOffset(Clamp(imgX*newScale - anchor.X, 0, max(0, extentW - viewportW)));
    sv.ScrollToVerticalOffset  (Clamp(imgY*newScale - anchor.Y, 0, max(0, extentH - viewportH)));
- 夹取在 ScrollToXxxOffset 之前做（不能让 WPF 自己夹，会回弹）
- |newScale - oldScale| < 1e-9 直接 return（到上下限不抖动）
- newScale 夹在 zoom_min … zoom_max（默认 0.1 … 16.0，1.0 = 原图 100%）
- 内容小于视口时 offset 显式设 0（居中靠容器对齐，不靠 offset 硬算）

滚轮（PreviewMouseWheel，必须 e.Handled = true）：
- WPF 的 e.Delta 恒为 120 的倍数，一档 = 120
- 单位换算：units = e.Delta / 120.0
- 目标倍率 = 当前 × exp(units × wheel_zoom_sensitivity)，Windows 上 sensitivity 默认 0.15
- 死区：|units| < 0.02 忽略；单次限幅 ±24 units
- 缩放时绝不累加翻页计数，且不调用 base（不让 ScrollViewer 自己滚）
- 注意：Windows 不会把 Shift+滚轮转成水平滚动，主导轴逻辑可保留但不必须

两级解码：
- 快解：BitmapImage { DecodePixelWidth = quickPx, CacheOption = OnLoad }，解码后 Freeze()
- 全解：停在同一张满 full_delay（0.8s）或 scale > fitScale*1.02 时，
  后台再解一张全分辨率（上限 decode_max_px），解完用「保持当前视觉位置」的方式替换
  （记录当前 offset 与 scale，换源后还原，不能让画面跳）
- quick_px=0 时自动取窗口长边的 2 倍
- 先读 header 拿尺寸再决定解码参数：
  BitmapDecoder.Create(ms, DelayCreation, BitmapCacheOption.None).Frames[0].PixelWidth
- 格式：JPEG/PNG/BMP/GIF/TIFF 走 WIC；HEIC/HEIF/WebP 检测 WIC 是否支持，
  不支持则用 SkiaSharp 解码（若引入，写成一个 IImageDecoder 接口，WIC 与 Skia 两个实现）

验收（照 macOS 版 --zoom-test 111 项 / --wheel-zoom-test 69 项移植）：
- 在 4 个角落、4 条边、中心共 9 个位置分别做「放大→缩小→还原」，
  每次断言「锚点下的图像内容屏幕坐标偏差 < 1 px」
- 连续 20 次滚轮放大到上限，再 20 次缩小到下限，全程不崩溃、offset 不出界
- 缩放过程中不得触发翻页
- 100% 与 fit 的切换后，图像完整可见
```

---

## R3 · 业务层

```text
本轮做：输入映射表、虚拟列表、视频、备份删除、设置窗口。

输入映射（严格按 docs/INPUT-MAP.md）：
- 7 个事件：double_click, double_click_again, right_click, wheel, shift_wheel, ctrl_wheel, alt_wheel
- 15 个动作：none, zoom_100, zoom_fit, zoom_toggle_100, zoom_in_step, zoom_out_step,
  zoom_continuous, page, pan, page_or_pan, next, prev, toggle_play, fullscreen, delete
- 配置键：event.<name> = <action>  /  event.<name>.enabled = 0|1
- R1~R8 八条冲突规则全部实现（见 INPUT-MAP.md 第四节）
- 修饰键匹配用 Keyboard.Modifiers，注意 Windows 键不参与映射
- dblArmed 状态机：首次双击置位走 double_click，下一次走 double_click_again，如此往复
- 键盘用 PreviewKeyDown（ScrollViewer 会吃掉方向键，必须 e.Handled=true）

虚拟列表：
- ListView + VirtualizingStackPanel.IsVirtualizing=true + VirtualizationMode=Recycling
- 缩略图 DecodePixelWidth = list_thumb_px，异步加载，带磁盘缓存
- Recycling 复用容器必须校验 DataContext 未变再赋 Source，否则图片错位
- 16000 项时内存与 47 项一致

视频：
- 播放用 LibVLCSharp.WPF（自带解码器，不依赖系统 HEVC 扩展）
  或 MediaElement + 检测 HEVC 缺失时降级提示
- 首帧用随包 ffmpeg.exe：ffmpeg -ss 0 -i <file> -frames:v 1 -vf scale=800:-1 out.jpg
- 先拉头部 video_head_mb（3MB）抽帧，失败（moov 在尾部）再拉全文件
- 停在视频上 video_delay（1.0s）才开始拉，快速翻过就不拉
- autoplay_video=0 时停在首帧，按 P 播放

删除（严格按 PORTING-SPEC 3.7）：
- DeleteOutcome { Done, BackupFailed, DeleteFailed }，没有第四种
- 第二次按 Del：立刻切下一张 + 从列表移除（乐观），后台执行备份→删除→复查
- BackupFailed / DeleteFailed：把项插回原索引、恢复当前显示、状态栏提示
- 删除后复查：test -e '<path>' && echo STILL || echo GONE（rm -f 对不存在的文件也返回 0）

设置窗口：
- 至少覆盖 CONFIG.md 里所有可调项，分组：查看范围 / 预读与流畅度 / 视频 / 删除与备份 / 缩放 / 输入映射 / 列表
- 保存即写文件 + 立即生效（能立即生效的项）
- 输入映射用下拉框选动作，非法值要有提示

验收：
- --input-map 的 32 项规则断言全绿
- 备份失败时，事件序列里只有 ["backup"]，没有 ["delete"]
- 16000 项连续翻 200 次，平均 < 60ms，0 次 > 300ms
- 冷启动 20 次 0 崩溃
```

---

## 如果只想问「能不能做」，一句话版

```text
用 C# / .NET 8 + WPF 重写，数据层（adb 调用）几乎照抄，视图层的缩放锚点必须按
「改 Image 尺寸 + UpdateLayout + 手动 ScrollToOffset」重做，滚轮在 Windows 上是
120 粒度档位而非连续像素。HEIC 需要额外解码库（SkiaSharp）否则小米的 HEIF 照片打不开。
详细规格见 docs/PORTING-SPEC.md，约 12 人日。
```
