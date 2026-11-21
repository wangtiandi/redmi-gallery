# 配置项参考

配置文件路径：`~/.config/redmi-gallery.conf`（首次运行自动按默认值创建）。
改完**重启程序**生效，或在程序内按 `,` 打开设置窗口（设置窗口保存后立即写文件）。

格式规则：

- 一行一个 `键 = 值`，`#` 之后是注释（行尾注释也支持）
- 布尔值接受 `1/0`、`true/false`、`on/off`、`yes/no`
- 路径支持 `~/` 展开
- 同一个键写两次：**以最后一次为准**，并在 `--print-config` 的「配置校验提示」里报警
- 未知键不会报错，但会被忽略（写错键名不生效，用 `--print-config` 核对「当前生效」一行）

---

## 1. 查看范围

| 键 | 默认 | 说明 |
|---|---|---|
| `media_filter` | `all` | `all` 图片+视频 / `images` 只看图片 / `videos` 只看视频。保存后重启生效 |
| `include_video` | `1` | **旧键**。仅在 `media_filter` 未设置时生效：`0` 等于 `images` |

`media_filter` 存在时完全覆盖 `include_video`，两个都写不会冲突。

## 2. 预读与流畅度

| 键 | 默认 | 范围 | 说明 |
|---|---|---|---|
| `prefetch` | `5` | 0~10 | 预读当前照片前后各几张（只针对图片）。0 = 完全按需 |
| `prefetch_video` | `0` | 0/1 | `1` = 对预读窗口内的视频也提前抽首帧；`0` = 翻到才处理（更快） |
| `max_concurrent_pull` | `4` | 1~8 | 同时从手机拉取的任务数。调大反而更慢（抢 USB 带宽） |
| `pull_timeout` | `20` | 秒 | 单次 adb 拉取超时，超时判失败，避免 USB 卡住时永久挂起 |
| `decode_max_px` | `4096` | 像素 | 全分辨率解码上限（放大看细节时才解到这个尺寸） |
| `quick_px` | `0` | 像素 | 浏览时的快速解码长边，`0` = 自动取窗口长边的 2 倍 |
| `full_delay` | `0.8` | 秒 | 停在一张上多久后，后台补一张全分辨率 |
| `cache_img_mb` | `600` | MB | 已解码图片的内存缓存上限（LRU 淘汰） |

两级解码是翻页流畅的核心：`quick_px` 让首帧 30 ms 内出现，`full_delay` 之后再补细节。
两者都调成「一开始就全分辨率」会让 4K 大图翻页回到 300 ms/张。

## 3. 视频

| 键 | 默认 | 说明 |
|---|---|---|
| `video_thumb` | `1` | 是否生成首帧缩略图。`0` = 只显示占位卡，最省 |
| `autoplay_video` | `1` | 拉完自动播放；`0` = 停在首帧，按 `P` 播放 |
| `cache_video` | `1` | 视频缓存到本地（下次瞬间打开）；`0` = 每次现拉 |
| `cache_max_mb` | `3000` | 视频缓存上限 MB，超出按最久未看清理 |
| `video_delay` | `1.0` | 停在视频上多久后才开始拉（快速翻过就不拉） |
| `video_head_mb` | `3` | 先只拉头部这么多 MB 用来抽首帧，够用就不拉全文件 |
| `video_thumb_max_mb` | `400` | 大于此大小的视频不自动抽首帧（`0` = 不限） |
| `thumb_px` | `800` | 视频首帧缩略图长边像素 |
| `fps` | `60` | 投屏相关（scrcpy 参数） |
| `bitrate` | `40M` | 投屏相关（scrcpy 参数） |

> 已知取舍：`moov` 原子在文件尾部的视频（部分机型录制的 MP4），只拉头部无法抽帧，
> 程序会自动回退到拉全文件。600 MB 级视频会因此慢十几秒，属预期行为。

## 4. 删除与备份

| 键 | 默认 | 说明 |
|---|---|---|
| `backup_dir` | `~/Pictures/红米相册回收站` | 删除前先拷到这里 |
| `backup_video` | `1` | 删视频前是否也备份。`0` = 主动放弃备份（**唯一**允许跳过备份的方式） |
| `delete_confirm` | `2.5` | 两次 `Del` 之间的确认窗口秒数 |
| `delete_success_hint` | `0` | `1` = 删除后提示备份位置（会打断连续删除节奏） |

**铁律：先备份，备份失败就绝不删除。** 代码里没有「删除成功但备份失败」这个状态 ——
`DeleteOutcome` 只有 `done` / `backupFailed` / `deleteFailed` 三种，`backupFailed` 分支
根本不会走到 `Adb.delete`。`--backup-test` 验证的就是这条：事件序列里只有 `backup`。

## 5. 缩放

| 键 | 默认 | 说明 |
|---|---|---|
| `zoom_step` | `1.25` | 按一次 `+`/`-` 的倍率 |
| `dblclick_step` | `1.5` | `zoom_in_step` / `zoom_out_step` 动作叠加的倍率 |
| `zoom_max` | `16.0` | 最大放大倍数（`1.0` = 原图 100%） |
| `zoom_min` | `0.1` | 最小缩小倍数 |
| `wheel_zoom_sensitivity` | `0.01` | 滚轮缩放系数：目标倍率 = 当前 × `exp(滚动量 × 该系数)` |
| `wheel_page_threshold` | `8` | `page` 动作累积多少滚动位移才翻一张 |
| `wheel_zoom` | `1` | **旧开关**：`0` 会强制禁用 `event.ctrl_wheel` |
| `fit_upscale` | `1` | 图比窗口小时是否放大铺满；`0` = 按原尺寸居中不拉伸 |
| `center_image` | `1` | 画面小于窗口时是否居中；`0` = 贴左下角 |

## 6. 输入映射

见 [INPUT-MAP.md](INPUT-MAP.md)。每个事件两个键：

```ini
event.<事件名> = <动作>
event.<事件名>.enabled = 0|1
```

| 事件名 | 对应物理操作 |
|---|---|
| `double_click` | 左键双击（未处于「已双击」状态） |
| `double_click_again` | 连续第二次双击 |
| `right_click` | 右键抬起 |
| `wheel` | 滚轮（无修饰键） |
| `shift_wheel` | Shift + 滚轮 |
| `ctrl_wheel` | Ctrl / ⌘ + 滚轮 |
| `alt_wheel` | Alt / Option + 滚轮 |

| 键 | 默认 | 说明 |
|---|---|---|
| `wheel_cmd_as_ctrl` | `1` | ⌘ 归一为 Ctrl（Mac 习惯）；`0` = ⌘ 不映射任何事件 |

## 7. 照片列表

| 键 | 默认 | 说明 |
|---|---|---|
| `list_visible` | `0` | 启动时是否显示侧栏列表（运行时按 `L` 切换） |
| `list_width` | `240` | 侧栏宽度（点） |
| `list_row_height` | `64` | 每行高度（点） |
| `list_thumb_px` | `96` | 列表缩略图长边像素 |

## 8. 排查用命令

```bash
bin=~/Applications/RedmiGallery.app/Contents/MacOS/RedmiGallery

$bin --print-config   # 打印默认值 + 当前生效值 + 冲突/重复/降级提示
$bin --input-map      # 打印完整映射表（触发器、配置动作、生效动作、预期结果）
$bin --dump           # 列出已连设备、图片/视频张数、过滤后结果
$bin --dir ~/Pictures # 不起 adb，直接看本地目录（排查 UI 问题用）
```
