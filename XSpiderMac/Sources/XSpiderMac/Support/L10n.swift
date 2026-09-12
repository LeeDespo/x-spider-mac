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

    private static let zhHant: [String: String] = safeDict([


        // 侧边栏 / 导航
        ("主页", "主頁"),
        ("下载管理", "下載管理"),
        ("设置", "設定"),
        ("关于", "關於"),
        ("未登录", "未登入"),
        ("点击导入 Cookie", "點擊匯入 Cookie"),
        ("登出", "登出"),
        // 主页 / 搜索
        ("搜索", "搜尋"),
        ("请输入用户 ID，如：shiratamacaron", "請輸入用戶 ID，如：shiratamacaron"),
        ("清空历史", "清空歷史"),
        ("正在加载用户…", "正在載入用戶…"),
        ("加载中…", "載入中…"),
        ("加载更多", "載入更多"),
        ("该用户没有媒体内容", "該用戶沒有媒體內容"),
        ("请先登录", "請先登入"),
        ("点击左侧账户卡导入 Cookie 后再搜索用户", "點擊左側賬戶卡匯入 Cookie 後再搜尋用戶"),
        ("输入用户 screen_name 开始浏览媒体", "輸入用戶 screen_name 開始瀏覽媒體"),
        ("媒体", "媒體"),
        ("注册于", "註冊於"),
        ("打开主页", "開啟主頁"),
        ("下载", "下載"),
        ("打开推文", "開啟推文"),
        ("图片", "圖片"),
        ("视频", "影片"),
        // 下载配置
        ("下载配置", "下載設定"),
        ("从", "從"),
        ("至", "至"),
        ("开始下载", "開始下載"),
        ("数据源", "資料來源"),
        ("媒体时间线", "媒體時間線"),
        ("推文时间线", "推文時間線"),
        // 下载管理
        ("下载中", "下載中"),
        ("等待中", "等待中"),
        ("已完成", "已完成"),
        ("失败", "失敗"),
        ("已暂停", "已暫停"),
        ("已移除", "已移除"),
        ("已跳过", "已跳過"),
        ("暂停", "暫停"),
        ("恢复", "恢復"),
        ("重试", "重試"),
        ("删除", "刪除"),
        ("全部暂停", "全部暫停"),
        ("全部恢复", "全部恢復"),
        ("全部重试", "全部重試"),
        ("全部删除", "全部刪除"),
        ("打开文件", "開啟檔案"),
        ("在文件夹中显示", "在資料夾中顯示"),
        ("未知大小", "未知大小"),
        ("暂无任务", "暫無任務"),
        ("进行中", "進行中"),
        ("跳过原因：1. 相同文件名已存在且开启跳过相同文件；2. 爬取进度未到指定开始日期", "跳過原因：1. 相同檔名已存在且開啟跳過相同檔案；2. 爬取進度未到指定開始日期"),
        // 设置
        ("保存路径", "儲存路徑"),
        ("选择…", "選擇…"),
        ("按账号创建子文件夹", "按賬號建立子資料夾"),
        ("开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中，如：", "開啟後，資源將儲存到「儲存路徑/暱稱-@用戶名」資料夾中，如："),
        ("文件名模板", "檔名模板"),
        ("预览", "預覽"),
        ("可用变量（点击复制）", "可用變數（點擊複製）"),
        ("展开", "展開"),
        ("收起", "收起"),
        ("跳过已存在的相同文件", "跳過已存在的相同檔案"),
        ("代理", "代理"),
        ("启用代理", "啟用代理"),
        ("使用系统代理", "使用系統代理"),
        ("代理地址", "代理位址"),
        ("外观", "外觀"),
        ("界面字体大小", "介面字體大小"),
        ("语言/Language", "語言/Language"),
        ("跟随系统", "跟隨系統"),
        ("简体中文", "簡體中文"),
        ("电源", "電源"),
        ("有下载任务时阻止系统休眠", "有下載任務時阻止系統休眠"),
        ("使用系统电源断言机制，仅在下载进行期间保持唤醒，不会修改系统设置", "使用系統電源斷言機制，僅在下載進行期間保持喚醒，不會修改系統設定"),
        ("日志", "日誌"),
        ("开启日志记录", "開啟日誌記錄"),
        ("日志记录网络请求、下载任务、错误等信息，用于问题排查", "日誌記錄網路請求、下載任務、錯誤等資訊，用於問題排查"),
        ("日志位置", "日誌位置"),
        ("导出日志…", "匯出日誌…"),
        ("暂无日志文件可导出", "暫無日誌檔案可匯出"),
        ("在 Finder 中显示", "在 Finder 中顯示"),
        // 登录
        ("登录 X 账号", "登入 X 賬號"),
        ("登录", "登入"),
        ("取消", "取消"),
        ("验证中…", "驗證中…"),
        // 其余
        ("完成", "完成"),
        ("切换到", "切換到"),
        ("重启并应用", "重啟並套用"),
        ("稍后手动重启", "稍後手動重啟"),
        ("重启失败，请手动退出并重新打开应用", "重啟失敗，請手動退出並重新開啟應用"),
        ("语言设置将保存为", "語言設定將儲存為"),
        ("。需要重启应用才能完全生效。", "。需要重啟應用才能完全生效。"),
        ("标签1", "標籤1"),
        ("个任务创建中", "個任務建立中"),
        ("已发送：", "已傳送："),
        ("已跳过：", "已跳過："),
        ("个日志文件", "個日誌檔案"),
        ("共", "共"),
        ("标签2", "標籤2"),
        ("加载媒体", "載入媒體"),
        ("搜索后自动加载媒体时间线", "搜尋後自動載入媒體時間線"),
        ("关闭后，主页仅显示用户信息与下载配置，需要时点击「加载媒体」手动加载，可显著节省流量。媒体网格始终使用缩略图展示，下载原图不受影响。", "關閉後，主頁僅顯示用戶資訊與下載設定，需要時點擊「載入媒體」手動載入，可顯著節省流量。媒體網格始終使用縮圖展示，下載原圖不受影響。"),
        ("失败", "失敗"),
        ("需要重启应用才能完全生效", "需要重新啟動應用才能完全生效"),
        ("立刻重启", "立刻重新啟動"),
        ("暂不重启", "暫不重新啟動"),
        ("字号与语言修改已保存。部分界面元素将在重启后应用新设置。", "字號與語言修改已儲存。部分介面元素將在重新啟動後套用新設定。"),
        ("macOS 原生版 X 媒体下载器", "macOS 原生版 X 媒體下載器"),
        ("关于", "關於"),

        ("自动加载媒体", "自動載入媒體"),
        ("主页", "主頁"),
        ("按用户筛选", "按用戶篩選"),
        ("显示全部", "顯示全部"),
        ("选择用户", "選擇用戶"),
        ("暂无记录", "暫無記錄"),
        ("删除当前记录", "刪除目前記錄"),
        ("删除所有日志", "刪除所有日誌"),
        ("确定删除所有日志文件？", "確定刪除所有日誌檔案？"),
        ("此操作不可撤销，当前日志与历史轮转文件都会被删除。", "此操作不可復原，目前日誌與歷史輪轉檔案都會被刪除。"),
        ("日志已全部删除", "日誌已全部刪除"),
        ("自动删除下载历史记录", "自動刪除下載歷史記錄"),
        ("自动删除搜索记录", "自動刪除搜尋記錄"),
        ("开启后，每次离开对应页面时自动清空相应历史记录。仅删除记录，不删除已下载的文件。", "開啟後，每次離開對應頁面時自動清空相應歷史記錄。僅刪除記錄，不刪除已下載的檔案。"),
        ("已下载", "已下載"),
        ("隐私", "隱私"),

        ("下载引擎", "下載引擎"),
        ("内置引擎", "內建引擎"),
        ("aria2：多连接分块下载，大文件更快更稳（推荐）；内置引擎：系统原生 URLSession，单连接。切换引擎后新任务生效。", "aria2：多連線分塊下載，大檔案更快更穩（推薦）；內建引擎：系統原生 URLSession，單連線。切換引擎後新任務生效。"),
        ("同时下载文件数", "同時下載檔案數"),
        ("数据", "資料"),
        ("清除所有应用数据…", "清除所有應用資料…"),
        ("应用数据统一存放在 Application Support/XSpiderMac、Caches/XSpiderMac 和 Logs/XSpiderMac，已下载的媒体文件不受影响。", "應用資料統一存放在 Application Support/XSpiderMac、Caches/XSpiderMac 和 Logs/XSpiderMac，已下載的媒體檔案不受影響。"),
        ("确定清除所有应用数据？", "確定清除所有應用資料？"),
        ("删除并退出应用", "刪除並結束應用"),
        ("将删除以下应用创建的目录（已下载的媒体文件不受影响）：\n", "將刪除以下應用建立的目錄（已下載的媒體檔案不受影響）：\n"),
        ("应用数据（下载暂存、aria2 会话）", "應用資料（下載暫存、aria2 會話）"),
        ("缓存（URL 缓存数据库）", "快取（URL 快取資料庫）"),
        ("日志（xspider.log 及历史）", "日誌（xspider.log 及歷史）"),

        ("引擎", "引擎"),
        ("内置引擎", "內建引擎"),
        ("未找到 aria2c（brew install aria2 安装后重启应用，或改用内置引擎）", "未找到 aria2c（brew install aria2 安裝後重啟應用，或改用內建引擎）"),
        ("同时下载文件数", "同時下載檔案數"),
        ("单文件连接数", "單檔案連接數"),
        ("最小分块大小 (MB)", "最小分塊大小 (MB)"),
        ("文件分配方式", "檔案分配方式"),
        ("预分配（推荐 HDD）", "預分配（建議 HDD）"),
        ("快速分配（推荐 SSD）", "快速分配（建議 SSD）"),
        ("不分配", "不分配"),
        ("液态玻璃外观", "液態玻璃外觀"),
        ("当前 macOS 版本低于 26（Tahoe），不支持液态玻璃，已自动使用标准材质。", "當前 macOS 版本低於 26（Tahoe），不支援液態玻璃，已自動使用標準材質。"),

        ("输入用户 ID 或推文链接", "輸入用戶 ID 或推文連結"),
        ("该推文没有媒体内容", "該推文沒有媒體內容"),
        ("推文加载失败", "推文載入失敗"),

        ("正在加载推文…", "正在載入推文…"),

        ("搜索历史", "搜尋歷史"),
        ("暂无搜索历史", "暫無搜尋歷史"),
        ("删除该条记录", "刪除該條記錄"),
        ("推文", "推文"),
        ("启用图片缓存", "啟用圖片快取"),
        ("用户头像", "用戶頭像"),
        ("媒体缩略图", "媒體縮圖"),
        ("缓存上限", "快取上限"),
        ("超出上限后自动清理最旧的缓存文件。", "超出上限後自動清理最舊的快取檔案。"),
        ("立即清理缓存", "立即清理快取"),
        ("已清理", "已清理"),
        ("缓存", "快取"),
        ("模糊度", "模糊度"),
        ("调整玻璃材质的模糊与透光度，实时生效。", "調整玻璃材質的模糊與透光度，即時生效。"),
        ("该媒体已下载过", "該媒體已下載過"),
        ("已下载", "已下載"),

    ])

    // MARK: - English

    private static let en: [String: String] = safeDict([


        // Sidebar / navigation
        ("主页", "Home"),
        ("下载管理", "Downloads"),
        ("设置", "Settings"),
        ("关于", "About"),
        ("未登录", "Not signed in"),
        ("点击导入 Cookie", "Click to import Cookie"),
        ("登出", "Sign out"),
        // Home / search
        ("搜索", "Search"),
        ("请输入用户 ID，如：shiratamacaron", "Enter a user ID, e.g. shiratamacaron"),
        ("清空历史", "Clear history"),
        ("正在加载用户…", "Loading user…"),
        ("加载中…", "Loading…"),
        ("加载更多", "Load more"),
        ("该用户没有媒体内容", "No media from this user"),
        ("请先登录", "Sign in required"),
        ("点击左侧账户卡导入 Cookie 后再搜索用户", "Import Cookie from the account card on the left, then search users"),
        ("输入用户 screen_name 开始浏览媒体", "Enter a user's screen_name to browse media"),
        ("媒体", "media"),
        ("注册于", "Registered"),
        ("打开主页", "Open profile"),
        ("下载", "Download"),
        ("打开推文", "Open post"),
        ("图片", "Photo"),
        ("视频", "Video"),
        // Download config
        ("下载配置", "Download Settings"),
        ("从", "From"),
        ("至", "To"),
        ("开始下载", "Start Download"),
        ("数据源", "Source"),
        ("媒体时间线", "Media timeline"),
        ("推文时间线", "Posts timeline"),
        // Downloads
        ("下载中", "Downloading"),
        ("等待中", "Waiting"),
        ("已完成", "Completed"),
        ("失败", "Failed"),
        ("已暂停", "Paused"),
        ("已移除", "Removed"),
        ("已跳过", "Skipped"),
        ("暂停", "Pause"),
        ("恢复", "Resume"),
        ("重试", "Retry"),
        ("删除", "Delete"),
        ("全部暂停", "Pause All"),
        ("全部恢复", "Resume All"),
        ("全部重试", "Retry All"),
        ("全部删除", "Delete All"),
        ("打开文件", "Open File"),
        ("在文件夹中显示", "Show in Folder"),
        ("未知大小", "Unknown size"),
        ("暂无任务", "No tasks"),
        ("进行中", "active"),
        ("跳过原因：1. 相同文件名已存在且开启跳过相同文件；2. 爬取进度未到指定开始日期", "Skipped: 1. A file with the same name exists and skip-duplicates is on; 2. Crawl progress hasn't reached the start date"),
        // Settings
        ("保存路径", "Save Path"),
        ("选择…", "Choose…"),
        ("按账号创建子文件夹", "Create subfolder per account"),
        ("开启后，资源将保存到「保存路径/昵称-@用户名」文件夹中，如：", "When enabled, files are saved to \"Save Path/nickname-@username\", e.g. "),
        ("文件名模板", "Filename Template"),
        ("预览", "Preview"),
        ("可用变量（点击复制）", "Variables (click to copy)"),
        ("展开", "Expand"),
        ("收起", "Collapse"),
        ("跳过已存在的相同文件", "Skip existing duplicate files"),
        ("代理", "Proxy"),
        ("启用代理", "Enable Proxy"),
        ("使用系统代理", "Use System Proxy"),
        ("代理地址", "Proxy URL"),
        ("外观", "Appearance"),
        ("界面字体大小", "UI Font Size"),
        ("语言/Language", "语言/Language"),
        ("跟随系统", "System"),
        ("简体中文", "简体中文"),
        ("电源", "Power"),
        ("有下载任务时阻止系统休眠", "Prevent sleep while downloading"),
        ("使用系统电源断言机制，仅在下载进行期间保持唤醒，不会修改系统设置", "Uses the system power assertion API — keeps the Mac awake only while downloads are active; no system settings are changed"),
        ("日志", "Logging"),
        ("开启日志记录", "Enable Logging"),
        ("日志记录网络请求、下载任务、错误等信息，用于问题排查", "Logs network requests, download tasks and errors for troubleshooting"),
        ("日志位置", "Log Location"),
        ("导出日志…", "Export Logs…"),
        ("暂无日志文件可导出", "No log files to export"),
        ("在 Finder 中显示", "Reveal in Finder"),
        // Sign in
        ("登录 X 账号", "Sign in to X"),
        ("登录", "Sign in"),
        ("取消", "Cancel"),
        ("验证中…", "Verifying…"),
        // Misc
        ("完成", "Done"),
        ("切换到", "Switch to"),
        ("重启并应用", "Restart & Apply"),
        ("稍后手动重启", "Restart Later"),
        ("重启失败，请手动退出并重新打开应用", "Restart failed — please quit and reopen the app"),
        ("语言设置将保存为", "Language will be saved as"),
        ("。需要重启应用才能完全生效。", ". Restart is required to fully apply."),
        ("标签1", "Label 1"),
        ("个任务创建中", " tasks being created"),
        ("已发送：", "Sent: "),
        ("已跳过：", "Skipped: "),
        ("个日志文件", " log file(s)"),
        ("共", ""),
        ("标签2", "Label 2"),
        ("加载媒体", "Load Media"),
        ("搜索后自动加载媒体时间线", "Auto-load media timeline after search"),
        ("关闭后，主页仅显示用户信息与下载配置，需要时点击「加载媒体」手动加载，可显著节省流量。媒体网格始终使用缩略图展示，下载原图不受影响。", "When off, Home shows only the user card and download settings; click “Load Media” to fetch manually and save bandwidth. The grid always uses thumbnails; original downloads are unaffected."),
        ("失败", "Failed"),
        ("需要重启应用才能完全生效", "Restart required to fully apply"),
        ("立刻重启", "Restart Now"),
        ("暂不重启", "Later"),
        ("字号与语言修改已保存。部分界面元素将在重启后应用新设置。", "Font size and language changes are saved. Some UI elements apply after restart."),
        ("macOS 原生版 X 媒体下载器", "Native macOS media downloader for X"),
        ("关于", "About"),

        ("自动加载媒体", "Auto-load media"),
        ("主页", "Home"),
        ("按用户筛选", "Filter by user"),
        ("显示全部", "Show All"),
        ("选择用户", "Select User"),
        ("暂无记录", "No records"),
        ("删除当前记录", "Delete Shown Records"),
        ("删除所有日志", "Delete All Logs"),
        ("确定删除所有日志文件？", "Delete all log files?"),
        ("此操作不可撤销，当前日志与历史轮转文件都会被删除。", "This cannot be undone. The current log and rotated history will be deleted."),
        ("日志已全部删除", "All logs deleted"),
        ("自动删除下载历史记录", "Auto-delete download history"),
        ("自动删除搜索记录", "Auto-delete search history"),
        ("开启后，每次离开对应页面时自动清空相应历史记录。仅删除记录，不删除已下载的文件。", "When on, histories are cleared each time you leave the page. Only records are removed; downloaded files are kept."),
        ("已下载", "Downloaded"),
        ("隐私", "Privacy"),

        ("下载引擎", "Download Engine"),
        ("内置引擎", "Built-in"),
        ("aria2：多连接分块下载，大文件更快更稳（推荐）；内置引擎：系统原生 URLSession，单连接。切换引擎后新任务生效。", "aria2: multi-connection chunked downloading, faster and more reliable for large files (recommended). Built-in: native URLSession, single connection. Applies to new tasks after switching."),
        ("同时下载文件数", "Concurrent Downloads"),
        ("数据", "Data"),
        ("清除所有应用数据…", "Clear All App Data…"),
        ("应用数据统一存放在 Application Support/XSpiderMac、Caches/XSpiderMac 和 Logs/XSpiderMac，已下载的媒体文件不受影响。", "App data lives in Application Support/XSpiderMac, Caches/XSpiderMac and Logs/XSpiderMac. Downloaded media files are not affected."),
        ("确定清除所有应用数据？", "Clear all app data?"),
        ("删除并退出应用", "Delete and Quit"),
        ("将删除以下应用创建的目录（已下载的媒体文件不受影响）：\n", "The following app-created directories will be deleted (downloaded media files are not affected):\n"),
        ("应用数据（下载暂存、aria2 会话）", "App data (download staging, aria2 session)"),
        ("缓存（URL 缓存数据库）", "Caches (URL cache database)"),
        ("日志（xspider.log 及历史）", "Logs (xspider.log and rotated history)"),

        ("引擎", "Engine"),
        ("内置引擎", "Built-in"),
        ("未找到 aria2c（brew install aria2 安装后重启应用，或改用内置引擎）", "aria2c not found (install with brew install aria2 and relaunch, or switch to Built-in engine)"),
        ("同时下载文件数", "Concurrent downloads"),
        ("单文件连接数", "Connections per file"),
        ("最小分块大小 (MB)", "Min split size (MB)"),
        ("文件分配方式", "File allocation"),
        ("预分配（推荐 HDD）", "Preallocate (HDD)"),
        ("快速分配（推荐 SSD）", "Fallocate (SSD)"),
        ("不分配", "None"),
        ("液态玻璃外观", "Liquid Glass appearance"),
        ("当前 macOS 版本低于 26（Tahoe），不支持液态玻璃，已自动使用标准材质。", "macOS below 26 (Tahoe) does not support Liquid Glass; standard materials are used."),

        ("输入用户 ID 或推文链接", "User ID or tweet link"),
        ("该推文没有媒体内容", "This tweet has no media"),
        ("推文加载失败", "Failed to load tweet"),

        ("正在加载推文…", "Loading tweet…"),

        ("搜索历史", "Search history"),
        ("暂无搜索历史", "No search history"),
        ("删除该条记录", "Remove this entry"),
        ("推文", "Tweet"),
        ("启用图片缓存", "Enable image caching"),
        ("用户头像", "User avatars"),
        ("媒体缩略图", "Media thumbnails"),
        ("缓存上限", "Cache limit"),
        ("超出上限后自动清理最旧的缓存文件。", "Oldest cached files are purged automatically when over the limit."),
        ("立即清理缓存", "Clear cache now"),
        ("已清理", "Cleared"),
        ("缓存", "Cache"),
        ("模糊度", "Blur"),
        ("调整玻璃材质的模糊与透光度，实时生效。", "Adjust the blur and translucency of glass materials. Applies instantly."),
        ("该媒体已下载过", "This media has already been downloaded"),
        ("已下载", "Downloaded"),

    ])
}

/// 重复 key 安全的字典构建（后值覆盖前值，不会 trap）
private func safeDict(_ pairs: [(String, String)]) -> [String: String] {
    var dict: [String: String] = [:]
    for (k, v) in pairs { dict[k] = v }
    return dict
}

/// 视图内便捷用法：Text(L("主页"))
func L(_ key: String) -> String {
    L10n.t(key)
}
