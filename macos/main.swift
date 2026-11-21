// 红米相册 —— 在 Mac 上用键盘浏览红米手机相册
//
// 编译：swiftc -O -o redmi-gallery main.swift -framework Cocoa -framework AVKit
// 配置：~/.config/redmi-gallery.conf（文件不存在就用下面的默认值，改完重启程序生效）
//
// 键位：← / ↑ 上一张      → / ↓ 下一张      Delete 删除（连按两次；必须先备份成功才会删）
//       P 或空格 播放/暂停视频      F 全屏      ⌘Q 退出
// 鼠标：双击 / 连续第二次双击 / 右击 / 滚轮 / Shift / Ctrl / Alt+滚轮 共 7 个事件各自独立可配
//       完整映射清单与冲突规则：redmi-gallery --input-map

import Cocoa
import AVKit
import AVFoundation

// MARK: - 输入映射

/// 可选动作全集。needsDelta 的动作依赖滚轮位移；用在指针事件上会按 pointerFallback 降级。
enum InputAction: String, CaseIterable {
    case none = "none"
    case zoom100 = "zoom_100"
    case zoomFit = "zoom_fit"
    case zoomToggle100 = "zoom_toggle_100"
    case zoomInStep = "zoom_in_step"
    case zoomOutStep = "zoom_out_step"
    case zoomContinuous = "zoom_continuous"
    case page = "page"
    case pan = "pan"
    case pageOrPan = "page_or_pan"
    case next = "next"
    case prev = "prev"
    case togglePlay = "toggle_play"
    case fullscreen = "fullscreen"
    case delete = "delete"

    var needsDelta: Bool {
        switch self {
        case .zoomContinuous, .page, .pan, .pageOrPan: return true
        default: return false
        }
    }
    /// 指针事件（双击 / 右击）没有滚轮位移，给出等价降级动作
    var pointerFallback: InputAction? {
        switch self {
        case .zoomContinuous: return .zoomInStep
        case .page: return .next
        case .pan, .pageOrPan: return .none
        default: return nil
        }
    }
    var label: String {
        switch self {
        case .none: return "无动作"
        case .zoom100: return "放大到原图 100%"
        case .zoomFit: return "还原为全图（适配屏幕）"
        case .zoomToggle100: return "100% / 全图 两态切换"
        case .zoomInStep: return "叠加放大一档"
        case .zoomOutStep: return "叠加缩小一档"
        case .zoomContinuous: return "滚轮缩放（向上放大 / 向下缩小）"
        case .page: return "滚轮翻页"
        case .pan: return "平移画面"
        case .pageOrPan: return "未放大翻页 / 放大后平移"
        case .next: return "下一张"
        case .prev: return "上一张"
        case .togglePlay: return "播放 / 暂停"
        case .fullscreen: return "全屏切换"
        case .delete: return "删除（连按两次确认）"
        }
    }
    var expected: String {
        switch self {
        case .none: return "什么都不做，事件被吞掉"
        case .zoom100: return "magnification=1.0，点击点下的内容保持原位"
        case .zoomFit: return "回到 fitScale 并居中，整张图可见"
        case .zoomToggle100: return "非 100% → 100%；已是 100% → 全图"
        case .zoomInStep: return "当前倍率 × zoom_step，锚点为指针"
        case .zoomOutStep: return "当前倍率 ÷ zoom_step，锚点为指针"
        case .zoomContinuous: return "向上滚放大 / 向下滚缩小；以指针为锚点，倍率 × exp(滚动量×灵敏度)，夹在 zoom_min…zoom_max；不翻页、不滚动页面"
        case .page: return "主导轴累积超过阈值后上/下一张（Shift 水平滚同样生效）"
        case .pan: return "按系统滚动平移可见区"
        case .pageOrPan: return "未放大→按阈值翻页；放大→平移"
        case .next: return "显示 index+1"
        case .prev: return "显示 index-1"
        case .togglePlay: return "视频播放/暂停；图片等同下一张"
        case .fullscreen: return "窗口进入/退出全屏"
        case .delete: return "第一次进入待确认，第二次执行备份优先删除"
        }
    }
}

enum InputEvent: String, CaseIterable {
    case doubleClick = "double_click"
    case doubleClickAgain = "double_click_again"
    case rightClick = "right_click"
    case wheel = "wheel"
    case shiftWheel = "shift_wheel"
    case ctrlWheel = "ctrl_wheel"
    case altWheel = "alt_wheel"

    var isWheel: Bool {
        switch self {
        case .wheel, .shiftWheel, .ctrlWheel, .altWheel: return true
        default: return false
        }
    }
    var modifiers: Set<String> {
        switch self {
        case .wheel: return []
        case .shiftWheel: return ["shift"]
        case .ctrlWheel: return ["control"]
        case .altWheel: return ["option"]
        default: return []
        }
    }
    var label: String {
        switch self {
        case .doubleClick: return "双击"
        case .doubleClickAgain: return "双击后再次双击（连续第二次）"
        case .rightClick: return "右击"
        case .wheel: return "滚轮滚动"
        case .shiftWheel: return "Shift + 滚轮"
        case .ctrlWheel: return "Ctrl + 滚轮"
        case .altWheel: return "Alt + 滚轮"
        }
    }
    var condition: String {
        switch self {
        case .doubleClick: return "左键 clickCount==2，且不在「已双击」状态"
        case .doubleClickAgain: return "左键 clickCount==2，且处于「已双击」状态"
        case .rightClick: return "右键抬起（rightMouseUp）"
        case .wheel: return "滚轮，且无 shift/control/option/command"
        case .shiftWheel: return "滚轮，且修饰键恰为 {shift}"
        case .ctrlWheel: return "滚轮，且修饰键恰为 {control}（⌘ 默认归一）"
        case .altWheel: return "滚轮，且修饰键恰为 {option}"
        }
    }
}

struct InputBinding {
    var action: InputAction
    var enabled: Bool = true
}

struct InputMap {
    var bindings: [InputEvent: InputBinding]
    var warnings: [String] = []

    static func defaults() -> InputMap {
        let pairs: [(InputEvent, InputAction)] = [
            (.doubleClick, .zoom100),
            (.doubleClickAgain, .zoomFit),
            (.rightClick, .zoomFit),
            (.wheel, .zoomContinuous),
            (.shiftWheel, .pageOrPan),
            (.ctrlWheel, .zoomContinuous),
            (.altWheel, .pageOrPan),
        ]
        var b: [InputEvent: InputBinding] = [:]
        for (e, a) in pairs { b[e] = InputBinding(action: a, enabled: true) }
        return InputMap(bindings: b)
    }

    /// 取最终生效动作：禁用 → none；指针事件配了需要位移的动作 → 按降级表转换
    func resolvedAction(_ e: InputEvent) -> InputAction {
        guard let b = bindings[e], b.enabled else { return .none }
        if !e.isWheel, let fb = b.action.pointerFallback { return fb }
        return b.action
    }

    /// 修饰键解析规则：
    /// 1) 精确匹配优先；2) 组合键取「掩码为实际掩码子集、且最具体」的已启用事件，
    ///    平局顺序 ctrl > alt > shift > 无；3) 命中的最具体事件若被禁用，不再回落，直接 none。
    func wheelEvent(for flags: NSEvent.ModifierFlags, cmdAsCtrl: Bool) -> InputEvent? {
        var s = Set<String>()
        if flags.contains(.shift) { s.insert("shift") }
        if flags.contains(.control) { s.insert("control") }
        if flags.contains(.command) { s.insert(cmdAsCtrl ? "control" : "command") }
        if flags.contains(.option) { s.insert("option") }
        if s.contains("command") { return nil }        // 未归一化的 ⌘ 不映射任何事件
        let exact: [Set<String>: InputEvent] = [
            []: .wheel, ["shift"]: .shiftWheel, ["control"]: .ctrlWheel, ["option"]: .altWheel
        ]
        if let e = exact[s] { return bindings[e]?.enabled == true ? e : nil }
        let order: [(InputEvent, Set<String>)] = [
            (.ctrlWheel, ["control"]), (.altWheel, ["option"]),
            (.shiftWheel, ["shift"]), (.wheel, [])
        ]
        for (e, m) in order where m.isSubset(of: s) {
            return bindings[e]?.enabled == true ? e : nil
        }
        return nil
    }

    /// 启动校验：动作适用性、禁用项、重复映射汇总（重复映射是允许的有意冗余，只提示不算错）
    mutating func validate() {
        for e in InputEvent.allCases {
            let b = bindings[e] ?? InputBinding(action: .none)
            if !e.isWheel, let fb = b.action.pointerFallback {
                warnings.append("event.\(e.rawValue) 的 \(b.action.rawValue) 需要滚轮位移，已降级为 \(fb.rawValue)")
            }
            if !b.enabled { warnings.append("event.\(e.rawValue) 已禁用") }
        }
        var grouped: [String: [String]] = [:]
        for e in InputEvent.allCases where bindings[e]?.enabled == true {
            let a = resolvedAction(e).rawValue
            if a != InputAction.none.rawValue { grouped[a, default: []].append(e.rawValue) }
        }
        for (a, es) in grouped where es.count > 1 {
            warnings.append("动作 \(a) 被 \(es.count) 个事件共用（允许）：\(es.joined(separator: ", "))")
        }
    }
}

// MARK: - 配置

/// 查看内容范围：只影响「启动时构建相册列表」这一步，默认两者都看
enum MediaFilter: String, CaseIterable {
    case all = "all"
    case images = "images"
    case videos = "videos"

    var label: String {
        switch self {
        case .all:    return "图片 + 视频"
        case .images: return "只看图片"
        case .videos: return "只看视频"
        }
    }
    var includesImages: Bool { self != .videos }
    var includesVideos: Bool { self != .images }
}

struct Config {
    var prefetch = 5                       // 预读当前前后各几张（只针对图片，范围 0~10）
    var prefetchVideo = false              // 是否提前为预读窗口内的视频生成首帧（默认 0 = 沿用原来的「翻到才处理」）
    var includeVideo = true                // 旧键 include_video 的兼容值（无 media_filter 时映射）
    var mediaFilter = MediaFilter.all     // 查看内容范围：all / images / videos（默认全部）
    var videoThumb = true                  // 视频是否生成首帧缩略图
    var autoplayVideo = true               // 视频下载完是否自动播放
    var cacheVideo = true                  // 是否把视频缓存到 Mac 本地（下次秒开）
    var cacheMaxMB = 3000                  // 视频缓存上限，超出按最久未用清理
    var thumbPx = 800                      // 视频缩略图长边像素
    var fps = 60
    var bitrate = "40M"
    var deleteConfirm: TimeInterval = 2.5  // 删除二次确认等待秒数
    var backupDir = NSHomeDirectory() + "/Pictures/红米相册回收站"
    var backupVideo = true                 // 删除视频前是否也备份
    var deleteSuccessHint = false          // 删除成功后是否提示（默认静默，方便连着删）

    // 缩放
    var zoomStep = 1.25                    // 每按一次 +/- 的缩放倍率
    var zoomMax = 16.0                     // 最大放大倍数（相对原图像素）
    var zoomMin = 0.1                      // 最小缩小倍数
    var dblclickStep = 1.5                 // 双击：在当前缩放级别上叠加的倍率（每次双击继续放大）
    var wheelZoom = true                   // 旧开关：wheel_zoom=0 时强制禁用 event.ctrl_wheel
    var fitUpscale = true                  // 图片比窗口小时是否放大到铺满（true=铺满，false=按原尺寸居中）
    var centerImage = true                 // 画面小于窗口时是否居中（false=回到 AppKit 默认贴左下角）

    // 输入映射（每个事件独立可配：动作 + 启用状态）
    var input = InputMap.defaults()
    var wheelCmdAsCtrl = true              // ⌘ 是否归一为 control（Mac 习惯）
    var wheelPageThreshold: CGFloat = 8    // page 动作的累积触发阈值
    var wheelZoomSensitivity = 0.01        // zoom_continuous 的 exp 系数
    var warnings: [String] = []            // 配置校验 / 冲突处理提示，仅 --input-map / --print-config 输出

    // 流畅度
    var decodeMaxPx = 4096                 // 全分辨率上限（放大看细节 / 停留时补解码）
    var quickPx = 0                        // 浏览用快速解码长边，0 = 自动（窗口长边的 2 倍）
    var fullDelay: TimeInterval = 0.8      // 停在一张上多久后，后台补一张全分辨率版本
    var maxConcurrentPull = 4              // 同时从手机拉取的任务数（太多会互相抢 USB 带宽）
    var pullTimeout: TimeInterval = 20     // 单次 adb 拉取超时秒数，超时判失败避免永久卡住
    var cacheImgMB = 600                   // 已解码图片的内存缓存上限 MB
    var videoDelay: TimeInterval = 1.0     // 停在视频上多久后才开始拉（快速翻过时不拉）
    var videoHeadMB = 3                    // 先只拉视频头部多少 MB 抽帧，够用就不拉全文件
    var videoThumbMaxMB = 400              // 超过这个大小的视频不自动生成首帧（0 = 不限）

    // 主窗口照片列表
    var listVisible = false                // 启动时是否显示侧栏照片列表
    var listWidth: CGFloat = 240           // 侧栏宽度（点）
    var listRowHeight: CGFloat = 64        // 每行高度（点）
    var listThumbPx = 96                   // 列表缩略图长边像素

    static let path = NSHomeDirectory() + "/.config/redmi-gallery.conf"

    static func expand(_ s: String) -> String {
        s.hasPrefix("~/") ? NSHomeDirectory() + String(s.dropFirst(1)) : s
    }

    static func load() -> Config {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            var c = Config(); c.input.validate(); c.warnings.append(contentsOf: c.input.warnings)
            return c
        }
        return load(fromText: raw)
    }

    /// 从文本解析配置（自检用同一个解析入口，保证规则与实际运行一致）
    static func load(fromText raw: String) -> Config {
        var c = Config()
        var seen: [String: Int] = [:]
        func truthy(_ v: String, _ d: Bool) -> Bool {
            let l = v.lowercased()
            if ["1","true","yes","on"].contains(l) { return true }
            if ["0","false","no","off"].contains(l) { return false }
            return d
        }
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = String(t[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // 行尾注释必须剥掉：否则「prefetch = 5  # 说明」会被当成整串值，读了等于没读
            if let h = v.firstIndex(of: "#") {
                v = String(v[..<h]).trimmingCharacters(in: .whitespaces)
            }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            seen[k, default: 0] += 1
            switch k {
            case "prefetch":       c.prefetch = min(10, max(0, Int(v) ?? c.prefetch))
            case "prefetch_video": c.prefetchVideo = truthy(v, c.prefetchVideo)
            case "include_video":  c.includeVideo = truthy(v, c.includeVideo)
            case "media_filter":
                if let f = MediaFilter(rawValue: v.lowercased()) { c.mediaFilter = f }
                else { c.warnings.append("media_filter 值 \(v) 未知，保持默认 all") }
            case "video_thumb":    c.videoThumb = truthy(v, c.videoThumb)
            case "autoplay_video": c.autoplayVideo = truthy(v, c.autoplayVideo)
            case "cache_video":    c.cacheVideo = truthy(v, c.cacheVideo)
            case "backup_video":   c.backupVideo = truthy(v, c.backupVideo)
            case "delete_success_hint": c.deleteSuccessHint = truthy(v, c.deleteSuccessHint)
            case "cache_max_mb":   c.cacheMaxMB = Int(v) ?? c.cacheMaxMB
            case "thumb_px":       c.thumbPx = Int(v) ?? c.thumbPx
            case "fps":            c.fps = Int(v) ?? c.fps
            case "bitrate":        c.bitrate = v
            case "delete_confirm": c.deleteConfirm = TimeInterval(v) ?? c.deleteConfirm
            case "backup_dir":     c.backupDir = expand(v)
            case "zoom_step":      c.zoomStep = Double(v) ?? c.zoomStep
            case "zoom_max":       c.zoomMax = Double(v) ?? c.zoomMax
            case "zoom_min":       c.zoomMin = Double(v) ?? c.zoomMin
            case "dblclick_step":  c.dblclickStep = max(1.01, Double(v) ?? c.dblclickStep)
            case "wheel_zoom":     c.wheelZoom = truthy(v, c.wheelZoom)
            case "fit_upscale":    c.fitUpscale = truthy(v, c.fitUpscale)
            case "center_image":   c.centerImage = truthy(v, c.centerImage)
            case "decode_max_px":  c.decodeMaxPx = Int(v) ?? c.decodeMaxPx
            case "quick_px":       c.quickPx = Int(v) ?? c.quickPx
            case "full_delay":     c.fullDelay = TimeInterval(v) ?? c.fullDelay
            case "max_concurrent_pull": c.maxConcurrentPull = max(1, Int(v) ?? c.maxConcurrentPull)
            case "pull_timeout":   c.pullTimeout = TimeInterval(v) ?? c.pullTimeout
            case "cache_img_mb":   c.cacheImgMB = Int(v) ?? c.cacheImgMB
            case "video_delay":    c.videoDelay = TimeInterval(v) ?? c.videoDelay
            case "video_head_mb":  c.videoHeadMB = max(0, Int(v) ?? c.videoHeadMB)
            case "video_thumb_max_mb": c.videoThumbMaxMB = Int(v) ?? c.videoThumbMaxMB
            case "list_visible":    c.listVisible = truthy(v, c.listVisible)
            case "list_width":      c.listWidth = max(160, CGFloat(Double(v) ?? Double(c.listWidth)))
            case "list_row_height": c.listRowHeight = max(40, CGFloat(Double(v) ?? Double(c.listRowHeight)))
            case "list_thumb_px":   c.listThumbPx = max(32, Int(v) ?? c.listThumbPx)
            case "wheel_cmd_as_ctrl": c.wheelCmdAsCtrl = truthy(v, c.wheelCmdAsCtrl)
            case "wheel_page_threshold":
                c.wheelPageThreshold = CGFloat(Double(v) ?? Double(c.wheelPageThreshold))
            case "wheel_zoom_sensitivity": c.wheelZoomSensitivity = Double(v) ?? c.wheelZoomSensitivity
            case let key where key.hasPrefix("event."):
                let rest = String(key.dropFirst("event.".count))
                let parts = rest.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
                guard let first = parts.first, let ev = InputEvent(rawValue: first) else {
                    c.warnings.append("未知事件 event.\(parts.first ?? "?")，已忽略"); continue
                }
                if parts.count == 1 {
                    guard let a = InputAction(rawValue: v.lowercased()) else {
                        c.warnings.append("event.\(ev.rawValue) 动作 '\(v)' 未知，保持默认 \(c.input.bindings[ev]?.action.rawValue ?? InputAction.none.rawValue)")
                        continue
                    }
                    c.input.bindings[ev]?.action = a
                } else if parts.count == 2, parts[1] == "enabled" {
                    let cur = c.input.bindings[ev]?.enabled ?? true
                    c.input.bindings[ev]?.enabled = truthy(v, cur)
                } else {
                    c.warnings.append("无法识别的配置键 \(key)，已忽略")
                }
            default: break
            }
        }
        for (key, n) in seen where n > 1 {
            c.warnings.append("配置键 \(key) 重复出现 \(n) 次，最后一次生效")
        }
        // 旧配置兼容：只有 media_filter 未出现时，才用 include_video=0 映射为「只看图片」
        if seen["media_filter"] == nil, seen["include_video"] != nil, !c.includeVideo {
            c.mediaFilter = .images
        }
        if !c.wheelZoom {
            c.input.bindings[.ctrlWheel]?.enabled = false
            c.warnings.append("wheel_zoom=0：event.ctrl_wheel 已强制禁用")
        }
        c.input.validate()
        c.warnings.append(contentsOf: c.input.warnings)
        return c
    }

    static func sample() -> String {
        """
        # 红米相册配置（改完重启程序生效；行首 # 为注释）
        # 文件位置：~/.config/redmi-gallery.conf

        prefetch = 5              # 预读当前照片前后各几张（图片，范围 0~10，越大越占内存）
        prefetch_video = 0        # 是否提前为窗口内的视频生成首帧（0 = 翻到才处理，1 = 提前预读）
        zoom_step = 1.25          # 按一次 +/- 缩放的倍率
        dblclick_step = 1.5       # 叠加档位倍率（zoom_in_step / zoom_out_step 动作使用）
        wheel_zoom = 1            # 旧开关：0 会强制禁用 event.ctrl_wheel
        center_image = 1          # 画面比窗口小时居中显示（0 则贴左下角）
        fit_upscale = 1           # 图片比窗口小时放大到铺满（0 则按原尺寸居中，不拉伸）

        # 翻页流畅度
        decode_max_px = 4096      # 全分辨率上限（放大看细节时才会解到这个尺寸）
        quick_px = 0              # 浏览时快速解码的长边，0 = 自动（取窗口长边的 2 倍）
        full_delay = 0.8          # 停在一张上多少秒后，后台补一张全分辨率的
        max_concurrent_pull = 4   # 同时从手机拉取的任务数（太多会互相抢 USB 带宽反而更慢）
        pull_timeout = 20         # 单次拉取超时秒数，超过就判失败，避免永久卡住
        cache_img_mb = 600        # 已解码图片占用的内存上限 MB
        video_delay = 1.0         # 停在视频上多少秒后才开始拉（快速翻过就不会被拖慢）
        video_head_mb = 3         # 先只拉视频开头这么多 MB 来抽首帧，够用就不拉全文件
        video_thumb_max_mb = 400  # 大于此大小的视频不自动抽首帧（0 = 不限大小）
        # 查看内容范围：all=图片+视频（默认） / images=只看图片 / videos=只看视频
        media_filter = all        # 保存后重启程序生效
        include_video = 1         # 旧键（仅在没有 media_filter 时兼容）：1 包含视频 / 0 只要照片
        video_thumb = 1           # 是否生成视频首帧缩略图（0 则只显示占位卡，最省）
        autoplay_video = 1        # 视频下载完自动播放（0 则停在首帧，按 P 播放）
        cache_video = 1           # 视频缓存到 Mac 本地（下次瞬间打开）
        cache_max_mb = 3000       # 视频缓存上限 MB，超出自动清理最久未看的
        backup_dir = ~/Pictures/红米相册回收站
        backup_video = 1          # 删视频前先备份；设 0 = 主动放弃备份仍会删（唯一跳过备份的例外）
        delete_confirm = 2.5      # 删除的二次确认等待秒数
        delete_success_hint = 0   # 删除成功后是否提示（0 静默，连着删不被打断；1 提示备份位置）
        # 铁律：先备份，备份失败就绝不删除，照片放回列表并提示

        # 输入映射：每个事件独立配置「动作」与「启用状态」，可选动作见 --input-map
        event.double_click = zoom_100
        event.double_click.enabled = 1
        event.double_click_again = zoom_fit
        event.double_click_again.enabled = 1
        event.right_click = zoom_fit
        event.right_click.enabled = 1
        event.wheel = zoom_continuous   # 滚轮向上放大 / 向下缩小（FSViewer 风格）
        event.wheel.enabled = 1
        event.shift_wheel = page_or_pan
        event.shift_wheel.enabled = 1
        event.ctrl_wheel = zoom_continuous
        event.ctrl_wheel.enabled = 1
        event.alt_wheel = page_or_pan
        event.alt_wheel.enabled = 1
        wheel_cmd_as_ctrl = 1          # ⌘ 归一为 Ctrl（0 则 ⌘ 不映射任何事件）
        wheel_page_threshold = 8       # page 动作累积多少位移才翻一张
        wheel_zoom_sensitivity = 0.01  # 滚轮缩放系数：向上为正，倍率 × exp(滚动量 × 系数)

        # 主窗口照片列表（L 键 / 「显示」菜单可随时开关）
        list_visible = 0          # 启动时是否显示侧栏
        list_width = 240          # 侧栏宽度（点）
        list_row_height = 64      # 每行高度（点）
        list_thumb_px = 96        # 列表缩略图长边像素
        """
    }
}

let cfg = Config.load()

// MARK: - adb

struct Adb {
    static let bin: String = {
        let home = NSHomeDirectory()
        let cands = ["\(home)/.local/bin/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        for c in cands where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "adb"
    }()

    static var serial: String?

    static func run(_ args: [String]) -> (Data, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (Data(), -1) }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (d, p.terminationStatus)
    }

    static func text(_ args: [String]) -> String {
        let (d, _) = run(args)
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func findDevice() -> String? {
        let out = text(["devices"])
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count >= 2, parts[1].trimmingCharacters(in: .whitespaces) == "device" {
                return String(parts[0])
            }
        }
        return nil
    }

    static func sh(_ cmd: String) -> String {
        guard let s = serial else { return "" }
        return text(["-s", s, "shell", cmd])
    }

    /// 从手机读整个文件到内存（图片用）。带超时：网络/USB 卡住时不会被永久拖死
    static func pullBytes(_ path: String, timeout: TimeInterval? = nil) -> Data? {
        guard let s = serial else { return nil }
        let limit = timeout ?? cfg.pullTimeout
        return runCapped(["-s", s, "exec-out", "cat '\(path)'"], timeout: limit).data
    }

    /// 带超时的进程执行：读数据在后台线程，主线程/调用线程只等 limit 秒
    static func runCapped(_ args: [String], timeout: TimeInterval) -> (data: Data?, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (nil, -1) }

        var box: Data?
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); box = d; lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            lock.lock(); let partial = box ?? Data(); lock.unlock()
            // 超时也要回收子进程，否则每超时一次就留一个僵尸 adb
            DispatchQueue.global(qos: .utility).async { p.waitUntilExit() }
            // 已经读到一部分且进程正常退出的情况仍算成功
            return (partial.isEmpty ? nil : partial, -2)
        }
        p.waitUntilExit()
        lock.lock(); let got = box; lock.unlock()
        return (got, p.terminationStatus)
    }

    /// 只拉文件开头若干 MB（视频抽帧用，避免整件几十 MB 全拉）
    static func pullHead(_ path: String, mb: Int, dest: String) -> Bool {
        guard let s = serial else { return false }
        try? FileManager.default.removeItem(atPath: dest)
        FileManager.default.createFile(atPath: dest, contents: nil)
        guard let wh = FileHandle(forWritingAtPath: dest) else { return false }
        let bs = 1048576
        let (data, code) = runCapped(["-s", s, "exec-out",
                                      "dd if='\(path)' bs=\(bs) count=\(mb) 2>/dev/null"],
                                     timeout: cfg.pullTimeout)
        defer { try? wh.close() }
        guard let d = data, !d.isEmpty else { return false }
        wh.write(d)
        _ = code
        return true
    }

    /// 流式拉取到 Mac 本地（视频等大文件用，避免一次性进内存）
    static func pullTo(_ path: String, dest: String, progress: ((Double) -> Void)? = nil) -> Bool {
        guard let s = serial else { return false }
        try? FileManager.default.removeItem(atPath: dest)
        FileManager.default.createFile(atPath: dest, contents: nil)
        guard let wh = FileHandle(forWritingAtPath: dest) else { return false }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-s", s, "exec-out", "cat '\(path)'"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        let fh = pipe.fileHandleForReading
        var got: Double = 0
        let group = DispatchGroup()
        group.enter()
        fh.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                group.leave()
                return
            }
            wh.write(d)
            got += Double(d.count)
            DispatchQueue.main.async { progress?(got) }
        }
        do { try p.run() } catch { return false }
        group.wait()
        p.waitUntilExit()
        try? wh.close()
        return got > 0
    }

    static func delete(_ item: MediaItem) -> Bool {
        guard let s = serial else { return false }
        var removed = false
        if !item.id.isEmpty {
            let uri = item.kind == .video
                ? "content://media/external/video/media"
                : "content://media/external/images/media"
            let (out, _) = run(["-s", s, "shell", "content", "delete",
                               "--uri", uri, "--where", "_id=\(item.id)"])
            let t = String(data: out, encoding: .utf8) ?? ""
            if t.contains("Deleted 1") { removed = true }
        }
        if !removed {
            let (_, code) = run(["-s", s, "shell", "rm -f '\(item.path)'"])
            if code == 0 {
                _ = run(["-s", s, "shell",
                         "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://\(item.path)"])
                removed = true
            }
        }
        // rm -f 对「文件本来就不存在」也返回 0，所以不能只看退出码。
        // 乐观删除依赖这个结果决定要不要把照片放回列表，必须再确认文件真的没了。
        let (chk, _) = run(["-s", s, "shell", "test -e '\(item.path)' && echo STILL || echo GONE"])
        let r = String(data: chk, encoding: .utf8) ?? ""
        if r.contains("STILL") { return false }
        return removed || r.contains("GONE")
    }
}

// MARK: - 媒体项

enum Kind { case image, video }

/// 删除后台任务的三种结局。注意没有「删除成功但备份失败」这一项——
/// 备份不成功就压根不会调用删除。
enum DeleteOutcome { case done, backupFailed, deleteFailed }

/// 自检用：线程安全地记录后台「备份 / 删除」的实际调用顺序
final class DeleteTrace {
    private let lock = NSLock()
    private var log: [String] = []
    func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    func events() -> [String] { lock.lock(); defer { lock.unlock() }; return log }
    func reset() { lock.lock(); log.removeAll(); lock.unlock() }
}

struct MediaItem {
    let kind: Kind
    let id: String
    let path: String
    let name: String
    let date: Date?
    let size: Int64
    let duration: Int64      // 毫秒，仅视频
}

let IMAGE_EXT: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff", "dng"]

/// 解析 `Row: N _id=.., date_modified=.., _size=.., duration=.., _data=/path`
/// projection 里 _data 必须放最后
func parseRows(_ raw: String, kind: Kind) -> [MediaItem] {
    var out: [MediaItem] = []
    for line in raw.split(separator: "\n") {
        guard let dr = line.range(of: "_data=") else { continue }
        let path = String(line[dr.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { continue }
        func num(_ k: String) -> String {
            guard let r = line.range(of: "\(k)=") else { return "" }
            return String(line[r.upperBound...].prefix { $0.isNumber || $0 == "-" })
        }
        let secs = Double(num("date_modified")) ?? 0
        out.append(MediaItem(kind: kind,
                             id: num("_id"),
                             path: path,
                             name: (path as NSString).lastPathComponent,
                             date: secs > 0 ? Date(timeIntervalSince1970: secs) : nil,
                             size: Int64(num("_size")) ?? 0,
                             duration: Int64(num("duration")) ?? 0))
    }
    return out
}

/// 按查看范围过滤列表。抽成纯函数，自检可直接验证真值表。
func filteredMedia(_ items: [MediaItem], by filter: MediaFilter) -> [MediaItem] {
    items.filter { it in
        (it.kind == .image && filter.includesImages) || (it.kind == .video && filter.includesVideos)
    }
}

func loadPhotosFromDevice() -> [MediaItem] {
    var items: [MediaItem] = []
    if cfg.mediaFilter.includesImages {
        let q = "content query --uri content://media/external/images/media " +
                "--projection _id:date_modified:_size:_data --sort \"date_modified DESC\""
        items.append(contentsOf: parseRows(Adb.sh(q), kind: .image))
    }

    if cfg.mediaFilter.includesVideos {
        let vq = "content query --uri content://media/external/video/media " +
                 "--projection _id:date_modified:_size:duration:_data --sort \"date_modified DESC\""
        items.append(contentsOf: parseRows(Adb.sh(vq), kind: .video))
    }
    items = filteredMedia(items, by: cfg.mediaFilter)

    items = items.filter { it in
        let lp = it.path.lowercased()
        if lp.contains("/thumbnails/") || lp.contains("/.cache/") || lp.contains("/cache/") { return false }
        return lp.contains("/dcim/") || lp.contains("/pictures/")
    }
    items.sort { a, b in (a.date ?? .distantPast) > (b.date ?? .distantPast) }
    return items
}

func loadPhotosFromLocal(_ dir: String) -> [MediaItem] {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
    let files = names.filter { IMAGE_EXT.contains(($0 as NSString).pathExtension.lowercased()) }
    return files.sorted().map { n -> MediaItem in
        let full = (dir as NSString).appendingPathComponent(n)
        let attrs = try? fm.attributesOfItem(atPath: full)
        return MediaItem(kind: .image, id: "", path: full, name: n,
                         date: attrs?[.modificationDate] as? Date,
                         size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0, duration: 0)
    }
}

// MARK: - 工具

func fnv1a(_ s: String) -> String {
    var h: UInt64 = 14695981039346656037
    for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
    return String(format: "%016llx", h)
}

func ensureDir(_ p: String) -> String {
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

func cacheDir(_ sub: String) -> String {
    ensureDir(NSHomeDirectory() + "/Library/Caches/redmi-gallery/" + sub)
}

func fmtBytes(_ v: Int64) -> String {
    let mb = Double(v) / 1_048_576
    if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    return String(format: "%lld KB", v / 1024)
}

func fmtDuration(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let s = ms / 1000
    return String(format: "%02lld:%02lld", s / 60, s % 60)
}

/// 视频占位卡
func placeholderImage(text: String, sub: String) -> NSImage {
    let size = NSSize(width: 900, height: 900)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(white: 0.13, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor(white: 0.85, alpha: 1),
        .font: NSFont.systemFont(ofSize: 22, weight: .medium),
        .paragraphStyle: para
    ]
    (text as NSString).draw(in: NSRect(x: 20, y: size.height / 2 + 4, width: size.width - 40, height: 30),
                      withAttributes: attrs)
    let a2 = attrs.merging([.foregroundColor: NSColor(white: 0.5, alpha: 1),
                            .font: NSFont.systemFont(ofSize: 15)]) { $1 }
    (sub as NSString).draw(in: NSRect(x: 20, y: size.height / 2 - 26, width: size.width - 40, height: 24),
                      withAttributes: a2)
    img.unlockFocus()
    return img
}

// MARK: - 视图

/// 虚拟照片列表：不为每行创建子视图，只绘制当前可见矩形内的若干行。
/// 因此相册无论是 47 张还是 16000 张，视图数与内存都恒定。
final class PhotoListView: NSView {
    weak var gallery: GalleryView?
    override var isFlipped: Bool { true }              // 第 0 行在顶部
    var rowHeight: CGFloat { cfg.listRowHeight }
    var count: Int { gallery?.items.count ?? 0 }

    private func drawLine(_ s: String, _ rect: NSRect, _ attrs: [NSAttributedString.Key: Any]) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        var a = attrs; a[.paragraphStyle] = p
        NSAttributedString(string: s, attributes: a)
            .draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = gallery else { return }
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); dirtyRect.fill()
        guard count > 0 else { return }
        let first = max(0, Int(floor(dirtyRect.minY / rowHeight)))
        let last = min(count - 1, Int(ceil(dirtyRect.maxY / rowHeight)))
        guard first <= last else { return }

        let w = bounds.width
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1)]
        let idxAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)]

        for i in first...last {
            let y = CGFloat(i) * rowHeight
            let row = NSRect(x: 0, y: y, width: w, height: rowHeight)
            if !row.intersects(dirtyRect) { continue }
            if i == g.index {
                NSColor.controlAccentColor.withAlphaComponent(0.34).setFill(); row.fill()
            } else {
                NSColor(calibratedWhite: 0.135, alpha: 0.6).setFill(); row.insetBy(dx: 0, dy: 1).fill()
            }
            NSColor(calibratedWhite: 0.22, alpha: 0.5).setFill()
            NSRect(x: 0, y: y + rowHeight - 1, width: w, height: 1).fill()

            let it = g.items[i]
            let tr = NSRect(x: 8, y: y + 8, width: rowHeight - 16, height: rowHeight - 16)
            NSColor(calibratedWhite: 0.20, alpha: 1).setFill()
            NSBezierPath(roundedRect: tr, xRadius: 4, yRadius: 4).fill()
            if let img = g.thumbnail(for: i) {
                img.draw(in: tr.insetBy(dx: 1, dy: 1), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let mark = it.kind == .video ? "▶" : "◻"
                (mark as NSString).draw(at: NSPoint(x: tr.midX - 6, y: tr.midY - 8),
                                        withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                                                         .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1)])
            }

            let tx = tr.maxX + 10
            let tw = w - tx - 12
            drawLine(it.name, NSRect(x: tx, y: y + 9, width: tw - 34, height: 16), nameAttrs)
            var sub = ""
            if let d = it.date {
                let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
                sub = f.string(from: d)
            }
            sub += it.kind == .video ? "   ▶ " + fmtDuration(it.duration) : "   " + fmtBytes(it.size)
            drawLine(sub, NSRect(x: tx, y: y + 29, width: tw, height: 14), subAttrs)
            drawLine("\(i + 1)", NSRect(x: w - 34, y: y + 9, width: 26, height: 14), idxAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let g = gallery, count > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / rowHeight)
        if i >= 0, i < count { g.show(i) }
    }

    /// 让当前张始终可见（只在必要时滚动，不会每次都把列表拽回顶部）
    func scrollToCurrent() {
        guard let g = gallery, count > 0, let cv = enclosingScrollView?.contentView else { return }
        let target = NSRect(x: 0, y: CGFloat(g.index) * rowHeight, width: bounds.width, height: rowHeight)
        let vis = cv.documentVisibleRect
        if target.minY < vis.minY {
            cv.scroll(to: NSPoint(x: 0, y: target.minY))
        } else if target.maxY > vis.maxY {
            cv.scroll(to: NSPoint(x: 0, y: target.maxY - vis.height))
        }
        needsDisplay = true
    }
}

/// 统一的可见区几何约束。
/// 实测：documentView.frame 恒定是原图尺寸（文档坐标，不随 magnification 变化），
/// clipView.bounds.size = 屏幕尺寸 / magnification（同为文档单位）。
/// 所以「某轴文档小于可视区 → 居中；否则 → clamp 到文档范围」可以只用文档坐标表达。
/// 这个函数同时被 AppKit 的 constrainBoundsRect 和我们自己的锚点缩放调用，
/// 保证「算出来的 origin」与「最终显示的 origin」完全一致，不会出现锚点漂移或布局跳动。
final class CenteredClipView: NSClipView {
    var centerEnabled = true               // 对应配置 center_image

    func constrainedOrigin(_ proposed: NSPoint, boundsSize: NSSize) -> NSPoint {
        guard let doc = documentView else { return proposed }
        let f = doc.frame
        var o = proposed
        if boundsSize.width >= f.width {
            o.x = centerEnabled ? f.minX - (boundsSize.width - f.width) / 2 : f.minX
        } else {
            o.x = min(max(o.x, f.minX), f.maxX - boundsSize.width)
        }
        if boundsSize.height >= f.height {
            o.y = centerEnabled ? f.minY - (boundsSize.height - f.height) / 2 : f.minY
        } else {
            o.y = min(max(o.y, f.minY), f.maxY - boundsSize.height)
        }
        return o
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = proposedBounds
        r.origin = constrainedOrigin(r.origin, boundsSize: r.size)
        return r
    }
}

/// 性能自检统计。写入来自多条并发的 OperationQueue 线程，必须加锁：
/// Swift 的 Dictionary 不是线程安全的，并发写会把 COW 引用计数写坏，
/// 崩溃点就是 swift_isUniquelyReferenced_nonNull_native（EXC_BAD_ACCESS）。
final class NavStats {
    enum K { case wait, pull, decode }
    private let lock = NSLock()
    private var wait: [String: Double] = [:]
    private var pull: [String: Double] = [:]
    private var decode: [String: Double] = [:]
    private var bytes = 0
    private var lastWait: Double = 0
    private var lastPull: Double = 0
    private var lastDecode: Double = 0

    func set(_ k: K, path: String, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        switch k {
        case .wait:   wait[path] = ms;   lastWait = ms / 1000
        case .pull:   pull[path] = ms;   lastPull = ms / 1000
        case .decode: decode[path] = ms; lastDecode = ms / 1000
        }
    }
    func get(_ k: K, path: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        switch k {
        case .wait:   return wait[path] ?? 0
        case .pull:   return pull[path] ?? 0
        case .decode: return decode[path] ?? 0
        }
    }
    func setBytes(_ n: Int) { lock.lock(); bytes = n; lock.unlock() }
    var lastBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
}

final class GalleryView: NSView {
    /// 后台线程会触碰的 items / index 统一走这把锁。
    /// 用 recursive 是为了临界区内再读属性时不会把自己锁死。
    private let stateLock = NSRecursiveLock()
    private var _items: [MediaItem] = []
    private var _index = 0
    var items: [MediaItem] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _items }
        set { stateLock.lock(); defer { stateLock.unlock() }; _items = newValue }
    }
    var index: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _index }
        set { stateLock.lock(); defer { stateLock.unlock() }; _index = newValue }
    }
    /// 后台线程用：一次原子拿到「当前显示的是哪张」，避免 items 和 index 分两次读到中间态
    func currentPath() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _index >= 0, _index < _items.count else { return nil }
        return _items[_index].path
    }
    /// 后台线程用：这个任务是否还在当前可见范围附近（翻远了就丢掉）
    func isNear(_ i: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return abs(i - _index) <= cfg.prefetch + 2
    }
    let navStats = NavStats()
    let localMode: Bool

    let imageView = NSImageView()
    var playerView: AVPlayerView!
    let titleLabel = NSTextField(labelWithString: "")
    let infoLabel = NSTextField(labelWithString: "")
    let hintLabel = NSTextField(labelWithString: "")
    let loadingLabel = NSTextField(labelWithString: "载入中…")

    /// 缓存的是「快速解码好的 NSImage」，显示时不用再解一遍（主线程不会被解码卡住）
    let cache = NSCache<NSString, NSImage>()
    /// 原始字节（供后面补解全分辨率用，避免二次从手机拉取）
    let dataCache = NSCache<NSString, NSData>()
    /// 全分辨率版本，只留最近几张
    let fullCache = NSCache<NSString, NSImage>()
    /// 图片拉取：限并发 + 过期自动丢弃，避免快速翻页时堆积上百个 adb 进程
    let ioQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = cfg.maxConcurrentPull
        q.qualityOfService = .userInitiated
        return q
    }()
    /// 视频拉取单独一条串行队列，不去挤抢占图片的拉取
    let videoQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        return q
    }()
    /// 删除单独一条串行队列：备份要拉原图/原片，多个一起跑会互抢 USB、备份文件名也可能撞车
    let deleteQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()
    /// 自检注入：分别接管「备份」与「删除」两步，nil 走真实逻辑。
    /// 拆成两个是为了能验证顺序，以及「备份失败时删除根本没被调用」。
    var backupSimulator: ((MediaItem) -> Bool)?
    var deleteSimulator: ((MediaItem) -> Bool)?
    /// 自检用：把备份写到别处，不污染用户真正的回收站
    var backupDirOverride: String?
    let inflightLock = NSLock()
    var inflight = Set<String>()          // 已排队的图片任务
    var videoInflight = Set<String>()     // 已排队的视频任务

    // 性能自检（--navtest 用）；下面两个只在主线程读写，耗时统计在 navStats 里加锁
    var applyCount = 0
    var lastInstant = false

    var pendingDelete = false
    var deleteTimer: Timer?
    var msgTimer: Timer?
    var thumbTimer: Timer?
    var fullTimer: Timer?
    var fullInflight = Set<String>()      // 已排队的全分辨率解码

    // 缩放 / 平移
    var scrollView: NSScrollView!
    var fitScale: Double = 1.0
    /// 只有窗口尺寸真的变了才重新适配，避免缩放过程中被 layout 重置回 fit（布局跳动）
    private var lastLayoutSize: NSSize = .zero

    // 主窗口照片列表（可开关侧栏）
    var listVisible = cfg.listVisible
    var listScroll: NSScrollView!
    var listView: PhotoListView!
    /// 图片可视区尺寸（列表显示时扣掉侧栏宽度），适配比例以它为准
    var photoArea: NSSize {
        NSSize(width: bounds.width - (listVisible ? cfg.listWidth : 0), height: bounds.height)
    }
    // 列表缩略图：独立缓存 + 低并发队列，不跟主图抢 USB
    let thumbCache = NSCache<NSString, NSImage>()
    let thumbQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility; return q
    }()
    let thumbLock = NSLock()
    var thumbInflight = Set<String>()
    var videoPrefetchInflight = Set<String>()   // prefetch_video 已排队的视频
    var wheelAccum: CGFloat = 0
    /// 自检注入：非空时替代全局输入映射，保证验收用例与用户配置解耦
    var inputMapOverride: InputMap?
    /// 自检注入：覆盖预读半径 / 视频预读开关，用于验收配置是否真正接上运行时
    var prefetchRadiusOverride: Int?
    var prefetchVideoOverride: Bool?
    /// 双击状态机：false=首次双击，true=连续第二次双击。任何其它输入都会把它复位
    var dblArmed = false
    var lastPan: NSPoint?

    static let hintText = "← ↑ 上一张   → ↓ 下一张   Delete 删除（连按两次，删前备份）   " +
        "滚轮 ↑放大 ↓缩小   双击 100%/全图   + - 0   L 列表   P 播放   F 全屏"

    init(frame: NSRect, localDir: String?) {
        self.localMode = localDir != nil
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        cache.countLimit = 80
        cache.totalCostLimit = cfg.cacheImgMB * 1_048_576
        dataCache.totalCostLimit = 260 * 1_048_576   // 只保留一小段窗口的原始字节
        fullCache.countLimit = 3                     // 只保留当前和最近几张的全分辨率版本

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.animates = false

        // 图片放进滚动视图，缩放超出窗口后可以拖动查看
        scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        scrollView.allowsMagnification = true
        // 两处限制必须一致，否则到达缩放边界时 AppKit 会再夹一次，导致几何跳变
        scrollView.minMagnification = CGFloat(cfg.zoomMin)
        scrollView.maxMagnification = CGFloat(cfg.zoomMax)
        // 换用自定义 clipView：文档小于窗口时自动居中，且约束与锚点缩放共用一套几何
        let clip = CenteredClipView(frame: frame)
        clip.centerEnabled = cfg.centerImage
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = imageView
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        // 照片列表侧栏：默认按配置隐藏，L 键 / 「显示」菜单可随时切换
        listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: cfg.listWidth, height: frame.height))
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = false
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listView = PhotoListView(frame: NSRect(x: 0, y: 0, width: cfg.listWidth, height: 1))
        listView.gallery = self
        listScroll.documentView = listView
        listScroll.isHidden = !listVisible
        addSubview(listScroll)

        playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.isHidden = true
        addSubview(playerView)

        for (lbl, size, color) in [(titleLabel, CGFloat(13), NSColor.white),
                                   (infoLabel, CGFloat(12), NSColor(white: 0.75, alpha: 1)),
                                   (hintLabel, CGFloat(11), NSColor(white: 0.55, alpha: 1)),
                                   (loadingLabel, CGFloat(15), NSColor(white: 0.8, alpha: 1))] {
            lbl.font = NSFont.systemFont(ofSize: size)
            lbl.textColor = color
            addSubview(lbl)
        }
        loadingLabel.isHidden = true
        hintLabel.stringValue = GalleryView.hintText
        hintLabel.alignment = .center

        if let d = localDir { items = loadPhotosFromLocal(d) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let lw = listVisible ? cfg.listWidth : 0
        let area = photoArea
        scrollView.frame = NSRect(x: lw, y: 0, width: area.width, height: h)
        playerView.frame = scrollView.frame
        listScroll.frame = NSRect(x: 0, y: 0, width: lw, height: h)
        listScroll.isHidden = !listVisible
        // 尺寸变化（含列表开关导致的可视区变化）才重新适配
        if lastLayoutSize != area {
            lastLayoutSize = area
            if let img = imageView.image { fitAndApplyScale(imageSize: docSize(img)) }
        }
        titleLabel.frame = NSRect(x: lw + 16, y: h - 30, width: area.width - 32, height: 20)
        infoLabel.frame = NSRect(x: lw + 16, y: h - 50, width: area.width - 32, height: 18)
        hintLabel.frame = NSRect(x: lw + 16, y: 12, width: area.width - 32, height: 16)
        loadingLabel.frame = NSRect(x: lw, y: h / 2 - 10, width: area.width, height: 20)
        loadingLabel.alignment = .center
    }

    // MARK: 显示

    func start() {
        guard !items.isEmpty else {
            titleLabel.stringValue = localMode ? "该目录没有图片" : "没读到照片：请确认手机已连接并授权 USB 调试"
            return
        }
        show(0)
        refreshList()          // 按 items 数量设置列表总高度
    }

    func show(_ i: Int) {
        // 无论从哪个分支返回，列表都要刷新高亮并跟随当前张
        defer { if listVisible { listView.needsDisplay = true; listView.scrollToCurrent() } }
        dblArmed = false          // 翻到别的照片后，下一次双击重新算「首次」
        guard !items.isEmpty else { return }
        let jumped = abs(i - index) > cfg.prefetch + 2
        index = max(0, min(i, items.count - 1))
        if jumped { dropPending() }          // 大跳转：清掉排队中的旧任务
        let it = items[index]

        stopPlayer()
        let tag = (it.kind == .video) ? "  [视频]" : ""
        titleLabel.stringValue = "\(index + 1) / \(items.count)   \(it.name)\(tag)"

        var info = ""
        if let d = it.date {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            info = f.string(from: d)
        }
        if it.kind == .video {
            let dur = fmtDuration(it.duration)
            info += (dur.isEmpty ? "" : "   时长 " + dur) + "   大小 " + fmtBytes(it.size)
        }
        infoLabel.stringValue = info

        thumbTimer?.invalidate(); thumbTimer = nil

        if it.kind == .video {
            let dur = fmtDuration(it.duration)
            let sub = (dur.isEmpty ? "" : "时长 " + dur + "   ") + fmtBytes(it.size)
            let ph = placeholderImage(text: "▶  " + it.name, sub: sub)
            let px = docSize(ph)
            imageView.image = ph
            imageView.frame = NSRect(origin: .zero, size: px)
            fitAndApplyScale(imageSize: px)
            if cfg.videoThumb {
                var tooBig = false
                if cfg.videoThumbMaxMB > 0 {
                    tooBig = it.size > Int64(cfg.videoThumbMaxMB) * 1_048_576
                }
                if !tooBig {
                    // 预读已生成首帧时不再等 video_delay，立即显示
                    let ready = FileManager.default.fileExists(atPath: thumbCachePath(it))
                    thumbTimer = Timer.scheduledTimer(withTimeInterval: ready ? 0 : cfg.videoDelay,
                                                     repeats: false) { [weak self] _ in
                        self?.loadVideoThumbnail(it)
                    }
                }
            }
            prefetch()
            return
        }

        // 命中缓存：直接显示，不解码、不联网 —— 这一步是「秒切」的关键
        if let img = fullCache.object(forKey: it.path as NSString) {
            lastInstant = true
            applyImage(img)
            prefetch()
            return
        }
        if let img = cache.object(forKey: it.path as NSString) {
            lastInstant = true
            applyImage(img)
            scheduleFull()
            prefetch()
            return
        }
        lastInstant = false

        // 没命中：保留上一张画面当底板（不闪黑），叠一个载入提示
        loadingLabel.isHidden = false
        loadingLabel.stringValue = "载入中…"
        fetch(priority: true)
        prefetch()
    }

    /// 浏览用的解码长边：0 = 自动（窗口长边的 2 倍，够铺满 Retina 屏即可）
    func quickPx() -> Int {
        if cfg.quickPx > 0 { return cfg.quickPx }
        return max(1600, Int(max(bounds.width, bounds.height) * 2))
    }

    // MARK: 取图（去重 + 限并发 + 过期丢弃）

    /// 排取第 i 张；已在队列里就跳过，避免重复排队
    func enqueueImage(_ i: Int, urgent: Bool) {
        guard i >= 0, i < items.count else { return }
        let it = items[i]
        guard it.kind == .image else { return }
        if cache.object(forKey: it.path as NSString) != nil { return }

        inflightLock.lock()
        let dup = inflight.contains(it.path)
        if !dup { inflight.insert(it.path) }
        inflightLock.unlock()
        if dup { return }

        // 在主线程（调用方）算好这些值，闭包里只捕获不可变常量：
        // bounds 属于 AppKit，绝不能从后台线程读；navStats 自己带锁，可安全跨线程共享。
        let px = quickPx()
        let stats = navStats
        let path = it.path
        let t0 = Date()
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self else { return }
            defer { self.markDone(path) }
            guard let op, !op.isCancelled else { return }
            let wms = Date().timeIntervalSince(t0) * 1000
            stats.set(.wait, path: path, ms: wms)

            // 已经翻远了就别拉了：快速连续翻页时堆积的旧任务在这里被丢掉
            if !self.isNear(i) { return }

            let t1 = Date()
            let data = self.localMode
                ? try? Data(contentsOf: URL(fileURLWithPath: path))
                : Adb.pullBytes(path)
            let pms = Date().timeIntervalSince(t1) * 1000
            stats.set(.pull, path: path, ms: pms)
            guard let data, !data.isEmpty else { return }
            stats.setBytes(data.count)
            self.dataCache.setObject(data as NSData, forKey: path as NSString, cost: data.count)

            guard self.isNear(i) else { return }

            // 解码放在后台线程，主线程只负责显示
            let t2 = Date()
            guard let img = GalleryView.decode(data, maxPx: px) else { return }
            let dms = Date().timeIntervalSince(t2) * 1000
            stats.set(.decode, path: path, ms: dms)

            let cost = Int(img.size.width * img.size.height * 4)
            self.cache.setObject(img, forKey: path as NSString, cost: cost)
            if self.index == i {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.index == i else { return }
                    self.applyImage(img)
                    self.scheduleFull()
                }
            }
        }
        op.queuePriority = urgent ? .veryHigh : .normal
        ioQueue.addOperation(op)
    }

    func fetch(priority: Bool) { enqueueImage(index, urgent: priority) }

    /// 取消所有排队中的普通任务（保留紧急的），避免跳到别处后还在慢慢拉旧图
    func dropPending() {
        for op in ioQueue.operations where op.queuePriority != .veryHigh { op.cancel() }
        inflightLock.lock()
        inflight.removeAll()
        inflightLock.unlock()
    }

    func markDone(_ path: String) {
        inflightLock.lock()
        inflight.remove(path)
        inflightLock.unlock()
    }

    // MARK: 全分辨率补充解码（放大看细节 / 停留一会儿时）

    /// 停在一张上 full_delay 秒后，后台补一张全分辨率的
    func scheduleFull() {
        fullTimer?.invalidate(); fullTimer = nil
        guard !items.isEmpty, items[index].kind == .image else { return }
        let i = index
        fullTimer = Timer.scheduledTimer(withTimeInterval: cfg.fullDelay, repeats: false) { [weak self] _ in
            self?.ensureFull(i)
        }
    }

    /// 需要看细节时调用：已有全分辨率就直接用，否则后台补一张
    func ensureFull(_ i: Int = -1) {
        let i = i < 0 ? index : i
        guard i >= 0, i < items.count else { return }
        let it = items[i]
        guard it.kind == .image else { return }
        if fullCache.object(forKey: it.path as NSString) != nil { return }
        // 已经比全分辨率还大就不用解了
        if let cur = cache.object(forKey: it.path as NSString),
           docSize(cur).width >= CGFloat(cfg.decodeMaxPx) { return }

        inflightLock.lock()
        let dup = fullInflight.contains(it.path)
        if !dup { fullInflight.insert(it.path) }
        inflightLock.unlock()
        if dup { return }

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, let op, !op.isCancelled else { return }
            defer {
                self.inflightLock.lock()
                self.fullInflight.remove(it.path)
                self.inflightLock.unlock()
            }
            var data = self.dataCache.object(forKey: it.path as NSString) as Data?
            if data == nil {
                data = self.localMode
                    ? try? Data(contentsOf: URL(fileURLWithPath: it.path))
                    : Adb.pullBytes(it.path)
                if let d = data { self.dataCache.setObject(d as NSData, forKey: it.path as NSString, cost: d.count) }
            }
            guard let data, let img = GalleryView.decode(data, maxPx: cfg.decodeMaxPx),
                  img.size.width > 0 else { return }
            self.fullCache.setObject(img, forKey: it.path as NSString,
                                     cost: Int(img.size.width * img.size.height * 4))
            DispatchQueue.main.async {
                guard self.index == i else { return }
                // 换图时保持屏幕上看到的大小和位置不变，不会突然跳一下
                self.swapKeepingView(img)
            }
        }
        op.queuePriority = .low
        ioQueue.addOperation(op)
    }

    /// 用另一张（通常更高分辨率的）图替换当前图，视觉上保持不变
    func swapKeepingView(_ img: NSImage) {
        guard let old = imageView.image else { applyImage(img); return }
        let oldSize = docSize(old), newSize = docSize(img)
        guard oldSize.width > 0, newSize.width > 0 else { applyImage(img); return }
        let vis = scrollView.contentView.documentVisibleRect
        let cx = vis.midX / oldSize.width, cy = vis.midY / oldSize.height
        let ratio = oldSize.width / newSize.width          // 保持屏幕上的物理尺寸
        let newMag = scrollView.magnification * ratio

        imageView.image = img
        imageView.frame = NSRect(origin: .zero, size: newSize)
        fitScale = Double(min(bounds.width / newSize.width, bounds.height / newSize.height))
        scrollView.magnification = newMag
        let v2 = scrollView.contentView.documentVisibleRect
        scrollView.contentView.scroll(to: NSPoint(x: cx * newSize.width - v2.width / 2,
                                                  y: cy * newSize.height - v2.height / 2))
        recenter()
        updateTitle()
    }

    /// 后台解码，超大图顺带降采样（比主线程直接 NSImage(data:) 快很多）
    static func decode(_ data: Data, maxPx: Int) -> NSImage? {
        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else {
            return NSImage(data: data)
        }
        if maxPx > 0 {
            let tOpt: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPx
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, tOpt as CFDictionary) {
                if getenv("RG_DEBUG") != nil { print("  [decode] maxPx=\(maxPx) -> \(cg.width)x\(cg.height)") }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        guard let cg0 = CGImageSourceCreateImageAtIndex(src, 0, opts) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg0, size: NSSize(width: cg0.width, height: cg0.height))
    }

    func applyImage(_ img: NSImage) {
        loadingLabel.isHidden = true
        imageView.image = img
        let px = docSize(img)
        imageView.frame = NSRect(origin: .zero, size: px)
        fitAndApplyScale(imageSize: px)
        applyCount += 1
    }

    // MARK: 主窗口照片列表

    /// 列表缩略图：优先用内存里已有的图/字节，都没有才后台拉一次。
    /// 只在 draw 可见行时被调用，配合去重与限并发 2，不会跟主图抢 USB 带宽。
    func thumbnail(for i: Int) -> NSImage? {
        guard i >= 0, i < items.count else { return nil }
        let it = items[i]
        let key = it.path as NSString
        if let t = thumbCache.object(forKey: key) { return t }

        if it.kind == .video {
            let p = thumbCachePath(it)
            if let d = FileManager.default.contents(atPath: p), let im = NSImage(data: d) {
                thumbCache.setObject(im, forKey: key); return im
            }
            return nil
        }
        if let big = cache.object(forKey: key) {
            let t = GalleryView.scaledThumb(big, px: cfg.listThumbPx)
            thumbCache.setObject(t, forKey: key); return t
        }
        if let d = dataCache.object(forKey: key) as Data?, let big = NSImage(data: d) {
            let t = GalleryView.scaledThumb(big, px: cfg.listThumbPx)
            thumbCache.setObject(t, forKey: key); return t
        }
        thumbLock.lock()
        let fresh = !thumbInflight.contains(it.path)
        if fresh { thumbInflight.insert(it.path) }
        thumbLock.unlock()
        if fresh {
            thumbQueue.addOperation { [weak self] in
                guard let self else { return }
                let data = self.localMode
                    ? try? Data(contentsOf: URL(fileURLWithPath: it.path))
                    : Adb.pullBytes(it.path, timeout: 8)
                var made: NSImage?
                if let data, let big = GalleryView.decode(data, maxPx: cfg.listThumbPx) {
                    made = GalleryView.scaledThumb(big, px: cfg.listThumbPx)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.thumbLock.lock(); self.thumbInflight.remove(it.path); self.thumbLock.unlock()
                    if let t = made { self.thumbCache.setObject(t, forKey: key) }
                    self.listView.needsDisplay = true
                }
            }
        }
        return nil
    }

    static func scaledThumb(_ img: NSImage, px: Int) -> NSImage {
        let s = img.size
        let k = min(1, CGFloat(px) / max(s.width, s.height))
        let out = NSImage(size: NSSize(width: max(1, s.width * k), height: max(1, s.height * k)))
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: out.size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// 列表总高度随 items 变化（删除后缩短），并刷新当前张高亮
    func refreshList() {
        let h = max(1, CGFloat(items.count) * cfg.listRowHeight)
        listView.setFrameSize(NSSize(width: cfg.listWidth, height: h))
        listView.needsDisplay = true
        if listVisible { listView.scrollToCurrent() }
    }

    func setListVisible(_ v: Bool) {
        guard v != listVisible else { return }
        listVisible = v
        listScroll.isHidden = !v
        lastLayoutSize = .zero          // 强制按新的可视区重新适配
        needsLayout = true
        layout()
        refreshList()
        flash(v ? "照片列表已显示（L 隐藏）" : "照片列表已隐藏（L 显示）")
    }

    // MARK: 缩放 / 平移

    /// 图片在窗口里的逻辑尺寸（点）。注意不能用 rep 的像素尺寸：2x 图会翻倍，
    /// 那样「100% 缩放」实际会变成 200%，适配比例也算错。
    func docSize(_ img: NSImage) -> NSSize {
        let s = img.size
        return (s.width > 0 && s.height > 0) ? s : NSSize(width: 1, height: 1)
    }

    /// 计算「刚好铺满窗口」的比例，并应用
    func fitAndApplyScale(imageSize: NSSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        // 记录「已经按这个窗口尺寸适配过」，避免之后任何一次 layout 又把缩放重置回去
        let area = photoArea
        lastLayoutSize = area
        let sx = area.width / imageSize.width
        let sy = area.height / imageSize.height
        var fit = min(sx, sy)
        if !cfg.fitUpscale { fit = min(fit, 1.0) }   // 小图不放大，按原尺寸显示
        fitScale = Double(fit)
        scrollView.magnification = CGFloat(fitScale)
        recenter()
        updateTitle()
    }

    /// 触发一次与锚点缩放完全相同的边界约束（幂等，不会把已锚定好的画面推回中间）
    func recenter() {
        guard let cv = scrollView.contentView as? CenteredClipView else { return }
        let target = cv.constrainedOrigin(cv.bounds.origin, boundsSize: cv.bounds.size)
        if abs(target.x - cv.bounds.origin.x) > 0.01 || abs(target.y - cv.bounds.origin.y) > 0.01 {
            cv.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(cv)
    }

    func isZoomedIn() -> Bool {
        scrollView.magnification > CGFloat(fitScale) * 1.02
    }

    /// 所有缩放入口（双击 / ⌘滚轮 / +/- / 0）统一走这里。
    /// anchorInView 是「本视图本地坐标」的屏幕点；不变量：缩放前后，该屏幕点下的
    /// 那一点图像内容保持在同一个屏幕坐标。传 nil 表示以可视区中心为锚点（键盘行为）。
    ///
    /// 实测几何：documentView.frame 恒为原图尺寸（文档坐标，不随 magnification 变化），
    /// clipView.bounds.size = 屏幕尺寸 / magnification，clipView.convert(屏幕点) 正好
    /// 返回「指针下的文档坐标」。旧实现把屏幕点和文档坐标直接相加再除倍率，量纲就是错的。
    func setZoom(_ m: Double, anchorInView: NSPoint? = nil) {
        guard let cv = scrollView.contentView as? CenteredClipView, m.isFinite else { return }
        let oldMag = CGFloat(scrollView.magnification)
        let newMag = CGFloat(min(max(m, cfg.zoomMin), cfg.zoomMax))
        guard oldMag > 0, newMag > 0 else { return }
        // 到达上下限：不做任何几何改动，避免边界处多出一次无效抖动
        if abs(newMag - oldMag) < 1e-9 { return }

        let anchor = anchorInView ?? NSPoint(x: bounds.width / 2, y: bounds.height / 2)
        let d = cv.convert(anchor, from: self)          // 指针下的文档坐标（缩放无关）
        let o0 = cv.bounds.origin
        let k = oldMag / newMag
        // 同一内容点的文档坐标恒为 d；令 o_new + p/newMag = d，其中 p = (d - o0)*oldMag
        let desired = NSPoint(x: d.x - (d.x - o0.x) * k,
                              y: d.y - (d.y - o0.y) * k)

        scrollView.magnification = newMag               // AppKit 会临时把 origin 改成保持中心
        // 用缩放后的 bounds.size 施加同一套约束：边缘/四角/上下限处平滑夹住，不会越界
        let final = cv.constrainedOrigin(desired, boundsSize: cv.bounds.size)
        cv.setBoundsOrigin(final)                      // 覆盖 AppKit 的临时 origin
        scrollView.reflectScrolledClipView(cv)
        updateTitle()
        if isZoomedIn() { ensureFull() }               // 放大看细节时才去解全分辨率
    }

    func zoomIn(anchor: NSPoint? = nil) {
        setZoom(Double(scrollView.magnification) * cfg.zoomStep, anchorInView: anchor)
    }

    func zoomOut(anchor: NSPoint? = nil) {
        setZoom(Double(scrollView.magnification) / cfg.zoomStep, anchorInView: anchor)
    }

    func resetZoom() {
        setZoom(fitScale)
    }

    /// 双击兼容入口：由映射表的 double_click / double_click_again 驱动
    func toggleZoom(anchor: NSPoint) {
        perform(cfg.input.resolvedAction(dblArmed ? .doubleClickAgain : .doubleClick), pointer: anchor)
        dblArmed.toggle()
    }


    /// FSViewer / FastStone 风格滚轮缩放（zoom_continuous 的唯一实现）。
    /// · 主导轴为正 = 向上滚 → 放大；为负 = 向下滚 → 缩小；与当前是否放大无关
    /// · 以指针为锚点，复用 setZoom 的几何不变量：指针下的图像内容保持在同一屏幕坐标
    /// · 连续事件按 exp(位移) 相乘；触控板像素位移换算成同一量级，单次事件限幅 → 平滑无跳变
    /// · 目标倍率夹在 zoom_min…zoom_max；到边界后 setZoom 直接 return，不会抖动
    /// · 独占事件：不累加 wheelAccum（不切照片）、不调用 super（不产生页面/滚动条滚动）
    func wheelZoom(deltaY: CGFloat, deltaX: CGFloat, anchor: NSPoint?, event: NSEvent?) {
        // 实测：普通滚轮 deltaY 是「行」；触控板精确滚动 deltaY 已被 AppKit 归一化（像素÷10），
        // 而 scrollingDeltaY 才是原始像素。这里统一换算成行量级，两种设备手感一致。
        let raw: CGFloat
        if let e = event, e.hasPreciseScrollingDeltas {
            raw = abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX)
                ? e.scrollingDeltaY / 10.0 : e.scrollingDeltaX / 10.0
        } else {
            raw = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        }
        var d = raw
        wheelAccum = 0                              // 缩放绝不触发翻页
        if abs(d) < 0.02 { return }                 // 死区：抑制触控板微小噪声造成的抖动
        d = max(-24, min(24, d))                    // 单次限幅：惯性滑动也不会一次拉爆倍率
        let old = Double(scrollView.magnification)
        let target = min(max(old * exp(Double(d) * cfg.wheelZoomSensitivity),
                             cfg.zoomMin), cfg.zoomMax)
        setZoom(target, anchorInView: anchor)
    }

    // MARK: 输入映射分派

    /// 统一动作执行器。pointer 供缩放锚点使用，deltaY / event 供滚轮类动作使用。
    func perform(_ a: InputAction, pointer: NSPoint?, deltaY: CGFloat = 0,
                 deltaX: CGFloat = 0, event: NSEvent? = nil) {
        // macOS 把 Shift+滚轮转成水平滚动（deltaY=0、deltaX≠0），取主导轴保证各组合键行为一致
        let d: CGFloat = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        switch a {
        case .none: break
        case .zoom100: setZoom(1.0, anchorInView: pointer)
        case .zoomFit: resetZoom()
        case .zoomToggle100:
            if abs(Double(scrollView.magnification) - 1.0) < 0.02 { resetZoom() }
            else { setZoom(1.0, anchorInView: pointer) }
        case .zoomInStep: setZoom(Double(scrollView.magnification) * cfg.dblclickStep, anchorInView: pointer)
        case .zoomOutStep: setZoom(Double(scrollView.magnification) / cfg.dblclickStep, anchorInView: pointer)
        case .zoomContinuous:
            wheelZoom(deltaY: deltaY, deltaX: deltaX, anchor: pointer, event: event)
        case .page:
            wheelAccum += d
            let t = cfg.wheelPageThreshold
            if wheelAccum < -t { wheelAccum = 0; show(index + 1) }
            else if wheelAccum > t { wheelAccum = 0; show(index - 1) }
        case .pan:
            if let e = event { super.scrollWheel(with: e) }
        case .pageOrPan:
            if !isZoomedIn() {
                perform(.page, pointer: pointer, deltaY: deltaY, deltaX: deltaX, event: event)
            } else if let e = event { super.scrollWheel(with: e) }
        case .next: show(index + 1)
        case .prev: show(index - 1)
        case .togglePlay: togglePlay()
        case .fullscreen: window?.toggleFullScreen(nil)
        case .delete: requestDelete()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        dblArmed = false
        // 修饰键精确匹配；未匹配 / 命中项被禁用时直接吞掉事件，不会误落到别的动作
        let map = inputMapOverride ?? cfg.input
        guard let e = map.wheelEvent(for: event.modifierFlags, cmdAsCtrl: cfg.wheelCmdAsCtrl) else { return }
        let p = convert(event.locationInWindow, from: nil)
        perform(map.resolvedAction(e), pointer: p,
                deltaY: event.deltaY, deltaX: event.deltaX, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            let p = convert(event.locationInWindow, from: nil)
            let e: InputEvent = dblArmed ? .doubleClickAgain : .doubleClick
            dblArmed.toggle()
            perform(cfg.input.resolvedAction(e), pointer: p)
            return
        }
        // 单击不复位：AppKit 会把双击的第一次点击也发成 clickCount==1
        lastPan = nil
        super.mouseUp(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        dblArmed = false
        let p = convert(event.locationInWindow, from: nil)
        perform(cfg.input.resolvedAction(.rightClick), pointer: p)
        // 不调用 super，避免弹出系统上下文菜单
    }

    override func mouseDown(with event: NSEvent) {
        lastPan = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        dblArmed = false
        guard isZoomedIn(), let last = lastPan,
              let cv = scrollView.contentView as? CenteredClipView else { return }
        let p = convert(event.locationInWindow, from: nil)
        // 屏幕点位移要除以 magnification 才是文档单位；两个轴方向一致（内容跟着手走）
        let m = CGFloat(scrollView.magnification)
        guard m > 0 else { return }
        var o = cv.bounds.origin
        o.x -= (p.x - last.x) / m
        o.y -= (p.y - last.y) / m
        cv.setBoundsOrigin(cv.constrainedOrigin(o, boundsSize: cv.bounds.size))
        scrollView.reflectScrolledClipView(cv)
        lastPan = p
    }

    func updateTitle() {
        guard !items.isEmpty else { return }
        let pct = Int(scrollView.magnification * 100)
        let tag = items[index].kind == .video ? "  [视频]" : ""
        window?.title = "红米相册  \(index + 1) / \(items.count)   \(pct)%\(tag)"
    }

    // MARK: 视频

    func videoCachePath(_ it: MediaItem) -> String {
        cacheDir("videos") + "/" + fnv1a(it.path) + "_" + it.name
    }

    func thumbCachePath(_ it: MediaItem) -> String {
        cacheDir("thumbs") + "/" + fnv1a(it.path) + ".png"
    }

    /// 视频首帧：本地缓存 → 已缓存原片 → 先试拉头部几 MB 抽帧（够用就不拉全文件）
    func loadVideoThumbnail(_ it: MediaItem) {
        let cached = thumbCachePath(it)
        if FileManager.default.fileExists(atPath: cached),
           let d = FileManager.default.contents(atPath: cached),
           let img = NSImage(data: d) {
            applyImage(img)
            if cfg.autoplayVideo { playCurrent() }
            return
        }
        let local = videoCachePath(it)
        if FileManager.default.fileExists(atPath: local) {
            if let frame = extractFrame(video: local) { saveThumb(frame, to: cached); applyFrame(frame) }
            if cfg.autoplayVideo { playCurrent() }
            return
        }
        inflightLock.lock()
        let dup = videoInflight.contains(it.path)
        if !dup { videoInflight.insert(it.path) }
        inflightLock.unlock()
        if dup { return }

        hintLabel.textColor = NSColor(white: 0.55, alpha: 1)
        hintLabel.stringValue = "正在后台拉取首帧…"

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, let op, !op.isCancelled else { return }
            defer {
                self.inflightLock.lock()
                self.videoInflight.remove(it.path)
                self.inflightLock.unlock()
            }
            guard self.currentPath() == it.path else { return }

            let head = cacheDir("tmp") + "/" + fnv1a(it.path) + "_head.mp4"
            defer { try? FileManager.default.removeItem(atPath: head) }

            var frame: NSImage?
            if cfg.videoHeadMB > 0, Adb.pullHead(it.path, mb: cfg.videoHeadMB, dest: head) {
                frame = self.extractFrame(video: head)
            }
            if frame == nil {
                DispatchQueue.main.async { self.hintLabel.stringValue = "正在拉取视频（\(fmtBytes(it.size))）…" }
                let tmp = cacheDir("tmp") + "/" + it.name
                if Adb.pullTo(it.path, dest: tmp) {
                    if cfg.cacheVideo {
                        try? FileManager.default.copyItem(atPath: tmp, toPath: local)
                        self.pruneVideoCache()
                    }
                    frame = self.extractFrame(video: tmp)
                    try? FileManager.default.removeItem(atPath: tmp)
                }
            }
            guard let frame else {
                DispatchQueue.main.async { self.flash("抽不出首帧，按 P 直接播放") }
                return
            }
            self.saveThumb(frame, to: cached)
            DispatchQueue.main.async {
                guard self.index < self.items.count, self.items[self.index].path == it.path else { return }
                self.applyFrame(frame)
                if cfg.autoplayVideo { self.playCurrent() }
            }
        }
        videoQueue.addOperation(op)
    }

    func applyFrame(_ img: NSImage) {
        loadingLabel.isHidden = true
        imageView.image = img
        let px = docSize(img)
        imageView.frame = NSRect(origin: .zero, size: px)
        fitAndApplyScale(imageSize: px)
    }

    func saveThumb(_ img: NSImage, to path: String) {
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func extractFrame(video path: String, atSecond: Double = 1.0) -> NSImage? {
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: cfg.thumbPx, height: cfg.thumbPx)
        for sec in [atSecond, 0.0] {
            do {
                let cg = try gen.copyCGImage(at: CMTime(seconds: sec, preferredTimescale: 600), actualTime: nil)
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } catch { continue }
        }
        return nil
    }

    /// 播放当前视频：本地有缓存直接播，没有先拉取
    func playCurrent() {
        guard !items.isEmpty else { return }
        let it = items[index]
        guard it.kind == .video else { flash("当前不是视频"); return }

        let local = videoCachePath(it)
        if FileManager.default.fileExists(atPath: local) {
            startPlayer(path: local)
            return
        }
        hintLabel.textColor = NSColor(white: 0.6, alpha: 1)
        hintLabel.stringValue = "正在拉取视频（\(fmtBytes(it.size))），请稍候…"
        let op = BlockOperation { [weak self] in
            guard let self = self else { return }
            let tmp = cacheDir("tmp") + "/" + it.name
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            guard Adb.pullTo(it.path, dest: tmp) else {
                DispatchQueue.main.async { self.flash("视频拉取失败") }
                return
            }
            if cfg.cacheVideo {
                try? FileManager.default.copyItem(atPath: tmp, toPath: local)
                self.pruneVideoCache()
            }
            DispatchQueue.main.async {
                if self.index < self.items.count, self.items[self.index].path == it.path {
                    self.startPlayer(path: tmp)
                }
            }
        }
        videoQueue.addOperation(op)
    }

    func startPlayer(path: String) {
        imageView.image = nil
        playerView.isHidden = false
        playerView.player = AVPlayer(url: URL(fileURLWithPath: path))
        playerView.player?.play()
        flash("播放中：P 暂停 / 继续")
    }

    func stopPlayer() {
        playerView.player?.pause()
        playerView.player = nil
        playerView.isHidden = true
    }

    func togglePlay() {
        guard let p = playerView.player, !playerView.isHidden else {
            if !items.isEmpty, items[index].kind == .video { playCurrent() }
            else { show(index + 1) }
            return
        }
        if p.rate == 0 { p.play(); flash("继续") } else { p.pause(); flash("已暂停") }
    }

    /// 视频缓存超限清理（按最后访问时间）—— 走后台线程，别卡主线程
    func pruneVideoCache() {
        DispatchQueue.global(qos: .background).async {
            let dir = cacheDir("videos")
            let fm = FileManager.default
                guard let files = try? fm.contentsOfDirectory(atPath: dir), !files.isEmpty else { return }
            var total: UInt64 = 0
            var infos: [(path: String, size: UInt64, atime: Date)] = []
            for f in files {
                let p = dir + "/" + f
                guard let a = try? fm.attributesOfItem(atPath: p) else { continue }
                let sz = (a[.size] as? NSNumber)?.uint64Value ?? 0
                let t = (a[.modificationDate] as? Date) ?? .distantPast
                total += sz
                infos.append((p, sz, t))
            }
            let limit = UInt64(cfg.cacheMaxMB) * 1_048_576
            guard total > limit else { return }
            infos.sort { $0.atime < $1.atime }
            for i in infos {
                if total <= limit { break }
                try? fm.removeItem(atPath: i.path)
                total -= i.size
            }
        }
    }

    /// 预取：按距离远近排队，近的优先
    func prefetch() {
        let r = prefetchRadiusOverride ?? cfg.prefetch
        var order: [Int] = []
        for i in (index - r)...(index + r) where i >= 0 && i < items.count { order.append(i) }
        order.sort { abs($0 - index) < abs($1 - index) }
        for i in order {
            if items[i].kind == .video {
                if prefetchVideoOverride ?? cfg.prefetchVideo { prefetchVideoThumb(i) }
            } else {
                enqueueImage(i, urgent: i == index)
            }
        }
    }

    /// 视频预读（prefetch_video=1）：只为预读窗口内的视频提前生成首帧缩略图。
    /// 只拉开头 video_head_mb，绝不整件下载；写磁盘缓存、不碰手机文件、不阻塞当前视频加载。
    /// 关掉（默认 0）时保持原行为：仅停留 video_delay 后才处理。
    func prefetchVideoThumb(_ i: Int) {
        guard i >= 0, i < items.count else { return }
        let it = items[i]
        guard it.kind == .video, cfg.videoThumb else { return }
        if cfg.videoThumbMaxMB > 0, it.size > Int64(cfg.videoThumbMaxMB) * 1_048_576 { return }
        let dest = thumbCachePath(it)
        if FileManager.default.fileExists(atPath: dest) { return }

        thumbLock.lock()
        let fresh = !videoPrefetchInflight.contains(it.path)
        if fresh { videoPrefetchInflight.insert(it.path) }
        thumbLock.unlock()
        guard fresh else { return }

        thumbQueue.addOperation { [weak self] in
            guard let self else { return }
            let tmp = cacheDir("tmp") + "/" + fnv1a(it.path) + "_pre.mp4"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            var frame: NSImage?
            if self.localMode {
                frame = self.extractFrame(video: it.path)
            } else if cfg.videoHeadMB > 0, Adb.pullHead(it.path, mb: cfg.videoHeadMB, dest: tmp) {
                frame = self.extractFrame(video: tmp)
            }
            if let frame { self.saveThumb(frame, to: dest) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.thumbLock.lock(); self.videoPrefetchInflight.remove(it.path); self.thumbLock.unlock()
                guard let frame else { return }
                self.thumbCache.setObject(frame, forKey: it.path as NSString)
                if self.currentPath() == it.path, self.playerView.isHidden { self.applyFrame(frame) }
                self.listView.needsDisplay = true
            }
        }
    }

    /// 自检用：当前排队中的视频预读任务数
    func videoPrefetchInflightForTest() -> Int {
        thumbLock.lock(); defer { thumbLock.unlock() }
        return videoPrefetchInflight.count
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        dblArmed = false
        switch event.keyCode {
        case 123, 126: show(index - 1)          // ← ↑
        case 124, 125: show(index + 1)          // → ↓
        case 49:       togglePlay()             // 空格：视频播放/暂停，图片则下一张
        case 51, 117:  requestDelete()          // Delete / Fn+Delete
        case 35:       togglePlay()             // P
        case 24:       zoomIn()                 // + / =
        case 27:       zoomOut()                 // - / _
        case 29:       resetZoom()               // 0
        case 3:        window?.toggleFullScreen(nil)  // F
        case 37:       setListVisible(!listVisible)  // L：照片列表开关
        case 116:      show(index - 10)         // PageUp
        case 121:      show(index + 10)         // PageDown
        case 115:      show(0)                  // Home
        case 119:      show(items.count - 1)    // End
        default:       super.keyDown(with: event)
        }
    }

    // MARK: 删除（先备份到 Mac，再从手机删）

    func requestDelete() {
        guard !items.isEmpty else { return }
        if !pendingDelete {
            pendingDelete = true
            hintLabel.textColor = NSColor.systemYellow
            hintLabel.stringValue = "⚠️ 再按一次 Delete 就删除（删除前会先备份到 Mac）"
            deleteTimer?.invalidate()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: cfg.deleteConfirm, repeats: false) { [weak self] _ in
                self?.resetHint()
            }
            return
        }
        deleteTimer?.invalidate()
        performDelete()
    }

    func resetHint() {
        pendingDelete = false
        hintLabel.textColor = NSColor(white: 0.55, alpha: 1)
        hintLabel.stringValue = GalleryView.hintText
    }

    /// 乐观删除：第二次按下 Delete 立刻把当前项从列表拿掉并显示下一张（零等待），
    /// 备份和真删除在后台串行队列继续；失败则把项放回原处并明确提示。
    func performDelete() {
        pendingDelete = false
        deleteTimer?.invalidate(); deleteTimer = nil
        // 第一次按下时那条黄色确认提示要立刻收掉，否则取消 timer 后它会一直挂在屏幕上
        msgTimer?.invalidate(); msgTimer = nil
        resetHint()
        guard !items.isEmpty else { return }
        let i = index
        let it = items[i]

        stopPlayer()

        // 1) 主线程立刻更新界面。删的是快照 it，不依赖后台完成时的 index，
        //    所以用户马上翻页或连着删下一张都不会删错项。
        var arr = items
        arr.remove(at: i)
        items = arr
        refreshList()          // 列表同步去掉这一行
        if items.isEmpty {
            imageView.image = nil
            titleLabel.stringValue = "已看完，没有更多照片"
            infoLabel.stringValue = ""
            loadingLabel.isHidden = true
            hintLabel.textColor = NSColor(white: 0.55, alpha: 1)
            hintLabel.stringValue = "最后一张正在后台删除…"
        } else {
            let next = min(i, items.count - 1)
            index = next
            show(next)
        }

        // 2) 后台铁律：先备份，备份不成功就绝不调用删除，整单撤回
        let op = BlockOperation { [weak self] in
            guard let self = self else { return }
            // ?? 右侧是 autoclosure：只有 simulator 为 nil 才会执行真实备份/删除
            let backedUp = self.backupSimulator?(it) ?? self.backupForDelete(it)
            let outcome: DeleteOutcome
            if backedUp {
                let ok = self.deleteSimulator?(it) ?? Adb.delete(it)
                outcome = ok ? .done : .deleteFailed
            } else {
                outcome = .backupFailed     // 到这里为止，手机上什么都没动过
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch outcome {
                case .done:
                    self.cache.removeObject(forKey: it.path as NSString)
                    self.dataCache.removeObject(forKey: it.path as NSString)
                    self.fullCache.removeObject(forKey: it.path as NSString)
                    if cfg.deleteSuccessHint {
                        self.flash("已删除 \(it.name)，备份在 Pictures/红米相册回收站")
                    }
                case .backupFailed:
                    self.restore(it, at: i)
                    self.flash("⚠️ 备份失败，未删除 \(it.name)：照片已放回列表，手机上文件没动",
                               seconds: 10, color: .systemOrange)
                case .deleteFailed:
                    self.restore(it, at: i)
                    self.flash("⚠️ 删除失败：\(it.name) 已放回列表，文件仍在手机上（备份已保存）",
                               seconds: 8, color: .systemRed)
                }
            }
        }
        deleteQueue.addOperation(op)
    }

    /// 删除前的备份。图片优先复用已缓存的原始字节，省掉一次 adb 往返。
    /// 返回 false 时调用方必须放弃删除。唯一「没备份也返回 true」的情况是用户
    /// 主动设了 backup_video = 0（明确放弃视频备份），那是有意选择，不是失败。
    func backupForDelete(_ it: MediaItem) -> Bool {
        if it.kind == .video && !cfg.backupVideo { return true }
        if let d = dataCache.object(forKey: it.path as NSString) as Data? {
            return writeBackup(it, d)
        }
        if localMode {
            // 本地测试目录：直接读本机文件，绝不去连手机 adb
            return writeBackup(it, (try? Data(contentsOf: URL(fileURLWithPath: it.path))) ?? Data())
        }
        if it.kind == .video {
            let local = videoCachePath(it)
            if FileManager.default.fileExists(atPath: local),
               let d = FileManager.default.contents(atPath: local) {
                return writeBackup(it, d)
            }
            let tmp = cacheDir("tmp") + "/" + fnv1a(it.path) + "_bak_" + it.name
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            if Adb.pullTo(it.path, dest: tmp) {
                return writeBackup(it, FileManager.default.contents(atPath: tmp) ?? Data())
            }
            return false
        }
        return writeBackup(it, Adb.pullBytes(it.path) ?? Data())
    }

    /// 删除失败时把项放回列表。插在当前位置之前时 index 跟着 +1，画面和标题不串位
    func restore(_ it: MediaItem, at i: Int) {
        var arr = items
        guard !arr.contains(where: { $0.path == it.path }) else { return }
        let p = min(max(i, 0), arr.count)
        arr.insert(it, at: p)
        items = arr
        if p <= index { index = min(index + 1, items.count - 1) }
        inflightLock.lock(); inflight.remove(it.path); inflightLock.unlock()
        if imageView.image == nil { show(index) } else { updateTitle() }
    }

    func writeBackup(_ it: MediaItem, _ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HHmmss_SSS"   // 连着删时避免同名文件互相覆盖
        let base = ensureDir((backupDirOverride ?? cfg.backupDir) + "/" + df.string(from: Date()))
        let dest = "\(base)/\(tf.string(from: Date()))_\(it.name)"
        return (try? data.write(to: URL(fileURLWithPath: dest))) != nil
    }

    func flash(_ msg: String, seconds: TimeInterval = 3, color: NSColor = .systemGreen) {
        hintLabel.textColor = color
        hintLabel.stringValue = msg
        msgTimer?.invalidate()
        msgTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.resetHint()
        }
    }
}

// MARK: - 配置文件读写（设置界面用）

struct ConfigFile {
    static var path: String { Config.path }

    static func read() -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? Config.sample()
    }

    /// 逐键替换：保留注释行、其它键和行尾注释；缺失的键追加到末尾。
    /// 同一键出现多次时全部改写，避免与「最后一次生效」规则产生歧义。
    static func update(_ raw: String, changes: [String: String]) -> String {
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let pendingKeys = changes
        var matched = Set<String>()
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            guard let v = pendingKeys[k] else { continue }
            let valuePart = String(t[t.index(after: eq)...])
            var comment = ""
            if let h = valuePart.firstIndex(of: "#") {
                comment = "  " + String(valuePart[h...]).trimmingCharacters(in: .whitespaces)
            }
            let indent = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))
            lines[i] = "\(indent)\(k) = \(v)\(comment)"
            matched.insert(k)
        }
        var missing = pendingKeys
        for k in matched { missing.removeValue(forKey: k) }
        if !missing.isEmpty {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("# 由设置界面追加")
            for k in missing.keys.sorted() { lines.append("\(k) = \(missing[k]!)") }
        }
        var out = lines.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    @discardableResult
    static func write(_ text: String) -> Bool {
        (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}

// MARK: - 设置窗口

final class ConfigWindowController: NSWindowController {
    private var rawText = ""
    private var segment: NSSegmentedControl!
    private var page1: NSView!          // 输入映射
    private var pageBrowse: NSView!     // 浏览 / 预读
    private var page2: NSView!          // 全部参数（原文）
    private var textView: NSTextView!
    private var mediaFilterPopup: NSPopUpButton!
    private var prefetchPopup: NSPopUpButton!
    private var prefetchVideoCheck: NSButton!
    private var browseHintLabel: NSTextField!
    /// 只有在「浏览 / 预读」页动手改过，才把 prefetch / prefetch_video 写回文本，
    /// 避免在「全部参数」页手工改的值被未改动的控件覆盖
    private var browseDirty = false
    private var popups: [InputEvent: NSPopUpButton] = [:]
    private var enables: [InputEvent: NSButton] = [:]
    private var expectationLabel: NSTextField!
    private var warningLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var tipLabel: NSTextField!
    private var inputHost: NSView!
    private var viewModeSeg: NSSegmentedControl!
    private var headerLabels: [NSTextField] = []
    private var nameLabels: [InputEvent: NSTextField] = [:]
    private var condLabels: [InputEvent: NSTextField] = [:]
    private var cards: [InputEvent: NSView] = [:]
    private var icons: [InputEvent: NSImageView] = [:]
    private enum ViewMode { case list, cards }
    private var inputMode: ViewMode = .list

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        super.init(window: w)
        w.title = "红米相册 · 设置"
        // 跟随系统外观：labelColor / windowBackgroundColor 会自动适配浅色与深色
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String, size: CGFloat = 12,
                       color: NSColor = .labelColor, bold: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        f.textColor = color
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 3
        return f
    }

    private func button(_ title: String, _ action: Selector, _ x: CGFloat, _ w: CGFloat) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.frame = NSRect(x: x, y: 18, width: w, height: 32)
        b.autoresizingMask = [.maxXMargin, .maxYMargin]
        return b
    }

    private func buildUI() {
        guard let w = window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 860, height: 680))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        w.contentView = content

        let header = label("配置文件：~/.config/redmi-gallery.conf   ·   改动保存后重启程序生效",
                           size: 12, color: .secondaryLabelColor)
        header.frame = NSRect(x: 20, y: 646, width: 820, height: 20)
        content.addSubview(header)

        // 不用 NSTabView：它在无窗口的离屏/自检环境里 addTabViewItem 会触发 AppKit 异常
        segment = NSSegmentedControl(frame: NSRect(x: 20, y: 610, width: 360, height: 28))
        segment.segmentCount = 3
        segment.setLabel("输入映射", forSegment: 0)
        segment.setLabel("浏览 / 预读", forSegment: 1)
        segment.setLabel("全部参数", forSegment: 2)
        segment.selectedSegment = 0
        segment.target = self
        segment.action = #selector(switchPage(_:))
        content.addSubview(segment)

        page1 = buildInputPage()
        pageBrowse = buildBrowsePage()
        page2 = buildRawPage()
        for p in [page1, pageBrowse, page2] {
            p?.setFrameOrigin(NSPoint(x: 20, y: 108))
            if let p = p { content.addSubview(p) }
        }
        pageBrowse.isHidden = true
        page2.isHidden = true

        statusLabel = label("", size: 11, color: .secondaryLabelColor)
        statusLabel.frame = NSRect(x: 20, y: 78, width: 820, height: 18)
        content.addSubview(statusLabel)

        for b in [button("取消", #selector(cancel(_:)), 20, 84),
                  button("打开配置文件…", #selector(openFile(_:)), 112, 146),
                  button("恢复默认", #selector(restoreDefaults(_:)), 266, 100),
                  button("保存并重启", #selector(saveAndRestart(_:)), 590, 122),
                  button("保存", #selector(save(_:)), 722, 118)] {
            content.addSubview(b)
        }
    }

    /// 每个事件一张小示意图：鼠标轮廓 + 该事件的特征标记，作为「图片列表」的缩略图
    private func eventIcon(_ e: InputEvent) -> NSImage {
        let s: CGFloat = 40
        let im = NSImage(size: NSSize(width: s, height: s))
        im.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: 9, yRadius: 9)
        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill(); bg.fill()
        let body = NSBezierPath(roundedRect: NSRect(x: 13, y: 5, width: 14, height: 30), xRadius: 7, yRadius: 7)
        NSColor.labelColor.withAlphaComponent(0.85).setStroke(); body.lineWidth = 1.3; body.stroke()
        let split = NSBezierPath(); split.move(to: NSPoint(x: 20, y: 35)); split.line(to: NSPoint(x: 20, y: 25))
        split.lineWidth = 1.1; split.stroke()
        NSColor.controlAccentColor.setFill()
        switch e {
        case .doubleClick, .doubleClickAgain:
            NSBezierPath(ovalIn: NSRect(x: 15.5, y: 28, width: 3.5, height: 3.5)).fill()
            NSBezierPath(ovalIn: NSRect(x: 21.5, y: 28, width: 3.5, height: 3.5)).fill()
        case .rightClick:
            NSBezierPath(ovalIn: NSRect(x: 21.5, y: 28, width: 3.5, height: 3.5)).fill()
        case .wheel, .shiftWheel, .ctrlWheel, .altWheel:
            NSBezierPath(roundedRect: NSRect(x: 18.5, y: 26, width: 3, height: 7), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let badge: String
        switch e {
        case .shiftWheel: badge = "⇧"
        case .ctrlWheel:  badge = "⌃"
        case .altWheel:   badge = "⌥"
        default:          badge = ""
        }
        if !badge.isEmpty {
            (badge as NSString).draw(at: NSPoint(x: 2, y: 24),
                                     withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                                      .foregroundColor: NSColor.controlAccentColor])
        }
        im.unlockFocus()
        return im
    }

    /// 纯 frame 手工布局。所有行共用一个「行矩形 + 中心线」，四个横向元素按同一 cy 居中，
    /// 消除文字标签与下拉框/勾选框的垂直偏差；列 x 固定，行距恒定。
    private func buildInputPage() -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 470))
        inputHost = host

        // 查看方式切换（放在页内右上角，不干扰主分段控件）
        viewModeSeg = NSSegmentedControl(frame: NSRect(x: 616, y: 440, width: 168, height: 24))
        viewModeSeg.segmentCount = 2
        viewModeSeg.setLabel("列表", forSegment: 0)
        viewModeSeg.setLabel("图片列表", forSegment: 1)
        viewModeSeg.selectedSegment = 0
        viewModeSeg.target = self
        viewModeSeg.action = #selector(switchViewMode(_:))
        host.addSubview(viewModeSeg)

        for (t, x, w) in [("事件", 16, 200), ("触发条件", 224, 250),
                          ("动作", 482, 205), ("启用", 700, 60)] as [(String, CGFloat, CGFloat)] {
            let l = label(t, bold: true)
            l.frame = NSRect(x: x, y: 410, width: w, height: 18)
            host.addSubview(l)
            headerLabels.append(l)
        }

        for e in InputEvent.allCases {
            let name = label(e.label, size: 11)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = e.label
            let cond = label(e.condition, size: 10, color: .secondaryLabelColor)
            cond.lineBreakMode = .byTruncatingTail
            cond.toolTip = e.condition
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            for a in InputAction.allCases {
                p.addItem(withTitle: a.label)
                p.lastItem?.representedObject = a.rawValue
            }
            p.target = self; p.action = #selector(inputChanged(_:))
            let c = NSButton(checkboxWithTitle: "", target: self, action: #selector(inputChanged(_:)))

            // 卡片：图片列表模式的容器，先建好、默认隐藏
            let card = NSView(frame: .zero)
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.8).cgColor
            card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
            card.layer?.borderWidth = 1
            let icon = NSImageView(frame: NSRect(x: 12, y: 7, width: 40, height: 40))
            icon.image = eventIcon(e)
            icon.imageScaling = .scaleProportionallyUpOrDown
            card.addSubview(icon)
            icons[e] = icon
            host.addSubview(card)
            cards[e] = card

            host.addSubview(name); host.addSubview(cond); host.addSubview(p); host.addSubview(c)
            nameLabels[e] = name; condLabels[e] = cond
            popups[e] = p; enables[e] = c
        }

        expectationLabel = label("选择某个动作可查看预期结果", size: 12, color: .labelColor)
        expectationLabel.frame = NSRect(x: 16, y: 84, width: 768, height: 28)
        host.addSubview(expectationLabel)
        warningLabel = label("", size: 11, color: .systemOrange)
        warningLabel.maximumNumberOfLines = 4
        host.addSubview(warningLabel)
        tipLabel = label("提示：每个事件也可在「全部参数」页用 event.<名称> 与 event.<名称>.enabled 单独配置。",
                         size: 11, color: .secondaryLabelColor)
        tipLabel.frame = NSRect(x: 16, y: 2, width: 768, height: 18)
        host.addSubview(tipLabel)

        layoutRows(.list)
        return host
    }

    /// 同一套控件对象在两种视图间只换父视图与 frame，数据与交互天然保持一致
    private func layoutRows(_ mode: ViewMode) {
        inputMode = mode
        let cardMode = mode == .cards
        for l in headerLabels { l.isHidden = cardMode }
        expectationLabel.isHidden = cardMode
        tipLabel.isHidden = cardMode
        warningLabel.frame = cardMode
            ? NSRect(x: 16, y: 4, width: 768, height: 32)
            : NSRect(x: 16, y: 24, width: 768, height: 56)

        for (idx, e) in InputEvent.allCases.enumerated() {
            let name = nameLabels[e]!, cond = condLabels[e]!
            let p = popups[e]!, c = enables[e]!, card = cards[e]!
            card.isHidden = !cardMode
            if cardMode {
                let y = 432 - CGFloat(idx + 1) * 56
                card.frame = NSRect(x: 16, y: y, width: 768, height: 54)
                card.addSubview(name); card.addSubview(cond); card.addSubview(p); card.addSubview(c)
                let cy: CGFloat = 27                 // 卡片本地坐标的中心线
                name.frame = NSRect(x: 66,  y: cy + 1,  width: 320, height: 18)
                cond.frame = NSRect(x: 66,  y: cy - 19, width: 320, height: 18)
                p.frame    = NSRect(x: 404, y: cy - 13, width: 210, height: 26)
                c.frame    = NSRect(x: 690, y: cy - 12, width: 40,  height: 24)
            } else {
                let cy = 410 - CGFloat(idx + 1) * 42 + 21   // 行矩形中心线
                inputHost.addSubview(name); inputHost.addSubview(cond)
                inputHost.addSubview(p); inputHost.addSubview(c)
                name.frame = NSRect(x: 16,  y: cy - 14, width: 200, height: 28)
                cond.frame = NSRect(x: 224, y: cy - 14, width: 250, height: 28)
                p.frame    = NSRect(x: 482, y: cy - 13, width: 205, height: 26)
                c.frame    = NSRect(x: 700, y: cy - 12, width: 40,  height: 24)
            }
        }
    }

    @objc private func switchViewMode(_ sender: Any?) {
        layoutRows(viewModeSeg.selectedSegment == 1 ? .cards : .list)
    }

    /// 「浏览 / 预读」页：只放两个最常用的性能参数，值域与默认值由控件约束
    private func buildBrowsePage() -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 470))

        let title = label("浏览 / 预读", size: 16, bold: true)
        title.frame = NSRect(x: 16, y: 436, width: 768, height: 22)
        host.addSubview(title)
        let desc = label("决定看什么、提前准备多少内容；改动保存后重启程序生效。", size: 12,
                         color: .secondaryLabelColor)
        desc.frame = NSRect(x: 16, y: 414, width: 768, height: 20)
        host.addSubview(desc)

        // 查看内容范围（新）
        let l0 = label("查看内容", size: 13, bold: true)
        l0.frame = NSRect(x: 16, y: 382, width: 200, height: 22)
        host.addSubview(l0)
        mediaFilterPopup = NSPopUpButton(frame: NSRect(x: 16, y: 350, width: 200, height: 26), pullsDown: false)
        for f in MediaFilter.allCases {
            mediaFilterPopup.addItem(withTitle: f.label)
            mediaFilterPopup.lastItem?.representedObject = f.rawValue
        }
        mediaFilterPopup.target = self
        mediaFilterPopup.action = #selector(browseChanged(_:))
        host.addSubview(mediaFilterPopup)
        let h0 = label("all = 图片 + 视频（默认）；images = 只看图片；videos = 只看视频。\n"
                         + "只影响启动时构建的相册列表，保存后重启生效。",
                         size: 11, color: .secondaryLabelColor)
        h0.frame = NSRect(x: 228, y: 348, width: 560, height: 36)
        host.addSubview(h0)

        let l1 = label("照片预读数量（当前照片前后各 N 张）", size: 13, bold: true)
        l1.frame = NSRect(x: 16, y: 312, width: 420, height: 22)
        host.addSubview(l1)
        prefetchPopup = NSPopUpButton(frame: NSRect(x: 16, y: 278, width: 180, height: 28), pullsDown: false)
        for n in 0...10 {
            prefetchPopup.addItem(withTitle: n == 0 ? "0 张（关闭预读）" : "\(n) 张")
        }
        prefetchPopup.target = self
        prefetchPopup.action = #selector(browseChanged(_:))
        host.addSubview(prefetchPopup)
        let h1 = label("每翻到一张，就提前把前后各 N 张照片从手机读进内存。\n"
                         + "0 = 完全不预读；数值越大翻页越顺，但越占内存与 USB 带宽。范围固定 0~10。",
                         size: 11, color: .secondaryLabelColor)
        h1.frame = NSRect(x: 212, y: 254, width: 560, height: 48)
        host.addSubview(h1)

        let l2 = label("视频预读", size: 13, bold: true)
        l2.frame = NSRect(x: 16, y: 210, width: 420, height: 22)
        host.addSubview(l2)
        prefetchVideoCheck = NSButton(checkboxWithTitle: "提前为预读窗口内的视频生成首帧缩略图",
                                      target: self, action: #selector(browseChanged(_:)))
        prefetchVideoCheck.frame = NSRect(x: 16, y: 178, width: 460, height: 24)
        host.addSubview(prefetchVideoCheck)
        let h2 = label("关闭（默认）：只在翻到某个视频并停留后才处理。\n"
                         + "开启：翻页时顺带提前拉视频开头几 MB 抽首帧，翻到视频秒出画面；绝不整件下载。",
                         size: 11, color: .secondaryLabelColor)
        h2.frame = NSRect(x: 16, y: 124, width: 756, height: 48)
        host.addSubview(h2)

        browseHintLabel = label("", size: 12, color: .controlAccentColor)
        browseHintLabel.frame = NSRect(x: 16, y: 80, width: 756, height: 36)
        host.addSubview(browseHintLabel)
        let tip = label("对应配置键：media_filter、prefetch（0~10）、prefetch_video（0/1）；也可在「全部参数」页直接编辑。",
                        size: 11, color: .secondaryLabelColor)
        tip.frame = NSRect(x: 16, y: 16, width: 756, height: 20)
        host.addSubview(tip)
        return host
    }

    @objc private func browseChanged(_ sender: Any?) {
        browseDirty = true
        updateBrowseHint()
        refreshInfo()
    }

    private func updateBrowseHint() {
        let n = min(10, max(0, prefetchPopup.indexOfSelectedItem))
        let v = prefetchVideoCheck.state == .on
        let f = MediaFilter(rawValue: mediaFilterPopup.selectedItem?.representedObject as? String ?? "")
            ?? .all
        browseHintLabel.stringValue =
            "当前选择：查看 \(f.label)；照片前后各 \(n) 张；视频预读 \(v ? "开启" : "关闭")。"
            + (browseDirty ? "（未保存）" : "（与配置文件一致）")
    }

    private func buildRawPage() -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 470))
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 46, width: 772, height: 410))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 750, height: 400))
        tv.isEditable = true
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        scroll.documentView = tv
        host.addSubview(scroll)
        textView = tv
        let tip = label("直接编辑配置原文，注释会保留。保存时「输入映射」页的 14 个键会覆盖此处的同名项。",
                        size: 11, color: .secondaryLabelColor)
        tip.frame = NSRect(x: 16, y: 14, width: 768, height: 20)
        host.addSubview(tip)
        return host
    }

    // MARK: 数据同步

    func reload() {
        rawText = ConfigFile.read()
        textView.string = rawText
        syncFromText()
        refreshInfo()
    }

    private func syncFromText() {
        let c = Config.load(fromText: rawText)
        for e in InputEvent.allCases {
            let b = c.input.bindings[e] ?? InputBinding(action: .none)
            if let i = InputAction.allCases.firstIndex(of: b.action) { popups[e]?.selectItem(at: i) }
            enables[e]?.state = b.enabled ? .on : .off
        }
        if let fi = MediaFilter.allCases.firstIndex(of: c.mediaFilter) {
            mediaFilterPopup?.selectItem(at: fi)
        }
        prefetchPopup?.selectItem(at: min(10, max(0, c.prefetch)))
        prefetchVideoCheck?.state = c.prefetchVideo ? .on : .off
        browseDirty = false
        updateBrowseHint()
    }

    func currentInputChanges() -> [String: String] {
        var ch: [String: String] = [:]
        for e in InputEvent.allCases {
            ch["event.\(e.rawValue)"] = popups[e]?.selectedItem?.representedObject as? String
                ?? InputAction.none.rawValue
            ch["event.\(e.rawValue).enabled"] = (enables[e]?.state == .on) ? "1" : "0"
        }
        if browseDirty {
            ch["media_filter"] = MediaFilter(rawValue:
                mediaFilterPopup.selectedItem?.representedObject as? String ?? "")?.rawValue
                ?? MediaFilter.all.rawValue
            ch["prefetch"] = String(min(10, max(0, prefetchPopup.indexOfSelectedItem)))
            ch["prefetch_video"] = (prefetchVideoCheck.state == .on) ? "1" : "0"
        }
        return ch
    }

    /// 输入映射页 → 文本（以文本视图当前内容为基底，只覆盖 14 个映射键）
    func syncFromInputs() {
        let base = ConfigFile.update(textView.string, changes: currentInputChanges())
        rawText = base
        if textView.string != base { textView.string = base }
        browseDirty = false
    }

    private func refreshInfo() {
        let c = Config.load(fromText: rawText)
        warningLabel.stringValue = c.warnings.isEmpty
            ? "映射校验：无冲突、无重复、无降级"
            : "映射校验提示：\n" + c.warnings.joined(separator: "\n")
        warningLabel.textColor = c.warnings.isEmpty ? .systemGreen : .systemOrange
        statusLabel.stringValue = "当前文件：\(ConfigFile.path)   ·   共 \(InputEvent.allCases.count) 个事件 / \(InputAction.allCases.count) 个可选动作"
    }

    /// 切页时双向同步：去「全部参数」把控件改动写进文本，回来时用文本刷新控件
    @objc private func switchPage(_ sender: Any?) {
        let sel = segment.selectedSegment
        let toRaw = sel == 2
        // 先把当前页控件写回文本，再用文本刷新所有控件，保证三页共享同一份数据
        syncFromInputs()
        if !toRaw {
            rawText = textView.string
            syncFromText()
        }
        page1.isHidden = sel != 0
        pageBrowse.isHidden = sel != 1
        page2.isHidden = !toRaw
        refreshInfo()
    }

    @objc private func inputChanged(_ sender: Any?) {
        for e in InputEvent.allCases {
            if popups[e] === (sender as? NSPopUpButton) || enables[e] === (sender as? NSButton) {
                let raw = popups[e]?.selectedItem?.representedObject as? String ?? ""
                let a = InputAction(rawValue: raw) ?? .none
                let on = enables[e]?.state == .on
                expectationLabel.stringValue = on
                    ? "\(e.label) → \(a.label)：\(a.expected)"
                    : "\(e.label) 已禁用：该事件完全不响应，也不会回落到其它事件"
                break
            }
        }
        // 实时预览：把当前控件状态套到文本上再校验，不写文件
        let preview = Config.load(fromText: ConfigFile.update(textView.string, changes: currentInputChanges()))
        warningLabel.stringValue = preview.warnings.isEmpty
            ? "映射校验：无冲突、无重复、无降级"
            : "映射校验提示：\n" + preview.warnings.joined(separator: "\n")
        warningLabel.textColor = preview.warnings.isEmpty ? .systemGreen : .systemOrange
    }

    // MARK: 动作

    @objc private func cancel(_ sender: Any?) { window?.close() }

    @objc private func openFile(_ sender: Any?) {
        NSWorkspace.shared.openFile(ConfigFile.path)
    }

    private func saveSilently() -> Bool {
        if segment.selectedSegment != 2 { syncFromInputs() }
        rawText = textView.string
        let text = rawText
        guard ConfigFile.write(text) else { return false }
        rawText = text
        refreshInfo()
        return true
    }

    @objc private func save(_ sender: Any?) {
        if !saveSilently() {
            let a = NSAlert(); a.messageText = "保存失败"
            a.informativeText = "无法写入 \(ConfigFile.path)，请检查权限。"; a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "已保存"
        a.informativeText = "配置已写入 ~/.config/redmi-gallery.conf。\n输入映射等改动需要重启程序后生效。"
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "立即重启")
        if a.runModal() == .alertSecondButtonReturn { relaunch() }
    }

    @objc private func saveAndRestart(_ sender: Any?) {
        if saveSilently() { relaunch() }
        else {
            let a = NSAlert(); a.messageText = "保存失败"
            a.informativeText = "无法写入 \(ConfigFile.path)"; a.runModal()
        }
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "恢复默认配置？"
        a.informativeText = "会用内置默认模板覆盖当前配置文件（含所有注释与自定义值）。"
        a.addButton(withTitle: "恢复默认")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        rawText = Config.sample()
        textView.string = rawText
        syncFromText()
        _ = ConfigFile.write(rawText)
        refreshInfo()
        statusLabel.stringValue = "已恢复默认配置，重启程序后生效"
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 自检用：返回控件数量，确认界面确实建起来了
    func uiCounts() -> (events: Int, actions: Int, warnings: Int) {
        (popups.count, popups[.wheel]?.numberOfItems ?? 0,
         Config.load(fromText: rawText).warnings.count)
    }
    /// 自检用：浏览页参数与分段页
    func browseValuesForTest() -> (prefetch: Int, video: Bool, items: Int, filter: String) {
        (prefetchPopup.indexOfSelectedItem, prefetchVideoCheck.state == .on,
         prefetchPopup.numberOfItems,
         MediaFilter(rawValue: mediaFilterPopup.selectedItem?.representedObject as? String ?? "")?.rawValue
            ?? MediaFilter.all.rawValue)
    }
    func setBrowseForTest(_ n: Int, video: Bool, filter: MediaFilter = .all) {
        if let fi = MediaFilter.allCases.firstIndex(of: filter) { mediaFilterPopup.selectItem(at: fi) }
        prefetchPopup.selectItem(at: min(10, max(0, n)))
        prefetchVideoCheck.state = video ? .on : .off
        browseDirty = true
        updateBrowseHint()
    }
    func selectPageForTest(_ i: Int) {
        segment.selectedSegment = i
        switchPage(nil)
    }
    func setTextForTest(_ t: String) { textView.string = t }
    func mediaFilterOptionsForTest() -> Int { mediaFilterPopup.numberOfItems }
    func pageVisibilityForTest() -> (Bool, Bool, Bool) {
        (!page1.isHidden, !pageBrowse.isHidden, !page2.isHidden)
    }
    /// 自检用：切换查看方式
    func setViewModeForTest(_ cardMode: Bool) {
        viewModeSeg.selectedSegment = cardMode ? 1 : 0
        layoutRows(cardMode ? .cards : .list)
    }
    func currentModeIsCards() -> Bool { inputMode == .cards }
    /// 自检用：每行四个元素的垂直中心（同一父视图内可直接比较）
    func rowCentersForTest() -> [(Double, Double, Double, Double)] {
        InputEvent.allCases.map { e in
            (Double(nameLabels[e]!.frame.midY), Double(condLabels[e]!.frame.midY),
             Double(popups[e]!.frame.midY), Double(enables[e]!.frame.midY))
        }
    }
    /// 自检用：每行四列的 x 起点
    func columnXForTest() -> [(Double, Double, Double, Double)] {
        InputEvent.allCases.map { e in
            (Double(nameLabels[e]!.frame.minX), Double(condLabels[e]!.frame.minX),
             Double(popups[e]!.frame.minX), Double(enables[e]!.frame.minX))
        }
    }
    func cardsForTest() -> (total: Int, visible: Int, icons: Int) {
        (cards.count, cards.values.filter { !$0.isHidden }.count, icons.count)
    }
    /// 自检用：模拟用户在下拉框/复选框上的一次改动
    func setForTest(_ e: InputEvent, action: InputAction, enabled: Bool) {
        if let i = InputAction.allCases.firstIndex(of: action) { popups[e]?.selectItem(at: i) }
        enables[e]?.state = enabled ? .on : .off
    }
    /// 自检用：读取文本视图当前内容
    func textSnapshot() -> String { textView.string }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: GalleryView!
    let localDir: String?
    var settings: ConfigWindowController?

    init(localDir: String?) { self.localDir = localDir }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMainMenu()
        if localDir == nil {
            guard let s = Adb.findDevice() else {
                let a = NSAlert()
                a.messageText = "没检测到手机"
                a.informativeText = "请插上数据线，并在手机上允许 USB 调试后重开本程序。"
                a.runModal()
                NSApp.terminate(nil)
                return
            }
            Adb.serial = s
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 1080),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "红米相册"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.center()

        view = GalleryView(frame: NSRect(x: 0, y: 0, width: 620, height: 1080), localDir: localDir)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        if localDir == nil { view.items = loadPhotosFromDevice() }
        view.start()
        window.makeFirstResponder(view)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: 菜单

    func buildMainMenu() {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "关于 红米相册", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(NSMenuItem.separator())
        let pref = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        pref.target = self
        pref.keyEquivalentModifierMask = .command
        appMenu.addItem(pref)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 红米相册", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 红米相册", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let settingsItem = NSMenuItem()
        menu.addItem(settingsItem)
        let settingsMenu = NSMenu(title: "设置")
        let openFile = NSMenuItem(title: "打开配置文件…", action: #selector(openConfigFile(_:)), keyEquivalent: "")
        openFile.target = self
        settingsMenu.addItem(openFile)
        let reload = NSMenuItem(title: "重新载入配置（重启）", action: #selector(relaunchApp(_:)), keyEquivalent: "r")
        reload.target = self
        reload.keyEquivalentModifierMask = .command
        settingsMenu.addItem(reload)
        settingsItem.submenu = settingsMenu

        let viewItem = NSMenuItem()
        menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let listItem = NSMenuItem(title: "照片列表", action: #selector(togglePhotoList(_:)), keyEquivalent: "l")
        listItem.target = self
        listItem.keyEquivalentModifierMask = .command
        listItem.state = cfg.listVisible ? .on : .off
        viewMenu.addItem(listItem)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = menu
    }

    @objc private func togglePhotoList(_ sender: Any?) {
        guard let v = view else { return }
        v.setListVisible(!v.listVisible)
        (sender as? NSMenuItem)?.state = v.listVisible ? .on : .off
    }

    @objc private func openPreferences(_ sender: Any?) {
        if settings == nil { settings = ConfigWindowController() }
        else { settings?.reload() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openConfigFile(_ sender: Any?) {
        NSWorkspace.shared.openFile(Config.path)
    }

    @objc private func showAbout(_ sender: Any?) {
        let a = NSAlert()
        a.messageText = "红米相册"
        a.informativeText = "在 Mac 上用键盘浏览安卓手机相册。\n\n配置：~/.config/redmi-gallery.conf\n设置：「红米相册 → 偏好设置…」（⌘,）\n输入映射清单：redmi-gallery --input-map"
        a.runModal()
    }

    @objc private func relaunchApp(_ sender: Any?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

// 完整主菜单在 AppDelegate.applicationDidFinishLaunching 里构建（需要 self 作为 target）
NSApplication.shared.setActivationPolicy(.regular)

var localDir: String? = nil
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--dir"), i + 1 < args.count { localDir = args[i + 1] }

// 主窗口照片列表自检
if args.contains("--list-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    print("=== 主窗口照片列表自检 ===")

    // 造 12 张本地小图
    let dir = "/tmp/rglisttest"
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for i in 1...12 {
        let im = NSImage(size: NSSize(width: 200, height: 300))
        im.lockFocus()
        NSColor(calibratedHue: CGFloat(i) / 13, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 200, height: 300).fill()
        im.unlockFocus()
        if let tiff = im.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let d = rep.representation(using: .jpeg, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/pic_\(String(format: "%02d", i)).jpg"))
        }
    }

    let W: CGFloat = 620, H: CGFloat = 900
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: W, height: H), localDir: dir)
    v.layoutSubtreeIfNeeded(); v.layout()
    v.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    // 固定一张已知尺寸的图，避免后台补解/预读在断言之间换图导致 fit 基准漂移
    func fixImage() {
        if let d0 = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/pic_01.jpg")),
           let im0 = NSImage(data: d0) { v.applyImage(im0) }
    }
    fixImage()

    chk("列表读到 12 项", v.listView.count == 12)
    chk("虚拟列表不按行创建子视图", v.listView.subviews.isEmpty)
    chk("列表总高度 = 12 × 行高",
        abs(v.listView.frame.height - CGFloat(v.items.count) * cfg.listRowHeight) < 0.5)
    chk("默认隐藏时图片区占满窗口",
        v.listVisible == false && v.scrollView.frame.minX == 0 && v.scrollView.frame.width == W)

    let fitFull = v.fitScale
    v.setListVisible(true)
    chk("L/菜单可显示侧栏", v.listVisible && !v.listScroll.isHidden)
    chk("显示后图片区右移并缩窄",
        v.scrollView.frame.minX == cfg.listWidth && v.scrollView.frame.width == W - cfg.listWidth)
    chk("标题/提示同步移到图片区",
        v.titleLabel.frame.minX >= cfg.listWidth && v.hintLabel.frame.minX >= cfg.listWidth)
    chk("适配比例按新的可视区重算",
        abs(v.fitScale - Double(min((W - cfg.listWidth) / 200, H / 300))) < 1e-6)
    chk("列表高度仍与 items 一致",
        abs(v.listView.frame.height - CGFloat(v.items.count) * cfg.listRowHeight) < 0.5)

    // 点击第 6 行 → 跳到 index 5
    let rowH = cfg.listRowHeight
    let winPt = v.listView.convert(NSPoint(x: 100, y: rowH * 5 + 10), to: nil)
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: winPt, modifierFlags: [],
                                   timestamp: 0, windowNumber: 0, context: nil,
                                   eventNumber: 1, clickCount: 1, pressure: 0)!
    v.listView.mouseDown(with: click)
    chk("点击列表第 6 行跳转到 index 5", v.index == 5)
    chk("跳转后当前行在列表可见区内",
        v.listScroll.contentView.documentVisibleRect.contains(
            NSPoint(x: 10, y: rowH * 5 + 2)) ||
        NSIntersectsRect(v.listScroll.contentView.documentVisibleRect,
                         NSRect(x: 0, y: rowH * 5, width: 10, height: rowH)))

    // 缩略图：本地文件应能在后台生成并命中缓存
    _ = v.thumbnail(for: 0)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    chk("可见行缩略图异步生成并缓存",
        v.thumbCache.object(forKey: v.items[0].path as NSString) != nil)
    chk("缩略图生成不创建行子视图", v.listView.subviews.isEmpty)

    fixImage()                 // 等待缩略图期间后台可能换过图，隐藏前再固定一次
    v.setListVisible(false)
    chk("隐藏后图片区恢复占满窗口",
        !v.listVisible && v.scrollView.frame.minX == 0 && v.scrollView.frame.width == W)
    chk("隐藏后适配比例恢复（原 \(fitFull)，现 \(v.fitScale)）", abs(v.fitScale - fitFull) < 1e-6)

    // L 键与菜单
    let keyL = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: 0, windowNumber: 0, context: nil,
                                characters: "l", charactersIgnoringModifiers: "l",
                                isARepeat: false, keyCode: 37)!
    v.keyDown(with: keyL)
    chk("L 键切换列表", v.listVisible)
    v.setListVisible(false)
    let d = AppDelegate(localDir: dir)
    d.buildMainMenu()
    let allItems = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
    chk("「显示」菜单含照片列表 ⌘L",
        allItems.contains { $0.title == "照片列表" && $0.keyEquivalent == "l"
            && $0.keyEquivalentModifierMask.contains(.command) })

    // 渲染带列表的主窗口
    v.setListVisible(true)
    v.layoutSubtreeIfNeeded()
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/rg-main-list.png"))
            chk("带列表主窗口可离屏渲染", true)
        } else { chk("带列表主窗口可离屏渲染", false) }
    } else { chk("带列表主窗口可离屏渲染", false) }

    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}


// 预读配置验收：prefetch（0~10）与 prefetch_video 是否真正接上运行时
if args.contains("--prefetch-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    print("=== 预读配置验收 ===")
    let dir = "/tmp/rg-prefetch-test"
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for n in ["a.jpg", "b.jpg"] {
        let im = NSImage(size: NSSize(width: 40, height: 30))
        im.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 40, height: 30).fill(); im.unlockFocus()
        if let t = im.tiffRepresentation, let r = NSBitmapImageRep(data: t),
           let d = r.representation(using: .jpeg, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: dir + "/" + n))
        }
    }
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: 620, height: 900), localDir: dir)
    func item(_ kind: Kind, _ name: String) -> MediaItem {
        MediaItem(kind: kind, id: "", path: dir + "/" + name, name: name,
                  date: nil, size: 1024, duration: 1)
    }
    v.items = [item(.image, "a.jpg"), item(.video, "v1.mp4"),
               item(.video, "v2.mp4"), item(.image, "b.jpg")]
    v.index = 0

    v.prefetchVideoOverride = false
    v.prefetchRadiusOverride = 2
    v.prefetch()
    chk("prefetch_video=0（当前默认）不排队任何视频预读", v.videoPrefetchInflightForTest() == 0)

    v.prefetchVideoOverride = true
    v.prefetchRadiusOverride = 0
    v.prefetch()
    chk("prefetch=0 时预读窗口只有当前张（radius 生效）", v.videoPrefetchInflightForTest() == 0)

    v.prefetchRadiusOverride = 2
    v.prefetch()
    chk("prefetch=2 + 视频预读开启 → 窗口内 2 个视频入队", v.videoPrefetchInflightForTest() == 2)
    v.prefetch()
    chk("同一视频不重复排队（去重）", v.videoPrefetchInflightForTest() == 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    chk("后台任务收尾后去重集合清空", v.videoPrefetchInflightForTest() == 0)
    chk("本地模式未生成虚假视频缩略图（抽帧失败不写文件）",
        !fm.fileExists(atPath: v.thumbCachePath(v.items[1])))
    try? fm.removeItem(atPath: dir)
    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}


// 查看内容范围验收：配置解析 / 旧键兼容 / 过滤真值表 / 界面写回 / 重启后生效
if args.contains("--filter-test") {
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    print("=== 查看内容范围验收（media_filter）===")
    chk("默认值为 all（图片视频都看）", Config().mediaFilter == .all)
    chk("三年枚举齐全：all / images / videos", MediaFilter.allCases.map { $0.rawValue } == ["all", "images", "videos"])
    chk("解析 images", Config.load(fromText: "media_filter = images").mediaFilter == .images)
    chk("解析 videos", Config.load(fromText: "media_filter = videos").mediaFilter == .videos)
    chk("带行尾注释也正确解析", Config.load(fromText: "media_filter = videos  # 只看视频").mediaFilter == .videos)
    let bad = Config.load(fromText: "media_filter = bogus")
    chk("非法值保持默认 all", bad.mediaFilter == .all)
    chk("非法值有提示", bad.warnings.contains { $0.contains("media_filter") })
    chk("旧键 include_video=0 兼容为只看图片",
        Config.load(fromText: "include_video = 0").mediaFilter == .images)
    chk("旧键 include_video=1 兼容为全部",
        Config.load(fromText: "include_video = 1").mediaFilter == .all)
    chk("media_filter 优先于旧键",
        Config.load(fromText: "include_video = 0\nmedia_filter = all").mediaFilter == .all)
    chk("内置模板默认 all", Config.load(fromText: Config.sample()).mediaFilter == .all)

    let a = MediaItem(kind: .image, id: "", path: "/tmp/a.jpg", name: "a.jpg", date: nil, size: 0, duration: 0)
    let b = MediaItem(kind: .image, id: "", path: "/tmp/b.jpg", name: "b.jpg", date: nil, size: 0, duration: 0)
    let v = MediaItem(kind: .video, id: "", path: "/tmp/v.mp4", name: "v.mp4", date: nil, size: 0, duration: 0)
    let all = [a, v, b]
    chk("all → 3 项（2 图 + 1 视频）", filteredMedia(all, by: .all).count == 3)
    chk("images → 2 项且全是图片",
        filteredMedia(all, by: .images).count == 2 && filteredMedia(all, by: .images).allSatisfy { $0.kind == .image })
    chk("videos → 1 项且是视频",
        filteredMedia(all, by: .videos).count == 1 && filteredMedia(all, by: .videos).first?.kind == .video)
    chk("时间顺序不被过滤打乱",
        filteredMedia(all, by: .all).map { $0.name } == ["a.jpg", "v.mp4", "b.jpg"])

    // 界面写回 → 文本 → 重新解析，等价于保存后重启再读
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let wc = ConfigWindowController()
    chk("设置页查看内容下拉含 3 项", wc.mediaFilterOptionsForTest() == 3)
    wc.setBrowseForTest(5, video: true, filter: .videos)
    wc.syncFromInputs()
    let written = wc.textSnapshot()
    chk("界面选择写入 media_filter = videos", Config.load(fromText: written).mediaFilter == .videos)
    chk("写回保留注释与其它键", written.contains("#") && written.contains("prefetch"))
    chk("重启后读取仍为 videos（模拟：从写回文本重新 load）",
        Config.load(fromText: ConfigFile.update(ConfigFile.read(),
            changes: ["media_filter": "videos"])).mediaFilter == .videos)
    wc.reload()
    chk("reload 后控件回到配置文件的值",
        wc.browseValuesForTest().filter == Config.load().mediaFilter.rawValue)

    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}

// 设置界面自检：配置写回规则 / 菜单 / 窗口控件 / 界面→文本同步 / 离屏渲染
if args.contains("--config-ui-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    setvbuf(stdout, nil, _IONBF, 0)   // 崩溃时也要看到阶段输出
    print("=== 设置界面自检 ===")

    let base = """
    # 头部注释
    prefetch = 5      # 预读张数
    event.wheel = page_or_pan   # 滚轮动作
    event.wheel.enabled = 1
    """
    let u1 = ConfigFile.update(base, changes: ["event.wheel": "zoom_continuous", "prefetch": "9"])
    chk("替换已有键值", u1.contains("event.wheel = zoom_continuous"))
    chk("保留行尾注释", u1.contains("# 滚轮动作"))
    chk("保留头部注释与其它键", u1.contains("# 头部注释") && u1.contains("prefetch = 9"))
    let c1 = Config.load(fromText: u1)
    chk("写回后解析为 zoom_continuous", c1.input.resolvedAction(.wheel) == .zoomContinuous)
    chk("写回后 prefetch=9", c1.prefetch == 9)

    let u2 = ConfigFile.update(base, changes: ["event.alt_wheel": "next"])
    chk("缺失键自动追加", u2.contains("event.alt_wheel = next"))
    chk("追加键可被解析", Config.load(fromText: u2).input.resolvedAction(.altWheel) == .next)

    let u3 = ConfigFile.update("event.wheel = next\nevent.wheel = prev\n",
                               changes: ["event.wheel": "pan"])
    chk("重复键全部改写（不残留旧值）", !u3.contains("= next") && !u3.contains("= prev"))
    chk("重复键全部改写后生效值为 pan",
        Config.load(fromText: u3).input.resolvedAction(.wheel) == .pan)
    chk("重复键仍按 R1 给出提示",
        Config.load(fromText: u3).warnings.contains { $0.contains("重复出现") })

    let cDef = Config.load(fromText: Config.sample())
    for e in InputEvent.allCases {
        chk("默认模板 \(e.rawValue) 与代码默认值一致",
            cDef.input.bindings[e]?.action == InputMap.defaults().bindings[e]?.action)
    }

    let wc = ConfigWindowController()
    let counts = wc.uiCounts()
    chk("设置窗口含 7 个事件行", counts.events == InputEvent.allCases.count)
    chk("每个下拉框含 15 个可选动作", counts.actions == InputAction.allCases.count)
    chk("窗口标题正确", wc.window?.title == "红米相册 · 设置")

    // 列表视图：同一行四元素的垂直中心必须一致，列 x 固定，行距恒定
    let centers = wc.rowCentersForTest()
    chk("列表模式：7 行四元素垂直中心一致（修复偏移）",
        centers.allSatisfy { c in
            max(max(c.0, c.1), max(c.2, c.3)) - min(min(c.0, c.1), min(c.2, c.3)) < 0.6
        })
    let xs = wc.columnXForTest()
    chk("列表模式：7 行四列 x 起点完全一致",
        xs.allSatisfy { x in
            x.0 == xs[0].0 && x.1 == xs[0].1 && x.2 == xs[0].2 && x.3 == xs[0].3
        })
    chk("列表模式：行距均匀 42pt",
        (1..<centers.count).allSatisfy { abs((centers[$0 - 1].2 - centers[$0].2) - 42.0) < 0.6 })
    chk("事件名列加宽到 200pt（长名称不再换行破坏网格）", xs[0].1 - xs[0].0 >= 200)

    // 图片列表视图
    wc.setViewModeForTest(true)
    chk("可切换到图片列表模式", wc.currentModeIsCards())
    let cardInfo = wc.cardsForTest()
    chk("图片列表：7 张卡片 + 7 张示意图且全部可见",
        cardInfo.total == 7 && cardInfo.visible == 7 && cardInfo.icons == 7)
    let cc = wc.rowCentersForTest()
    chk("图片列表：下拉框与勾选框中心一致", cc.allSatisfy { abs($0.2 - $0.3) < 0.6 })
    chk("图片列表：两行文字围绕中心线对称", cc.allSatisfy { abs(($0.0 + $0.1) / 2 - $0.2) < 0.6 })
    chk("切换视图不重建控件（数据与交互保持）", wc.uiCounts().events == 7)
    wc.setViewModeForTest(false)
    chk("切回列表模式仍保持对齐",
        !wc.currentModeIsCards() && wc.rowCentersForTest().allSatisfy { c in
            max(max(c.0, c.1), max(c.2, c.3)) - min(min(c.0, c.1), min(c.2, c.3)) < 0.6
        })

    wc.setForTest(.wheel, action: .zoomInStep, enabled: true)
    wc.syncFromInputs()
    chk("界面改动同步进配置文本",
        Config.load(fromText: wc.textSnapshot()).input.resolvedAction(.wheel) == .zoomInStep)
    wc.setForTest(.altWheel, action: .next, enabled: false)
    wc.syncFromInputs()
    chk("界面禁用状态同步为 none",
        Config.load(fromText: wc.textSnapshot()).input.resolvedAction(.altWheel) == .none)
    chk("同步过程不破坏其它配置项",
        Config.load(fromText: wc.textSnapshot()).prefetch == Config.load().prefetch)

    // 「浏览 / 预读」页：0~10 值域、默认值、写回、跨页同步
    print("  --- 浏览 / 预读页 ---")
    wc.selectPageForTest(1)
    chk("分段控件 3 页：仅浏览页可见",
        wc.pageVisibilityForTest() == (false, true, false))
    let bv0 = wc.browseValuesForTest()
    chk("照片预读下拉含 0~10 共 11 档", bv0.items == 11)
    chk("查看内容下拉含 3 项且默认 all（与配置一致）",
        wc.mediaFilterOptionsForTest() == 3 && bv0.filter == Config.load(fromText: wc.textSnapshot()).mediaFilter.rawValue)
    chk("默认照片预读数与配置文件一致（\(Config.load().prefetch)）",
        bv0.prefetch == Config.load().prefetch)
    chk("默认视频预读关闭（沿用当前行为）", bv0.video == Config.load().prefetchVideo)
    chk("prefetch 解析上限夹到 10", Config.load(fromText: "prefetch = 99").prefetch == 10)
    chk("prefetch 解析下限夹到 0", Config.load(fromText: "prefetch = -3").prefetch == 0)
    chk("prefetch_video=1 生效", Config.load(fromText: "prefetch_video = 1").prefetchVideo)
    chk("缺省 prefetch_video 默认关闭", !Config.load(fromText: "prefetch = 5").prefetchVideo)
    wc.setBrowseForTest(8, video: true)
    wc.syncFromInputs()
    let btext = wc.textSnapshot()
    chk("界面改动写入 prefetch = 8", Config.load(fromText: btext).prefetch == 8)
    chk("界面改动写入 prefetch_video = 1", Config.load(fromText: btext).prefetchVideo)
    chk("界面改动写入 media_filter = all（当前选择）",
        Config.load(fromText: btext).mediaFilter == .all)
    chk("写回保留事件键与注释", btext.contains("event.wheel") && btext.contains("#"))
    wc.selectPageForTest(2)
    chk("原文页含新值且仅原文页可见",
        wc.textSnapshot().contains("prefetch = 8") && wc.pageVisibilityForTest() == (false, false, true))
    wc.selectPageForTest(1)
    chk("切回浏览页控件值保持 8 / 开启",
        wc.browseValuesForTest().prefetch == 8 && wc.browseValuesForTest().video)
    wc.setTextForTest("prefetch = 3\nprefetch_video = 0\n")
    wc.selectPageForTest(2)
    chk("原文页手工改的值不会被未改动控件覆盖",
        Config.load(fromText: wc.textSnapshot()).prefetch == 3)
    wc.selectPageForTest(0)
    chk("回到输入映射页可见性正确", wc.pageVisibilityForTest() == (true, false, false))

    let d = AppDelegate(localDir: "/tmp")
    d.buildMainMenu()
    let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
    chk("菜单含「偏好设置…」", items.contains { $0.title == "偏好设置…" })
    chk("偏好设置快捷键为 ⌘,",
        items.contains { $0.title == "偏好设置…" && $0.keyEquivalent == ","
            && $0.keyEquivalentModifierMask.contains(.command) })
    chk("菜单含「打开配置文件…」", items.contains { $0.title == "打开配置文件…" })
    chk("菜单含「重新载入配置（重启）」", items.contains { $0.title == "重新载入配置（重启）" })
    if let pref = items.first(where: { $0.title == "偏好设置…" }), let act = pref.action {
        _ = NSApp.sendAction(act, to: pref.target, from: pref)
        chk("⌘, 菜单动作确实能打开设置窗口",
            (pref.target as? AppDelegate)?.settings != nil)
    } else {
        chk("⌘, 菜单动作确实能打开设置窗口", false)
    }

    // 渲染前恢复真实配置，保证截图反映的是文件里的默认值而非上面的测试改动
    wc.reload()
    let restored = Config.load(fromText: wc.textSnapshot())
    chk("reload 后控件状态与配置文件一致",
        restored.input.resolvedAction(.wheel) == Config.load().input.resolvedAction(.wheel)
            && restored.input.resolvedAction(.altWheel) == Config.load().input.resolvedAction(.altWheel))

    func renderConfig(_ path: String) -> Bool {
        guard let content = wc.window?.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: URL(fileURLWithPath: path))
        return true
    }
    wc.selectPageForTest(0)
    chk("列表模式可离屏渲染", renderConfig("/tmp/rg-config-ui.png"))
    wc.setViewModeForTest(true)
    chk("图片列表模式可离屏渲染", renderConfig("/tmp/rg-config-cards.png"))
    wc.setViewModeForTest(false)
    wc.selectPageForTest(1)
    chk("浏览 / 预读页可离屏渲染", renderConfig("/tmp/rg-config-browse.png"))
    wc.selectPageForTest(0)

    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}


// 滚轮缩放验收自检（FSViewer 风格）：方向 / 锚点 / 连续平滑 / 上下限 / 无副作用 / 其它交互回归
if args.contains("--wheel-zoom-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let W: CGFloat = 620, H: CGFloat = 900
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: W, height: H), localDir: nil)
    v.inputMapOverride = InputMap.defaults()          // 与用户配置文件解耦
    let img = NSImage(size: NSSize(width: 1000, height: 500))
    img.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 500).fill(); img.unlockFocus()
    v.imageView.image = img
    v.imageView.frame = NSRect(origin: .zero, size: NSSize(width: 1000, height: 500))
    v.layoutSubtreeIfNeeded(); v.layout()
    guard let cv = v.scrollView.contentView as? CenteredClipView else { print("NO_CLIP"); exit(1) }
    let fit = v.fitScale
    v.items = (1...6).map {
        MediaItem(kind: .image, id: "", path: "/tmp/__wz_\($0)__.jpg", name: "w\($0).jpg",
                  date: nil, size: 0, duration: 0)
    }
    v.index = 0

    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    func f3(_ d: Double) -> String { String(format: "%.4f", d) }
    func mag() -> CGFloat { v.scrollView.magnification }
    func docAt(_ p: NSPoint) -> NSPoint { cv.convert(p, from: v) }
    func err(_ a: NSPoint, _ b: NSPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
    func geomOK() -> Bool {
        let b = cv.bounds, f = cv.frame, m = mag()
        guard m.isFinite, m > 0, b.origin.x.isFinite, b.origin.y.isFinite else { return false }
        if abs(b.size.width - f.size.width / m) > 0.5 ||
           abs(b.size.height - f.size.height / m) > 0.5 { return false }
        let t = cv.constrainedOrigin(b.origin, boundsSize: b.size)
        return abs(t.x - b.origin.x) < 0.02 && abs(t.y - b.origin.y) < 0.02
    }
    func wheel(_ dy: Int32, flags: NSEvent.ModifierFlags = [], at pt: CGPoint? = nil,
               pixel: Bool = false) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: pixel ? .pixel : .line,
                         wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        var f = CGEventFlags()
        if flags.contains(.shift) { f.insert(.maskShift) }
        if flags.contains(.control) { f.insert(.maskControl) }
        if flags.contains(.option) { f.insert(.maskAlternate) }
        if flags.contains(.command) { f.insert(.maskCommand) }
        cg.flags = f
        cg.location = pt ?? CGPoint(x: 310, y: 450)
        return NSEvent(cgEvent: cg)!
    }
    func reset(_ m: Double? = nil) {
        v.scrollView.magnification = CGFloat(m ?? fit)
        v.recenter(); v.wheelAccum = 0; v.index = 0
    }
    /// 按 wheelZoom 的公式预测目标倍率，再验证「锚点不变量」或「撞边界只被夹住」
    func checkWheel(_ label: String, dy: Int32, at loc: CGPoint, pixel: Bool = false) {
        let ev = wheel(dy, at: loc, pixel: pixel)
        let p = v.convert(ev.locationInWindow, from: nil)
        let d = docAt(p), o0 = cv.bounds.origin, old = mag()
        let raw = abs(ev.deltaY) >= abs(ev.deltaX) ? ev.deltaY : ev.deltaX
        let step = max(-24, min(24, raw))
        let cm = CGFloat(min(max(Double(old) * exp(Double(step) * cfg.wheelZoomSensitivity),
                                 cfg.zoomMin), cfg.zoomMax))
        let k = old / cm
        let desired = NSPoint(x: d.x - (d.x - o0.x) * k, y: d.y - (d.y - o0.y) * k)
        let bs = NSSize(width: cv.frame.width / cm, height: cv.frame.height / cm)
        let predicted = cv.constrainedOrigin(desired, boundsSize: bs)
        let clamped = abs(predicted.x - desired.x) > 0.02 || abs(predicted.y - desired.y) > 0.02
        v.scrollWheel(with: ev)
        if clamped {
            chk("\(label) 撞边界：origin 精确等于约束值（无额外漂移）",
                abs(cv.bounds.origin.x - predicted.x) < 0.02 &&
                abs(cv.bounds.origin.y - predicted.y) < 0.02)
        } else {
            let e = err(d, docAt(p))
            chk("\(label) 锚点保持，误差 \(f3(e)) < 0.5", e < 0.5)
        }
        chk("\(label) 几何合法（无越界 / NaN / 跳变）", geomOK())
    }

    print("=== 滚轮缩放验收（1000x500 图 / 620x900 窗口）===")
    print("适配比例 fit = \(f3(fit))，上下限 = \(cfg.zoomMin)…\(cfg.zoomMax)，灵敏度 = \(cfg.wheelZoomSensitivity)")

    // 【1】方向：向上放大、向下缩小，与当前是否放大无关
    print("【1】方向")
    reset(); let up0 = mag()
    v.scrollWheel(with: wheel(12))
    chk("滚轮向上 → 放大（\(f3(Double(up0))) → \(f3(Double(mag())))）", mag() > up0)
    chk("向上滚不切换照片", v.index == 0)
    reset(); let dn0 = mag()
    v.scrollWheel(with: wheel(-12))
    chk("滚轮向下 → 缩小（\(f3(Double(dn0))) → \(f3(Double(mag())))）", mag() < dn0)
    chk("向下滚不切换照片", v.index == 0)
    chk("缩放清空翻页累积位移（不会误触发翻页）", v.wheelAccum == 0)
    reset(); v.scrollWheel(with: wheel(12)); v.scrollWheel(with: wheel(-12))
    chk("一上一下往返倍率精确回到起点", abs(Double(mag()) - fit) < 1e-6)
    reset(4.0); let big0 = mag()
    v.scrollWheel(with: wheel(-12))
    chk("已放大状态下向下滚仍然缩小", mag() < big0)
    reset(0.3); let small0 = mag()
    v.scrollWheel(with: wheel(12))
    chk("已缩小状态下向上滚仍然放大", mag() > small0)

    // 【2】指针锚点：9 个位置 × 放大 / 缩小
    print("【2】指针锚点（中心 / 1/4 / 四角 / 边缘 / 图片外）")
    let locs: [(String, CGPoint)] = [
        ("中心", CGPoint(x: 310, y: 450)), ("1/4 点", CGPoint(x: 155, y: 225)),
        ("左上角", CGPoint(x: 2, y: 898)), ("右上角", CGPoint(x: 618, y: 898)),
        ("左下角", CGPoint(x: 2, y: 2)), ("右下角", CGPoint(x: 618, y: 2)),
        ("距边 2px", CGPoint(x: 2, y: 450)), ("图片上方黑边", CGPoint(x: 310, y: 880)),
        ("容器外", CGPoint(x: -60, y: 450)),
    ]
    for (name, loc) in locs {
        reset(2.0); checkWheel("向上-\(name)", dy: 12, at: loc)
        reset(2.0); checkWheel("向下-\(name)", dy: -12, at: loc)
    }

    // 【3】连续滚动：单调、每步比例恒定、锚点累计不漂移
    print("【3】连续滚动平滑性")
    reset(2.0)
    let pMid = CGPoint(x: 310, y: 450)
    let anchor0 = docAt(v.convert(wheel(3, at: pMid).locationInWindow, from: nil))
    var ratios: [Double] = [], monotonic = true, prev = Double(mag())
    for _ in 0..<20 {
        v.scrollWheel(with: wheel(3, at: pMid))
        let m = Double(mag())
        ratios.append(m / prev)
        if m <= prev { monotonic = false }
        prev = m
    }
    chk("连续 20 次小滚动倍率单调上升", monotonic)
    chk("每步比例恒定（无跳变，最大偏差 < 0.001）",
        ratios.allSatisfy { abs($0 - ratios[0]) < 0.001 })
    chk("连续滚动后锚点累计误差 \(f3(err(anchor0, docAt(v.convert(wheel(3, at: pMid).locationInWindow, from: nil))))) < 0.5",
        err(anchor0, docAt(v.convert(wheel(3, at: pMid).locationInWindow, from: nil))) < 0.5)
    chk("连续滚动始终不切换照片", v.index == 0)

    // 【4】触控板精确滚动归一化 / 单次限幅 / 死区
    print("【4】触控板归一化与限幅")
    let evPixel = wheel(120, at: pMid, pixel: true)
    chk("像素单位事件被识别为 precise scrolling", evPixel.hasPreciseScrollingDeltas)
    reset(1.0); let px0 = Double(mag())
    v.scrollWheel(with: evPixel)
    let pxRatio = Double(mag()) / px0
    chk("触控板 120px 单次缩放幅度与普通滚轮同量级（1.05 < \(f3(pxRatio)) < 1.3）",
        pxRatio < 1.3 && pxRatio > 1.05)
    reset(1.0)
    v.scrollWheel(with: wheel(100000, at: pMid))
    chk("单次超大滚动被限幅（≤ exp(24×灵敏度)）",
        Double(mag()) <= exp(24 * cfg.wheelZoomSensitivity) * 1.001)
    reset(1.0); let zero0 = mag()
    v.scrollWheel(with: wheel(0, at: pMid))
    chk("零位移不改变倍率（死区）", mag() == zero0)

    // 【5】缩放上下限：到达后倍率与 origin 都不再抖动
    print("【5】缩放上下限")
    reset(1.0)
    for _ in 0..<100 { v.scrollWheel(with: wheel(24, at: pMid)) }
    chk("连续放大夹到 zoom_max = \(cfg.zoomMax)", abs(Double(mag()) - cfg.zoomMax) < 1e-6)
    let oMax = cv.bounds.origin
    for _ in 0..<10 { v.scrollWheel(with: wheel(24, at: pMid)) }
    chk("到上限后倍率保持不变", abs(Double(mag()) - cfg.zoomMax) < 1e-6)
    chk("到上限后 origin 完全不抖动",
        abs(cv.bounds.origin.x - oMax.x) < 0.001 && abs(cv.bounds.origin.y - oMax.y) < 0.001)
    for _ in 0..<200 { v.scrollWheel(with: wheel(-24, at: pMid)) }
    chk("连续缩小夹到 zoom_min = \(cfg.zoomMin)", abs(Double(mag()) - cfg.zoomMin) < 1e-6)
    let oMin = cv.bounds.origin
    for _ in 0..<10 { v.scrollWheel(with: wheel(-24, at: pMid)) }
    chk("到下限后倍率保持不变", abs(Double(mag()) - cfg.zoomMin) < 1e-6)
    chk("到下限后 origin 完全不抖动",
        abs(cv.bounds.origin.x - oMin.x) < 0.001 && abs(cv.bounds.origin.y - oMin.y) < 0.001)
    chk("到达上下限过程中几何始终合法", geomOK())

    // 【6】其它交互不变
    print("【6】其它交互回归")
    reset(); v.index = 2
    v.scrollWheel(with: wheel(12, at: pMid))
    chk("滚轮缩放不切换照片（index 保持 2）", v.index == 2)
    chk("滚轮缩放不产生页面滚动（wheelAccum=0）", v.wheelAccum == 0)
    reset(); v.index = 1
    v.scrollWheel(with: wheel(12, flags: [.shift], at: pMid))
    chk("Shift+滚轮仍翻页（其它交互不变）", v.index == 0)
    reset(); v.index = 1
    v.scrollWheel(with: wheel(-12, flags: [.option], at: pMid))
    chk("Alt+滚轮仍翻页（其它交互不变）", v.index == 2)
    reset(); let ctrl0 = mag()
    v.scrollWheel(with: wheel(12, flags: [.control], at: pMid))
    chk("Ctrl+滚轮仍缩放（其它交互不变）", mag() > ctrl0)
    func dbl(_ n: Int) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 310, y: 450),
                           modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: n, clickCount: 2, pressure: 0)!
    }
    reset(); v.dblArmed = false
    v.mouseUp(with: dbl(1))
    chk("双击仍到 100%", abs(Double(mag()) - 1.0) < 1e-6)
    v.mouseUp(with: dbl(2))
    chk("连续第二次双击仍回全图", abs(Double(mag()) - fit) < 1e-6)
    v.rightMouseUp(with: NSEvent.mouseEvent(with: .rightMouseUp, location: NSPoint(x: 310, y: 450),
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 3, clickCount: 1, pressure: 0)!)
    chk("右击仍回全图", abs(Double(mag()) - fit) < 1e-6)
    reset(); v.zoomIn(anchor: nil)
    chk("+ 键放大仍有效", mag() > CGFloat(fit))
    v.resetZoom()
    chk("0 键仍复原", abs(Double(mag()) - fit) < 1e-6)

    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}

// 输入映射清单与规则自检：输出完整清单 + 验证冲突/重复/降级/真实事件
if args.contains("--input-map") {
    let conf = Config.load()
    let defs = InputMap.defaults()
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }

    print("=== 一、事件—动作映射清单（当前生效）===")
    for e in InputEvent.allCases {
        let b = conf.input.bindings[e] ?? InputBinding(action: .none)
        let a = conf.input.resolvedAction(e)
        print("event.\(e.rawValue)  【\(e.label)】")
        print("   触发条件 : \(e.condition)")
        print("   配置动作 : \(b.action.rawValue)（\(b.action.label)）   启用: \(b.enabled ? "是" : "否")")
        print("   生效动作 : \(a.rawValue)（\(a.label)）")
        print("   预期结果 : \(a.expected)")
    }

    print("=== 二、配置项定义（默认值 / 可选范围 / 启用状态）===")
    print("每个事件 2 个键：event.<key> = <动作>  /  event.<key>.enabled = 0|1")
    print("动作可选范围（\(InputAction.allCases.count) 个）：\(InputAction.allCases.map { $0.rawValue }.joined(separator: ", "))")
    for e in InputEvent.allCases {
        let d = defs.bindings[e]!
        print("  event.\(e.rawValue) = \(d.action.rawValue)（默认）   event.\(e.rawValue).enabled = \(d.enabled ? 1 : 0)（默认）")
    }
    print("  全局参数: wheel_cmd_as_ctrl=1  wheel_page_threshold=8  wheel_zoom_sensitivity=0.01")

    print("=== 三、可选动作定义 ===")
    for a in InputAction.allCases {
        print("  \(a.rawValue) — \(a.label)")
        print("      需要滚轮位移: \(a.needsDelta ? "是" : "否") | 用于指针事件时降级为: \(a.pointerFallback?.rawValue ?? "原样")")
        print("      预期结果: \(a.expected)")
    }

    print("=== 四、冲突 / 重复映射处理规则（含实测）===")
    print("  R1 同一配置键重复出现 → 最后一次生效 + 提示")
    print("  R2 动作值非法 / 事件名未知 → 保持默认(或忽略) + 提示")
    print("  R3 事件 enabled=0 → 完全不响应，且不回落到其它事件")
    print("  R4 修饰键精确匹配优先；组合键取最具体子集，平局 ctrl > alt > shift > 无")
    print("  R5 ⌘ 默认归一为 Ctrl；关闭归一后 ⌘ 不映射任何事件")
    print("  R6 需要滚轮位移的动作配到指针事件 → 按降级表转换")
    print("  R7 多个事件映射同一动作 → 允许（有意冗余），仅汇总提示")
    print("  R8 wheel_zoom=0（旧开关）→ 强制禁用 event.ctrl_wheel")

    let c1 = Config.load(fromText: "event.wheel = next\nevent.wheel = prev\n")
    chk("R1 重复定义最后一次生效", c1.input.resolvedAction(.wheel) == .prev)
    chk("R1 重复定义有提示", c1.warnings.contains { $0.contains("重复出现") })

    let c2 = Config.load(fromText: "event.wheel = bogus_action\nevent.no_such_event = next\n")
    chk("R2 非法动作保持默认", c2.input.resolvedAction(.wheel) == defs.resolvedAction(.wheel))
    chk("R2 非法动作 / 未知事件均有提示",
        c2.warnings.contains { $0.contains("bogus_action") } && c2.warnings.contains { $0.contains("未知事件") })

    let c3 = Config.load(fromText: "event.shift_wheel.enabled = 0\n")
    chk("R3 禁用事件动作 = none", c3.input.resolvedAction(.shiftWheel) == .none)
    chk("R3 Shift+滚轮 命中禁用项后不回落", c3.input.wheelEvent(for: [.shift], cmdAsCtrl: true) == nil)

    chk("R4 无修饰 → wheel", defs.wheelEvent(for: [], cmdAsCtrl: true) == .wheel)
    chk("R4 shift → shift_wheel", defs.wheelEvent(for: [.shift], cmdAsCtrl: true) == .shiftWheel)
    chk("R4 control → ctrl_wheel", defs.wheelEvent(for: [.control], cmdAsCtrl: true) == .ctrlWheel)
    chk("R4 option → alt_wheel", defs.wheelEvent(for: [.option], cmdAsCtrl: true) == .altWheel)
    chk("R4 ctrl+shift → ctrl_wheel（最具体）",
        defs.wheelEvent(for: [.control, .shift], cmdAsCtrl: true) == .ctrlWheel)
    chk("R4 alt+shift → alt_wheel（平局顺序）",
        defs.wheelEvent(for: [.option, .shift], cmdAsCtrl: true) == .altWheel)
    chk("R5 ⌘ 归一 → ctrl_wheel", defs.wheelEvent(for: [.command], cmdAsCtrl: true) == .ctrlWheel)
    chk("R5 ⌘ 未归一 → 不映射", defs.wheelEvent(for: [.command], cmdAsCtrl: false) == nil)

    let c6 = Config.load(fromText: "event.double_click = page\nevent.right_click = zoom_continuous\nevent.wheel = zoom_in_step\n")
    chk("R6 指针事件配 page → next", c6.input.resolvedAction(.doubleClick) == .next)
    chk("R6 指针事件配 zoom_continuous → zoom_in_step", c6.input.resolvedAction(.rightClick) == .zoomInStep)
    chk("R6 滚轮事件配 zoom_in_step 不降级", c6.input.resolvedAction(.wheel) == .zoomInStep)

    let c7 = Config.load(fromText: "event.right_click = zoom_fit\nevent.double_click_again = zoom_fit\n")
    chk("R7 重复映射两者都生效",
        c7.input.resolvedAction(.rightClick) == .zoomFit && c7.input.resolvedAction(.doubleClickAgain) == .zoomFit)
    chk("R7 重复映射有汇总提示", c7.warnings.contains { $0.contains("共用") })
    let c8 = Config.load(fromText: "wheel_zoom = 0\n")
    chk("R8 wheel_zoom=0 强制禁用 ctrl_wheel", c8.input.resolvedAction(.ctrlWheel) == .none)

    print("=== 五、真实事件模拟（默认配置）===")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let W: CGFloat = 620, H: CGFloat = 900
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: W, height: H), localDir: nil)
    v.inputMapOverride = defs          // 事件模拟固定用默认映射，不受用户配置影响
    let img = NSImage(size: NSSize(width: 1000, height: 500))
    img.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 500).fill(); img.unlockFocus()
    v.imageView.image = img
    v.imageView.frame = NSRect(origin: .zero, size: NSSize(width: 1000, height: 500))
    v.layoutSubtreeIfNeeded(); v.layout()
    let fit = v.fitScale
    v.items = (1...5).map {
        MediaItem(kind: .image, id: "", path: "/tmp/__im_\($0)__.jpg", name: "i\($0).jpg",
                  date: nil, size: 0, duration: 0)
    }
    v.index = 0
    func resetFit() {
        v.scrollView.magnification = CGFloat(fit)
        v.recenter(); v.wheelAccum = 0; v.dblArmed = false
    }
    func mouseEv(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 310, y: 450), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 1, clickCount: clicks, pressure: 0)!
    }
    func wheelEv(_ flags: NSEvent.ModifierFlags, _ dy: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                         wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
        var cf = CGEventFlags()
        if flags.contains(.shift) { cf.insert(.maskShift) }
        if flags.contains(.control) { cf.insert(.maskControl) }
        if flags.contains(.option) { cf.insert(.maskAlternate) }
        if flags.contains(.command) { cf.insert(.maskCommand) }
        cg.flags = cf
        cg.location = CGPoint(x: 248, y: 540)
        return NSEvent(cgEvent: cg)!
    }
    func magNow() -> Double { Double(v.scrollView.magnification) }

    resetFit()
    v.mouseUp(with: mouseEv(.leftMouseUp, 2))
    chk("双击#1 → 100%（mag=1.0，实测 \(String(format: "%.3f", magNow()))）", abs(magNow() - 1.0) < 1e-6)
    v.mouseUp(with: mouseEv(.leftMouseUp, 2))
    chk("双击#2（连续第二次）→ 全图（mag=fit）", abs(magNow() - fit) < 1e-6)
    v.mouseUp(with: mouseEv(.leftMouseUp, 2))
    chk("双击#3 交替回 100%", abs(magNow() - 1.0) < 1e-6)
    v.rightMouseUp(with: mouseEv(.rightMouseUp, 1))
    chk("右击 → 全图", abs(magNow() - fit) < 1e-6)

    resetFit(); v.index = 0
    let wUp0 = magNow()
    v.scrollWheel(with: wheelEv([], 12))
    chk("滚轮（无修饰）向上 → 放大（\(String(format: "%.3f", wUp0)) → \(String(format: "%.3f", magNow()))）", magNow() > wUp0)
    chk("滚轮缩放不切换照片", v.index == 0)
    resetFit(); v.index = 0
    let wDn0 = magNow()
    v.scrollWheel(with: wheelEv([], -12))
    chk("滚轮（无修饰）向下 → 缩小", magNow() < wDn0)
    chk("向下滚也不切换照片", v.index == 0)
    resetFit(); v.index = 1
    v.scrollWheel(with: wheelEv([.shift], 12))
    chk("Shift+滚轮 → 上一张（其它交互不变）", v.index == 0)
    resetFit(); v.index = 1
    v.scrollWheel(with: wheelEv([.option], -12))
    chk("Alt+滚轮 → 下一张（其它交互不变）", v.index == 2)
    resetFit()
    let before = magNow()
    v.scrollWheel(with: wheelEv([.control], 12))
    chk("Ctrl+滚轮 → 放大（\(String(format: "%.3f", before)) → \(String(format: "%.3f", magNow()))）", magNow() > before)
    resetFit()
    let before2 = magNow()
    v.scrollWheel(with: wheelEv([.control, .shift], 12))
    chk("Ctrl+Shift 不串到 shift_wheel，仍走缩放", magNow() > before2)

    print("=== 结果 \(pass)/\(total) 通过 ===")
    if !conf.warnings.isEmpty {
        print("当前配置校验提示：")
        for w in conf.warnings { print("  - \(w)") }
    }
    exit(pass == total ? 0 : 1)
}

if args.contains("--print-config") {
    print(Config.sample())
    print("当前生效：prefetch=\(cfg.prefetch)  max_concurrent_pull=\(cfg.maxConcurrentPull)  " +
          "delete_confirm=\(cfg.deleteConfirm)  delete_success_hint=\(cfg.deleteSuccessHint)  " +
          "backup_video=\(cfg.backupVideo)  include_video=\(cfg.includeVideo)  " +
          "media_filter=\(cfg.mediaFilter.rawValue)(\(cfg.mediaFilter.label))  " +
          "video_thumb=\(cfg.videoThumb)  autoplay_video=\(cfg.autoplayVideo)  " +
          "prefetch_video=\(cfg.prefetchVideo)  zoom_min=\(cfg.zoomMin)  zoom_max=\(cfg.zoomMax)  " +
          "cache_video=\(cfg.cacheVideo)  cache_max_mb=\(cfg.cacheMaxMB)")
    if !cfg.warnings.isEmpty {
        print("配置校验提示（冲突 / 重复 / 降级）：")
        for w in cfg.warnings { print("  - \(w)") }
    }
    exit(0)
}

if args.contains("--dump") {
    guard let s = Adb.findDevice() else { print("NO_DEVICE"); exit(1) }
    Adb.serial = s
    print("device=\(s)")
    let items = loadPhotosFromDevice()
    let imgs = items.filter { $0.kind == .image }.count
    print("count=\(items.count)   图片=\(imgs)   视频=\(items.count - imgs)")
    for it in items.prefix(5) { print("\((it.kind == .video) ? "V" : "I") \(it.id)\t\(it.path)") }
    exit(0)
}

// 翻页性能自检：--navtest N（等每张加载完） / --navfast N（每 120ms 强制翻一张，模拟长按方向键）
for (flag, waitEach) in [("--navtest", true), ("--navfast", false)] {
    if let i = args.firstIndex(of: flag), i + 1 < args.count {
        let steps = Int(args[i + 1]) ?? 30
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let v = GalleryView(frame: NSRect(x: 0, y: 0, width: 620, height: 1080), localDir: localDir)
        if localDir == nil {
            guard let s = Adb.findDevice() else { print("NO_DEVICE"); exit(1) }
            Adb.serial = s
            v.items = loadPhotosFromDevice()
        }
        guard !v.items.isEmpty else { print("没有可翻的媒体"); exit(1) }
        print("共 \(v.items.count) 项，开始翻 \(steps) 次（\(waitEach ? "逐张等待" : "模拟长按 120ms/张")）")

        var rows: [(Int, String, Double, Double, Double, Double, Int, Bool)] = []
        for s in 0..<min(steps, v.items.count) {
            let n0 = v.applyCount
            let t0 = Date()
            v.show(s)
            if waitEach {
                let deadline = Date().addingTimeInterval(30)
                while v.applyCount == n0 && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                }
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            }
            let total = Date().timeIntervalSince(t0) * 1000
            let key = v.items[s].path
            rows.append((s + 1, v.items[s].name, total, v.navStats.get(.wait, path: key),
                         v.navStats.get(.pull, path: key), v.navStats.get(.decode, path: key),
                         v.navStats.lastBytes, v.lastInstant))
        }
        print(String(format: "%-5@ %-24@ %8@ %8@ %8@ %8@ %9@ %@",
                     "序号", "文件", "总计ms", "排队ms", "拉取ms", "解码ms", "字节", "缓存命中"))
        for r in rows {
            let nm = String((r.1 as NSString).lastPathComponent.prefix(22))
            print(String(format: "%-5d %-24@", r.0, nm),
                  String(format: "%8.0f %8.0f %8.0f %8.0f %9d %@",
                         r.2, r.3, r.4, r.5, r.6, r.7 ? "是" : "否"))
        }
        let hit = rows.filter { $0.7 }.count
        let ts = rows.map { $0.2 }.sorted()
        let avg = ts.reduce(0, +) / Double(max(1, ts.count))
        let p95 = ts.isEmpty ? 0 : ts[min(ts.count - 1, Int(Double(ts.count) * 0.95))]
        print(String(format: "缓存命中 %d/%d   平均 %.0fms   中位 %.0fms   p95 %.0fms   最慢 %.0fms   超过300ms的 %d 次",
                     hit, rows.count, avg, ts[ts.count / 2], p95, ts.last ?? 0,
                     rows.filter { $0.2 > 300 }.count))
        exit(0)
    }
}

// 真实备份链路自检：备份只写 /tmp，删除仍用模拟器，全程不碰手机、不写用户回收站
if args.contains("--backup-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let dir = "/tmp/deluxbak"
    let out = "/tmp/rg-backup-selftest"
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try? fm.removeItem(atPath: out)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for k in 1...3 {
        let img = NSImage(size: NSSize(width: 120, height: 180))
        img.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 180).fill()
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let d = rep.representation(using: .jpeg, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/q\(k).jpg"))
        }
    }
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: 620, height: 900), localDir: dir)
    v.backupDirOverride = out
    v.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let dayDir = out + "/" + df.string(from: Date())
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    print("=== 真实备份链路自检（备份写 /tmp，不碰手机）===")

    let okReal = v.backupForDelete(v.items[0])
    let fake = MediaItem(kind: .image, id: "", path: dir + "/__no_such__.jpg",
                         name: "__no_such__.jpg", date: nil, size: 0, duration: 0)
    let okFake = v.backupForDelete(fake)
    let files = (try? fm.contentsOfDirectory(atPath: dayDir)) ?? []
    let sizes = files.compactMap { (try? Data(contentsOf: URL(fileURLWithPath: dayDir + "/" + $0)))?.count }
    chk("存在的照片备份成功", okReal)
    chk("不存在的照片备份失败（不会误判）", !okFake)
    chk("备份目录只生成 1 个文件：\(files)", files.count == 1)
    chk("备份文件非空：\(sizes) 字节", sizes.first ?? 0 > 0)

    // 端到端顺序：真实 backupForDelete + 模拟删除，确认备份成功后才会调用删除
    let trace = DeleteTrace()
    v.deleteSimulator = { _ in trace.add("delete"); return true }
    let n = v.items.count
    v.requestDelete(); v.requestDelete()
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    chk("真实备份成功后才调用删除：\(trace.events())", trace.events() == ["delete"])
    chk("列表 \(n)→\(v.items.count)", v.items.count == n - 1)
    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}

// 删除交互自检：backupSimulator / deleteSimulator 分别接管两步，绝不碰手机文件
if args.contains("--delete-ux-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let dir = "/tmp/delux"
    let fm = FileManager.default
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for k in 1...7 {
        let img = NSImage(size: NSSize(width: 160, height: 240))
        img.lockFocus()
        NSColor(calibratedHue: CGFloat(k) / 9, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 160, height: 240).fill()
        img.unlockFocus()
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let d = rep.representation(using: .jpeg, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: "\(dir)/p\(k).jpg"))
        }
    }
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: 620, height: 900), localDir: dir)
    v.start()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let trace = DeleteTrace()
    let n0 = v.items.count
    let firstName = v.items[0].name
    let secondName = v.items[1].name
    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    print("=== 删除交互自检（备份优先，模拟两步，全程不碰手机文件）===")
    print("初始 \(n0) 张：\(firstName) → \(secondName) → …")

    // 场景 1：成功。后台故意慢 0.8 秒，第二次按下必须立刻切界面；顺序必须是 backup→delete
    trace.reset()
    v.backupSimulator = { _ in trace.add("backup"); Thread.sleep(forTimeInterval: 0.8); return true }
    v.deleteSimulator = { _ in trace.add("delete"); return true }
    let t0 = Date()
    v.requestDelete(); v.requestDelete()
    let dt = Date().timeIntervalSince(t0) * 1000
    let n1 = v.items.count
    let cur1 = v.items[v.index].name
    print("场景1 备份成功 → 删除成功（后台慢 0.8s）")
    chk(String(format: "第二次按下耗时 %.0fms（应 <100ms）", dt), dt < 100)
    chk("列表立即 \(n0)→\(n1)", n1 == n0 - 1)
    chk("当前立即变成下一张 \(cur1)（期望 \(secondName)）", cur1 == secondName)
    chk("黄色确认提示已收起", !v.hintLabel.stringValue.contains("再按一次"))
    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
    chk("后台调用顺序 backup→delete：\(trace.events())", trace.events() == ["backup", "delete"])
    chk("后台完成后列表稳定在 \(n1)", v.items.count == n1)
    chk("成功默认静默（无失败字样）", !v.hintLabel.stringValue.contains("失败"))

    // 场景 2（核心）：备份失败 → 删除函数根本不许被调用，整单撤回
    trace.reset()
    v.backupSimulator = { _ in trace.add("backup"); Thread.sleep(forTimeInterval: 0.25); return false }
    v.deleteSimulator = { _ in trace.add("delete"); return true }
    let n2 = v.items.count
    let target2 = v.items[v.index].name
    v.requestDelete(); v.requestDelete()
    chk("备份失败时列表也是立即 \(n2)→\(v.items.count)", v.items.count == n2 - 1)
    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
    print("场景2 备份失败（删除函数不应被调用）")
    chk("删除函数完全没被调用：\(trace.events())", trace.events() == ["backup"])
    chk("列表恢复为 \(n2)", v.items.count == n2)
    chk("\(target2) 已放回", v.items.contains { $0.name == target2 })
    chk("提示含「备份失败」", v.hintLabel.stringValue.contains("备份失败"))
    chk("提示含「未删除」：\(v.hintLabel.stringValue)", v.hintLabel.stringValue.contains("未删除"))
    chk("提示说明手机上文件没动", v.hintLabel.stringValue.contains("没动"))

    // 场景 3：备份成功、删除失败 → 撤回，并说明备份已保存
    trace.reset()
    v.backupSimulator = { _ in trace.add("backup"); return true }
    v.deleteSimulator = { _ in trace.add("delete"); return false }
    let n3 = v.items.count
    let target3 = v.items[v.index].name
    v.requestDelete(); v.requestDelete()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    print("场景3 备份成功 → 删除失败")
    chk("顺序仍是 backup→delete：\(trace.events())", trace.events() == ["backup", "delete"])
    chk("列表恢复为 \(n3)", v.items.count == n3)
    chk("\(target3) 已放回", v.items.contains { $0.name == target3 })
    chk("提示含「删除失败」", v.hintLabel.stringValue.contains("删除失败"))
    chk("提示说明备份已保存", v.hintLabel.stringValue.contains("备份已保存"))

    // 场景 4：连着删两张，两次都必须是先备份后删除
    trace.reset()
    v.backupSimulator = { _ in trace.add("b"); return true }
    v.deleteSimulator = { _ in trace.add("d"); return true }
    let n4 = v.items.count
    v.requestDelete(); v.requestDelete()
    v.requestDelete(); v.requestDelete()
    chk("连删两张立即 \(n4)→\(v.items.count)", v.items.count == n4 - 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    chk("两次都是先备份后删除：\(trace.events())", trace.events() == ["b", "d", "b", "d"])
    chk("后台跑完仍是 \(n4 - 2)", v.items.count == n4 - 2)

    // 场景 5：删到最后一张不崩
    while v.items.count > 1 { v.requestDelete(); v.requestDelete() }
    v.requestDelete(); v.requestDelete()
    chk("删完最后一张列表为空", v.items.isEmpty)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    chk("空列表标题正确：\(v.titleLabel.stringValue)", v.titleLabel.stringValue.contains("已看完"))

    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}

// 缩放几何探针：打印不同 magnification 下 AppKit 实际的 bounds/frame/vis 关系
if args.contains("--zoom-probe") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let W: CGFloat = 620, H: CGFloat = 900
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: W, height: H), localDir: nil)
    let img = NSImage(size: NSSize(width: 1000, height: 500))
    img.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 500).fill(); img.unlockFocus()
    v.imageView.image = img
    v.imageView.frame = NSRect(origin: .zero, size: NSSize(width: 1000, height: 500))
    v.layoutSubtreeIfNeeded(); v.layout()
    let cv = v.scrollView.contentView
    func dump(_ tag: String, _ m: CGFloat? = nil) {
        if let m { v.scrollView.magnification = m }
        let b = cv.bounds, f = cv.frame, d = v.imageView.frame, vis = cv.documentVisibleRect
        let p = cv.convert(NSPoint(x: 300, y: 400), from: nil)
        print(String(format: "%@ mag=%.3f | bounds=(%.1f,%.1f %.1fx%.1f) frame=(%.1f,%.1f %.1fx%.1f) doc=(%.1f,%.1f %.1fx%.1f) vis=(%.1f,%.1f %.1fx%.1f) conv=(%.1f,%.1f)",
                     tag, v.scrollView.magnification,
                     b.origin.x, b.origin.y, b.size.width, b.size.height,
                     f.origin.x, f.origin.y, f.size.width, f.size.height,
                     d.origin.x, d.origin.y, d.size.width, d.size.height,
                     vis.origin.x, vis.origin.y, vis.size.width, vis.size.height,
                     p.x, p.y))
    }
    dump("fit")
    dump("m=1.0", 1.0)
    dump("m=2.0", 2.0)
    dump("m=0.4", 0.4)
    exit(0)
}

// 缩放验收自检：锚点不变量 / 连续放大 / 滚轮双向 / 边缘四角 / 上下限 / 现有交互回归
if args.contains("--zoom-test") {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let W: CGFloat = 620, H: CGFloat = 900
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: W, height: H), localDir: nil)
    v.inputMapOverride = InputMap.defaults()   // 与用户配置文件解耦
    func solid(_ w: CGFloat, _ h: CGFloat) -> NSImage {
        let im = NSImage(size: NSSize(width: w, height: h))
        im.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); im.unlockFocus()
        return im
    }
    let img = solid(1000, 500)
    v.imageView.image = img
    v.imageView.frame = NSRect(origin: .zero, size: NSSize(width: 1000, height: 500))
    v.layoutSubtreeIfNeeded(); v.layout()
    guard let cv = v.scrollView.contentView as? CenteredClipView else { print("NO_CLIP"); exit(1) }

    var pass = 0, total = 0
    func chk(_ label: String, _ ok: Bool) {
        total += 1; if ok { pass += 1 }
        print("  \(ok ? "通过" : "失败")  \(label)")
    }
    func f3(_ d: Double) -> String { String(format: "%.3f", d) }
    func mag() -> CGFloat { v.scrollView.magnification }
    func docAt(_ p: NSPoint) -> NSPoint { cv.convert(p, from: v) }   // 指针下的文档坐标
    func err(_ a: NSPoint, _ b: NSPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
    func reset(_ m: Double) { v.scrollView.magnification = CGFloat(m); v.recenter() }

    func geomOK() -> Bool {
        let b = cv.bounds, f = cv.frame, m = mag()
        guard m.isFinite, m > 0, b.origin.x.isFinite, b.origin.y.isFinite,
              b.size.width.isFinite, b.size.height.isFinite else { return false }
        if abs(b.size.width - f.size.width / m) > 0.5 ||
           abs(b.size.height - f.size.height / m) > 0.5 { return false }
        let t = cv.constrainedOrigin(b.origin, boundsSize: b.size)
        if abs(t.x - b.origin.x) > 0.02 || abs(t.y - b.origin.y) > 0.02 { return false }
        let vis = cv.documentVisibleRect
        return abs(vis.origin.x - b.origin.x) < 0.02 && abs(vis.origin.y - b.origin.y) < 0.02
    }

    /// 一次缩放的完整断言：未撞到边界时锚点必须精确保持；撞到边界时 origin 必须
    /// 等于约束预测值（证明只被夹住、没有额外漂移），且几何始终合法。
    func checkAnchored(_ label: String, _ p: NSPoint, _ target: Double, _ action: () -> Void) {
        let cm = CGFloat(min(max(target, cfg.zoomMin), cfg.zoomMax))
        let d = docAt(p), o0 = cv.bounds.origin, old = mag()
        let k = old / cm
        let desired = NSPoint(x: d.x - (d.x - o0.x) * k, y: d.y - (d.y - o0.y) * k)
        let bs = NSSize(width: cv.frame.width / cm, height: cv.frame.height / cm)
        let predicted = cv.constrainedOrigin(desired, boundsSize: bs)
        let clamped = abs(predicted.x - desired.x) > 0.02 || abs(predicted.y - desired.y) > 0.02
        action()
        let e = err(d, docAt(p))
        if clamped {
            chk("\(label) 撞边界：origin 精确等于约束值（无漂移）",
                abs(cv.bounds.origin.x - predicted.x) < 0.02 && abs(cv.bounds.origin.y - predicted.y) < 0.02)
        } else {
            chk("\(label) 锚点保持，误差 \(f3(e)) < 0.5", e < 0.5)
        }
        chk("\(label) 无越界/NaN/布局跳变", geomOK())
    }

    print("=== 缩放验收自检（1000x500 图 / 620x900 窗口）===")
    print("适配比例 fit = \(f3(v.fitScale))，叠加倍率 = \(f3(cfg.dblclickStep))")

    // 【1】任意位置锚点放大：动作执行器 + 以点击点为锚点
    print("【1】任意位置锚点放大（点击点锚定）")
    reset(v.fitScale)
    let mFit = mag()
    v.perform(.zoomInStep, pointer: NSPoint(x: W / 2, y: H / 2))
    chk("从适配态叠加放大一档（动作执行器，与映射表解耦）",
        abs(Double(mag()) - Double(mFit) * cfg.dblclickStep) < 1e-6)
    let pts: [(String, NSPoint)] = [
        ("中心", NSPoint(x: W / 2, y: H / 2)),
        ("左上1/4", NSPoint(x: W * 0.25, y: H * 0.75)),
        ("右下1/4", NSPoint(x: W * 0.75, y: H * 0.25)),
        ("靠左2px", NSPoint(x: 2, y: H / 2)),
        ("靠右2px", NSPoint(x: W - 2, y: H / 2)),
        ("靠上2px", NSPoint(x: W / 2, y: H - 2)),
        ("靠下2px", NSPoint(x: W / 2, y: 2)),
        ("容器左上角", NSPoint(x: 0, y: H)),
        ("容器右下角", NSPoint(x: W, y: 0)),
    ]
    for (name, p) in pts {
        reset(2.5)   // 两轴都超出窗口，锚点可以精确保持
        checkAnchored("锚点放大-\(name)", p, 2.5 * cfg.dblclickStep) {
            v.perform(.zoomInStep, pointer: p)
        }
        chk("锚点放大-\(name) 倍率按级别叠加", abs(Double(mag()) - 2.5 * cfg.dblclickStep) < 1e-6)
    }

    // 【2】连续放大：同一点连按 5 次双击，锚点逐次不漂移
    print("【2】连续放大（同一点连续 5 次叠加）")
    reset(2.0)
    let pc = NSPoint(x: W * 0.35, y: H * 0.62)
    var expected = 2.0
    for k in 1...5 {
        let before = docAt(pc)
        v.perform(.zoomInStep, pointer: pc)
        expected *= cfg.dblclickStep
        chk("第\(k)次 锚点误差 \(f3(err(before, docAt(pc)))) < 0.5", err(before, docAt(pc)) < 0.5)
        chk("第\(k)次 倍率 \(f3(Double(mag()))) = \(f3(expected))", abs(Double(mag()) - expected) < 1e-6)
        chk("第\(k)次 几何合法", geomOK())
    }

    // 【3】滚轮双向：同一指针放大/缩小交替，缩小也不得偏移
    print("【3】滚轮放大 / 缩小（同一指针，双向）")
    reset(4.0)
    let pw = NSPoint(x: W * 0.7, y: H * 0.3)
    for k in 1...4 {
        for (dir, f) in [("放大", exp(0.1)), ("缩小", exp(-0.1))] {
            let target = Double(mag()) * f
            checkAnchored("滚轮\(dir)#\(k)", pw, target) { v.setZoom(target, anchorInView: pw) }
        }
    }
    chk("滚轮往返后倍率回到 4.0（无累积漂移）", abs(Double(mag()) - 4.0) < 1e-6)
    checkAnchored("大幅缩小到图片小于窗口", pw, 0.5) { v.setZoom(0.5, anchorInView: pw) }
    chk("缩小到居中态几何合法", geomOK())

    // 【4】边缘 / 四角 / 图片外黑边
    print("【4】边缘、四角、图片外黑边")
    let edges: [(String, NSPoint)] = [
        ("容器左上角", NSPoint(x: 0, y: H)),
        ("容器右上角", NSPoint(x: W, y: H)),
        ("容器左下角", NSPoint(x: 0, y: 0)),
        ("容器右下角", NSPoint(x: W, y: 0)),
        ("上黑边", NSPoint(x: W / 2, y: H - 5)),
        ("下黑边", NSPoint(x: W / 2, y: 5)),
        ("图片上边缘", NSPoint(x: W / 2, y: H / 2 + 155)),
        ("图片下边缘", NSPoint(x: W / 2, y: H / 2 - 155)),
        ("四角外一点", NSPoint(x: -20, y: H + 20)),
    ]
    for (name, p) in edges {
        reset(v.fitScale)
        let target = Double(mag()) * cfg.dblclickStep
        checkAnchored("边缘-\(name)", p, target) { v.perform(.zoomInStep, pointer: p) }
    }
    reset(v.fitScale)
    v.perform(.zoomInStep, pointer: .zero); let o1 = cv.bounds.origin
    v.perform(.zoomInStep, pointer: .zero); let o2 = cv.bounds.origin
    chk("四角连续两次缩放 origin 有限且几何合法",
        o1.x.isFinite && o1.y.isFinite && o2.x.isFinite && o2.y.isFinite && geomOK())

    // 【5】缩放上下限：到达边界后不再抖动
    print("【5】缩放上下限")
    reset(2.0)
    let pt = NSPoint(x: W * 0.4, y: H * 0.6)
    for _ in 0..<40 { v.setZoom(Double(mag()) * 1.5, anchorInView: pt) }
    chk("到达上限 = \(f3(cfg.zoomMax))", abs(Double(mag()) - cfg.zoomMax) < 1e-6)
    chk("上限处几何合法", geomOK())
    let oTop = cv.bounds.origin
    v.setZoom(Double(mag()) * 1.5, anchorInView: pt)
    chk("到顶后再操作 origin 完全不变（无抖动）",
        abs(cv.bounds.origin.x - oTop.x) < 1e-6 && abs(cv.bounds.origin.y - oTop.y) < 1e-6)
    for _ in 0..<60 { v.setZoom(Double(mag()) / 1.5, anchorInView: pt) }
    chk("到达下限 = \(f3(cfg.zoomMin))", abs(Double(mag()) - cfg.zoomMin) < 1e-6)
    chk("下限处几何合法", geomOK())
    let oBot = cv.bounds.origin
    v.setZoom(Double(mag()) / 1.5, anchorInView: pt)
    chk("到底后再操作 origin 完全不变", abs(cv.bounds.origin.x - oBot.x) < 1e-6 && abs(cv.bounds.origin.y - oBot.y) < 1e-6)

    // 【6】现有交互回归
    print("【6】现有交互回归")
    reset(v.fitScale)
    chk("适配比例 = min(W/1000, H/500)", abs(Double(mag()) - Double(min(W / 1000, H / 500))) < 1e-6)
    chk("fit 态垂直居中", abs(cv.bounds.origin.y + (cv.bounds.height - 500) / 2) < 0.02)
    chk("fit 态 isZoomedIn = false", !v.isZoomedIn())
    v.zoomIn()
    chk("键盘 + 中心放大到 fit*zoomStep", abs(Double(mag()) - v.fitScale * cfg.zoomStep) < 1e-6)
    chk("放大后 isZoomedIn = true", v.isZoomedIn())
    v.zoomOut()
    chk("键盘 - 回到 fit", abs(Double(mag()) - v.fitScale) < 1e-6)
    v.setZoom(3.0)
    let mBeforeLayout = mag()
    v.layout()
    chk("layout 尺寸不变时不重置缩放（无布局跳动）", abs(mag() - mBeforeLayout) < 1e-6)
    v.setFrameSize(NSSize(width: 800, height: 1000)); v.layout()
    let expectFit = min(800.0 / 1000.0, 1000.0 / 500.0)
    chk("窗口尺寸变化后重新适配（实测 \(f3(Double(mag())))，期望 \(f3(expectFit))）",
        abs(Double(mag()) - expectFit) < 1e-6)
    v.setFrameSize(NSSize(width: W, height: H)); v.layout()
    v.setZoom(3.0); v.resetZoom()
    chk("0 键复原到适配", abs(Double(mag()) - v.fitScale) < 1e-6)

    // 真实事件路径：⌘+滚轮（走 scrollWheel → setZoom）
    reset(3.0)
    let cgZoom = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                         wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0)!
    cgZoom.location = CGPoint(x: W * 0.3, y: H * 0.7)
    cgZoom.flags = .maskCommand
    let evZoom = NSEvent(cgEvent: cgZoom)!
    let pz = v.convert(evZoom.locationInWindow, from: nil)
    let dz0 = docAt(pz)
    v.scrollWheel(with: evZoom)
    chk("⌘滚轮真实事件触发放大", mag() > 3.0)
    chk("⌘滚轮真实事件锚点保持，误差 \(f3(err(dz0, docAt(pz)))) < 0.5", err(dz0, docAt(pz)) < 0.5)
    chk("⌘滚轮事件后几何合法", geomOK())

    // 真实事件路径：双击 → 100% 原图；连续第二次双击 → 还原全图（映射表默认）
    reset(2.5); v.dblArmed = false
    let evDbl = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: W * 0.6, y: H * 0.4),
                                   modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                   eventNumber: 1, clickCount: 2, pressure: 0)!
    v.mouseUp(with: evDbl)
    chk("双击真实事件 → 100% 原图", abs(Double(mag()) - 1.0) < 1e-6)
    chk("双击到 100% 后几何合法", geomOK())
    let evDbl2 = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: W * 0.6, y: H * 0.4),
                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    eventNumber: 2, clickCount: 2, pressure: 0)!
    v.mouseUp(with: evDbl2)
    chk("连续第二次双击 → 还原全图", abs(Double(mag()) - v.fitScale) < 1e-6)
    chk("还原全图后居中且几何合法", geomOK())

    // 放大后拖动平移：内容跟手且不越界
    reset(3.0)
    let evDown = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: 400),
                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    eventNumber: 1, clickCount: 1, pressure: 0)!
    v.mouseDown(with: evDown)
    let evDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 340, y: 430),
                                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                    eventNumber: 2, clickCount: 1, pressure: 0)!
    let od0 = cv.bounds.origin
    v.mouseDragged(with: evDrag)
    chk("拖动方向正确（内容跟手，两轴一致）", cv.bounds.origin.x < od0.x && cv.bounds.origin.y < od0.y)
    chk("拖动后几何合法不越界", geomOK())

    // 无修饰滚轮：缩放，且不切换照片 / 不产生页面滚动（FSViewer 风格）
    v.items = [
        MediaItem(kind: .image, id: "", path: "/tmp/__zoom_fake_a__.jpg", name: "a.jpg", date: nil, size: 0, duration: 0),
        MediaItem(kind: .image, id: "", path: "/tmp/__zoom_fake_b__.jpg", name: "b.jpg", date: nil, size: 0, duration: 0),
    ]
    v.index = 0
    reset(v.fitScale)
    let beforeWheel = mag()
    let cgPage = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                         wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0)!
    v.scrollWheel(with: NSEvent(cgEvent: cgPage)!)
    chk("无修饰滚轮改为缩放（倍率变大）", mag() > beforeWheel)
    chk("滚轮缩放不切换照片（index 保持 0）", v.index == 0)
    chk("滚轮缩放不产生页面滚动（wheelAccum=0）", v.wheelAccum == 0)

    reset(2.0)
    let dc0 = docAt(NSPoint(x: W / 2, y: H / 2))
    v.swapKeepingView(solid(2000, 1000))
    let dc1 = docAt(NSPoint(x: W / 2, y: H / 2))
    chk("补解全分辨率后中心内容比例保持",
        abs(Double(dc0.x / 1000 - dc1.x / 2000)) < 0.01 &&
        abs(Double(dc0.y / 500 - dc1.y / 1000)) < 0.01)
    chk("补解后几何合法", geomOK())

    print("=== 结果 \(pass)/\(total) 通过 ===")
    exit(pass == total ? 0 : 1)
}

// 离屏渲染：不弹窗口，直接画成 PNG（本机 screencapture 无屏幕录制权限，截图全黑）
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let outPath = args[i + 1]
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    var snapW: CGFloat = 620, snapH: CGFloat = 1080
    if let i = args.firstIndex(of: "--wh"), i + 1 < args.count {
        let p = args[i + 1].split(separator: "x").compactMap { Double($0) }
        if p.count == 2 { snapW = CGFloat(p[0]); snapH = CGFloat(p[1]) }
    }
    let v = GalleryView(frame: NSRect(x: 0, y: 0, width: snapW, height: snapH), localDir: localDir)
    if localDir == nil {
        guard let s = Adb.findDevice() else { print("NO_DEVICE"); exit(1) }
        Adb.serial = s
        v.items = loadPhotosFromDevice()
    }
    v.start()
    RunLoop.current.run(until: Date().addingTimeInterval(2.5))
    if args.contains("--full") {          // 验证补解全分辨率后画面不会跳
        v.ensureFull()
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        print("补解后：\(Int(v.scrollView.magnification * 100))%  图 \(Int(v.docSize(v.imageView.image ?? NSImage()).width))px")
    }
    if args.contains("--zoom-in") {
        v.zoomIn()
        print("放大后比例：\(Int(v.scrollView.magnification * 100))%  (适配比例 \(Int(v.fitScale * 100))%)")
    }
    v.layoutSubtreeIfNeeded()
    v.layout()
    let vis = v.scrollView.contentView.documentVisibleRect
    let docNSSize = v.imageView.frame.size
    print("渲染时实际放大比例：\(Int(v.scrollView.magnification * 100))%  (fit \(Int(v.fitScale * 100))%)")
    print(String(format: "窗口 %.0fx%.0f  原图 %.0fx%.0f  适配比例 %.1f%%  可视区 %.0fx%.0f  文档 %.0fx%.0f",
                 snapW, snapH, docNSSize.width, docNSSize.height, v.fitScale * 100,
                 vis.width, vis.height, docNSSize.width, docNSSize.height))
    print(String(format: "水平边距 左 %.0f 右 %.0f ｜ 垂直边距 下 %.0f 上 %.0f",
                 vis.minX, vis.width - docNSSize.width - vis.minX,
                 vis.minY, vis.height - docNSSize.height - vis.minY))
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("已写出 \(outPath)")
        }
    }
    exit(0)
}

let delegate = AppDelegate(localDir: localDir)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
