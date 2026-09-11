import Foundation

/// 应用内三语字符串表（简体中文 / 繁體中文 / English）。
/// 设计：以简体中文原文为 key（视图里写 L("主页")），切换语言立即生效（无需重启）。
/// 缺失的 key 原样返回（保持简体兜底）。
enum L10n {
    /// 当前语言（由 SettingsStore 持久化驱动，"system" 时解析系统语言）
    nonisolated(unsafe) static var language: Settings.Language = .zhHans {
        didSet { table = table(for: language) }
    }

    /// 翻译入口
    static func t(_ key: String) -> String {
        table[key] ?? key
    }

    // MARK: - 表

    nonisolated(unsafe) private static var table: [String: String] = table(for: .zhHans)

    private static func table(for lang: Settings.Language) -> [String: String] {
        switch lang {
        case .zhHans, .system:
            return [:] // key 即简体，空表兜底
        case .zhHant:
            return zhHant
        case .en:
            return en
        }
    }

    // MARK: - 繁體中文

    private static let zhHant: [String: String] = [
        // 侧边栏 / 导航
        "主页": "主頁",
        "下载管理": "下載管理",
        "设置": "設定",
        "关于": "關於",
        "未登录": "未登入",
        "点击导入 Cookie": "點擊匯入 Cookie",
        "登出": "登出",
        // 主页 / 搜索
        "搜索": "搜尋",
        "请输入用户 ID，如：shiratamacaron": "請輸入用戶 ID，如：shiratamacaron",
        "清空历史": "清空歷史",
        "正在加载用户…": "正在載入用戶…",
        "加载中…": "載入中…",
        "加载更多": "載入更多",
        "该用户没有媒体内容": "該用戶沒有媒體內容",
        "请先登录": "請先登入",
        "点击左侧账户卡导入 Cookie 后再搜索用户": "點擊左側賬戶卡匯入 Cookie 後再搜尋用戶",
        "输入用户 screen_name 开始浏览媒体": "輸入用戶 screen_name 開始瀏覽媒體",
        "媒体": "媒體",
        "注册于": "註冊於",
        "打开主页": "開啟主頁",
        "下载": "下載",
        "打开推文": "開啟推文",
        "图片": "圖片",
        "视频": "影片",
        // 下载配置
        "下载配置": "下載設定",
        "从": "從",
        "至": "至",
        "开始下载": "開始下載",
        "数据源": "資料來源",
        "媒体时间线": "媒體時間線",
        "推文时间线": "推文時間線",
        // 下载管理
        "下载中": "下載中",
        "等待中": "等待中",
        "已完成": "已完成",
        "失败": "失敗",
        "已暂停": "已暫停",
        "已移除": "已移除",
        "已跳过": "已跳過",
        "暂停": "暫停",
        "恢复": "恢復",
        "重试": "重試",
        "删除": "刪除",
        "全部暂停": "全部暫停",
        "全部恢复": "全部恢復",
        "全部重试": "全部重試",
        "全部删除": "全部刪除",
        "打开文件": "開啟檔案",
        "在文件夹中显示": "在資料夾中顯示",
        "未知大小": "未知大小",
        "暂无任务": "暫無任務",
        "进行中": "進行中",
        "跳过原因：1. 相同文件名已存在且开启跳过相同文件；2. 爬取进度未到指定开始日期":
            "跳過原因：1. 相同檔名已存在且開啟跳過相同檔案；2. 爬取進度未到指定開始日期",
        // 设置
        "保存路径": "儲存路徑",
        "选择…": "選擇…",
        "按账号创建子文件夹": "按賬號建立子資料夾",
        "开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中，如：": "開啟後，資源將儲存到「儲存路徑/暱稱-@用戶名」資料夾中，如：",
        "文件名模板": "檔名模板",
        "预览": "預覽",
        "可用变量（点击复制）": "可用變數（點擊複製）",
        "展开": "展開",
        "收起": "收起",
        "跳过已存在的相同文件": "跳過已存在的相同檔案",
        "代理": "代理",
        "启用代理": "啟用代理",
        "使用系统代理": "使用系統代理",
        "代理地址": "代理位址",
        "外观": "外觀",
        "界面字体大小": "介面字體大小",
        "语言/Language": "語言/Language",
        "跟随系统": "跟隨系統",
        "简体中文": "簡體中文",
        "电源": "電源",
        "有下载任务时阻止系统休眠": "有下載任務時阻止系統休眠",
        "使用系统电源断言机制，仅在下载进行期间保持唤醒，不会修改系统设置":
            "使用系統電源斷言機制，僅在下載進行期間保持喚醒，不會修改系統設定",
        "日志": "日誌",
        "开启日志记录": "開啟日誌記錄",
        "日志记录网络请求、下载任务、错误等信息，用于问题排查":
            "日誌記錄網路請求、下載任務、錯誤等資訊，用於問題排查",
        "日志位置": "日誌位置",
        "导出日志…": "匯出日誌…",
        "暂无日志文件可导出": "暫無日誌檔案可匯出",
        "在 Finder 中显示": "在 Finder 中顯示",
        // 登录
        "登录 X 账号": "登入 X 賬號",
        "登录": "登入",
        "取消": "取消",
        "验证中…": "驗證中…",
        // 其余
        "完成": "完成",
        "切换到": "切換到",
        "重启并应用": "重啟並套用",
        "稍后手动重启": "稍後手動重啟",
        "重启失败，请手动退出并重新打开应用": "重啟失敗，請手動退出並重新開啟應用",
        "语言设置将保存为": "語言設定將儲存為",
        "。需要重启应用才能完全生效。": "。需要重啟應用才能完全生效。",
        "标签1": "標籤1",
        "个任务创建中": "個任務建立中",
        "已发送：": "已傳送：",
        "已跳过：": "已跳過：",
        "个日志文件": "個日誌檔案",
        "共": "共",
        "切换到": "切換到",
        "标签2": "標籤2",
    ]

    // MARK: - English

    private static let en: [String: String] = [
        // Sidebar / navigation
        "主页": "Home",
        "下载管理": "Downloads",
        "设置": "Settings",
        "关于": "About",
        "未登录": "Not signed in",
        "点击导入 Cookie": "Click to import Cookie",
        "登出": "Sign out",
        // Home / search
        "搜索": "Search",
        "请输入用户 ID，如：shiratamacaron": "Enter a user ID, e.g. shiratamacaron",
        "清空历史": "Clear history",
        "正在加载用户…": "Loading user…",
        "加载中…": "Loading…",
        "加载更多": "Load more",
        "该用户没有媒体内容": "No media from this user",
        "请先登录": "Sign in required",
        "点击左侧账户卡导入 Cookie 后再搜索用户": "Import Cookie from the account card on the left, then search users",
        "输入用户 screen_name 开始浏览媒体": "Enter a user's screen_name to browse media",
        "媒体": "media",
        "注册于": "Registered",
        "打开主页": "Open profile",
        "下载": "Download",
        "打开推文": "Open post",
        "图片": "Photo",
        "视频": "Video",
        // Download config
        "下载配置": "Download Settings",
        "从": "From",
        "至": "To",
        "开始下载": "Start Download",
        "数据源": "Source",
        "媒体时间线": "Media timeline",
        "推文时间线": "Posts timeline",
        // Downloads
        "下载中": "Downloading",
        "等待中": "Waiting",
        "已完成": "Completed",
        "失败": "Failed",
        "已暂停": "Paused",
        "已移除": "Removed",
        "已跳过": "Skipped",
        "暂停": "Pause",
        "恢复": "Resume",
        "重试": "Retry",
        "删除": "Delete",
        "全部暂停": "Pause All",
        "全部恢复": "Resume All",
        "全部重试": "Retry All",
        "全部删除": "Delete All",
        "打开文件": "Open File",
        "在文件夹中显示": "Show in Folder",
        "未知大小": "Unknown size",
        "暂无任务": "No tasks",
        "进行中": "active",
        "跳过原因：1. 相同文件名已存在且开启跳过相同文件；2. 爬取进度未到指定开始日期":
            "Skipped: 1. A file with the same name exists and skip-duplicates is on; 2. Crawl progress hasn't reached the start date",
        // Settings
        "保存路径": "Save Path",
        "选择…": "Choose…",
        "按账号创建子文件夹": "Create subfolder per account",
        "开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中，如：":
            "When enabled, files are saved to \"Save Path/nickname-@username\", e.g. ",
        "文件名模板": "Filename Template",
        "预览": "Preview",
        "可用变量（点击复制）": "Variables (click to copy)",
        "展开": "Expand",
        "收起": "Collapse",
        "跳过已存在的相同文件": "Skip existing duplicate files",
        "代理": "Proxy",
        "启用代理": "Enable Proxy",
        "使用系统代理": "Use System Proxy",
        "代理地址": "Proxy URL",
        "外观": "Appearance",
        "界面字体大小": "UI Font Size",
        "语言/Language": "语言/Language",
        "跟随系统": "System",
        "简体中文": "简体中文",
        "电源": "Power",
        "有下载任务时阻止系统休眠": "Prevent sleep while downloading",
        "使用系统电源断言机制，仅在下载进行期间保持唤醒，不会修改系统设置":
            "Uses the system power assertion API — keeps the Mac awake only while downloads are active; no system settings are changed",
        "日志": "Logging",
        "开启日志记录": "Enable Logging",
        "日志记录网络请求、下载任务、错误等信息，用于问题排查":
            "Logs network requests, download tasks and errors for troubleshooting",
        "日志位置": "Log Location",
        "导出日志…": "Export Logs…",
        "暂无日志文件可导出": "No log files to export",
        "在 Finder 中显示": "Reveal in Finder",
        // Sign in
        "登录 X 账号": "Sign in to X",
        "登录": "Sign in",
        "取消": "Cancel",
        "验证中…": "Verifying…",
        // Misc
        "完成": "Done",
        "切换到": "Switch to",
        "重启并应用": "Restart & Apply",
        "稍后手动重启": "Restart Later",
        "重启失败，请手动退出并重新打开应用": "Restart failed — please quit and reopen the app",
        "语言设置将保存为": "Language will be saved as",
        "。需要重启应用才能完全生效。": ". Restart is required to fully apply.",
        "标签1": "Label 1",
        "个任务创建中": " tasks being created",
        "已发送：": "Sent: ",
        "已跳过：": "Skipped: ",
        "个日志文件": " log file(s)",
        "共": "",
        "切换到": "Switch to",
        "标签2": "Label 2",
    ]
}

/// 视图内便捷用法：Text(L("主页"))
func L(_ key: String) -> String {
    L10n.t(key)
}
