# 输入映射

7 个指针事件，各自独立配置「动作」和「启用状态」。默认值刻意做成互不冲突、
且覆盖 FSViewer / FastStone 用户的肌肉记忆。

```
event.<事件名> = <动作>
event.<事件名>.enabled = 0|1
```

跑 `redmi-gallery --input-map` 可以打印当前生效的完整表格（含每个事件的触发条件、
配置动作、生效动作、预期结果）以及配置校验报告。

---

## 一、事件表

| 事件名 | 触发条件 |
|---|---|
| `double_click` | 左键 `clickCount == 2`，且不在「已双击」状态 |
| `double_click_again` | 左键 `clickCount == 2`，且处于「已双击」状态 |
| `right_click` | 右键抬起（`rightMouseUp`） |
| `wheel` | 滚轮，且无 Shift / Ctrl / Alt / ⌘ |
| `shift_wheel` | 滚轮，修饰键恰为 `{shift}` |
| `ctrl_wheel` | 滚轮，修饰键恰为 `{control}`（⌘ 默认归一为 Ctrl） |
| `alt_wheel` | 滚轮，修饰键恰为 `{option}` |

`double_click` / `double_click_again` 用 `dblArmed` 状态机区分：首次双击置位，
下一次双击走「再次」分支，再下一次又回到首次 —— 所以连按双击是「放大 / 还原 / 放大 / 还原」。

## 二、动作表（15 个）

| 动作 | 需要滚动位移 | 配到指针事件时降级为 | 预期结果 |
|---|---|---|---|
| `none` | 否 | 原样 | 什么都不做，事件被吞掉 |
| `zoom_100` | 否 | 原样 | 放大到原图 100%，点击点下的内容留在原位 |
| `zoom_fit` | 否 | 原样 | 回到 fitScale 并居中，整张图可见 |
| `zoom_toggle_100` | 否 | 原样 | 非 100% → 100%；已是 100% → 全图 |
| `zoom_in_step` | 否 | 原样 | 当前倍率 × `zoom_step`，锚点为指针 |
| `zoom_out_step` | 否 | 原样 | 当前倍率 ÷ `zoom_step`，锚点为指针 |
| `zoom_continuous` | **是** | `zoom_in_step` | 上滚放大 / 下滚缩小，以指针为锚点，倍率 × `exp(滚动量 × 灵敏度)`，夹在 `zoom_min…zoom_max`，不翻页 |
| `page` | **是** | `next` | 主导轴累积超过 `wheel_page_threshold` 后上/下一张（Shift 水平滚同样生效） |
| `pan` | **是** | 原样 | 按系统滚动平移可见区 |
| `page_or_pan` | **是** | 原样 | 未放大 → 按阈值翻页；已放大 → 平移 |
| `next` | 否 | 原样 | 显示 index+1 |
| `prev` | 否 | 原样 | 显示 index−1 |
| `toggle_play` | 否 | 原样 | 视频播放/暂停；图片等同下一张 |
| `fullscreen` | 否 | 原样 | 进入/退出全屏 |
| `delete` | 否 | 原样 | 第一次进入待确认，第二次执行「备份优先」删除 |

## 三、默认映射

```ini
event.double_click       = zoom_100          # 双击放大到 100%
event.double_click_again = zoom_fit          # 再双击还原
event.right_click        = zoom_fit          # 右击还原
event.wheel              = zoom_continuous   # 滚轮缩放（FSViewer 风格）
event.shift_wheel        = page_or_pan       # Shift 滚轮：未放大翻页 / 放大平移
event.ctrl_wheel         = zoom_continuous   # Ctrl 滚轮：同滚轮
event.alt_wheel          = page_or_pan       # Alt 滚轮：同 Shift
```

三个动作被复用（`zoom_fit` 2 次、`zoom_continuous` 2 次、`page_or_pan` 2 次），
这是允许的有意冗余，`--print-config` 会如实汇总成提示但不算错误。

## 四、冲突与重复处理规则

| 规则 | 内容 |
|---|---|
| **R1** | 同一配置键重复出现 → 最后一次生效，并给出提示 |
| **R2** | 动作值非法 / 事件名未知 → 保持默认（或忽略该行）+ 提示，不影响其它键 |
| **R3** | `event.X.enabled = 0` → 该事件完全不响应，**且不回落到其它事件**（按了 Shift+滚轮不会变成普通滚轮） |
| **R4** | 修饰键精确匹配优先；组合键取最具体子集，平局顺序 `ctrl > alt > shift > 无` |
| **R5** | ⌘ 默认归一为 Ctrl（`wheel_cmd_as_ctrl = 1`）；关闭归一后 ⌘+滚轮不映射任何事件 |
| **R6** | 需要滚动位移的动作配到指针事件 → 按降级表转换（`page`→`next`，`zoom_continuous`→`zoom_in_step`） |
| **R7** | 多个事件映射同一动作 → 允许（有意冗余），仅汇总提示 |
| **R8** | `wheel_zoom = 0`（旧开关）→ 强制禁用 `event.ctrl_wheel` |

R4 的实测用例：

- `{control, shift}` → `ctrl_wheel`（最具体子集）
- `{option, shift}` → `alt_wheel`（同为两键，按 `ctrl > alt > shift` 取 alt）
- `{}` → `wheel`
- `{command}` 且归一开启 → `ctrl_wheel`；归一关闭 → 不映射

## 五、常见改法

```ini
# 讨厌右击还原，改成「下一张」
event.right_click = next

# 滚轮只想翻页，不想缩放（传统相册习惯）
event.wheel = page

# 双击走「叠档放大」（每次 ×1.5），而不是跳到 100%
event.double_click = zoom_in_step

# Alt+滚轮完全不响应
event.alt_wheel.enabled = 0
```

> 写错键名（例如 `event.doubleclick`）不会报错也不会生效。改完跑 `--input-map`，
> 看对应事件那行「生效动作」是否变成你要的，比猜键名快。
