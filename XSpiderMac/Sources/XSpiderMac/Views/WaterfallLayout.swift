import SwiftUI

/// 瀑布流布局（masonry）：按列高最短优先放置，各列高度自然错落。
///
/// 为什么不用 LazyVGrid：网格行高由最高单元决定，其他单元必须缩小或留白；
/// 瀑布流让每张图按自身宽高比占据高度，图片无需被裁切/letterbox 到指定格子里。
/// 适用场景：不强调媒体先后顺序的浏览（主页媒体时间线）。
///
/// 测量成本：`Layout` 会测量全部子视图，因此本布局假设子视图高度是**廉价的**
/// （由媒体元数据的宽高比算出，不需要解码图片）。若子视图需要昂贵测量，请先限制条数。
struct WaterfallLayout: Layout {
    /// 列数（自适应前的最小值由调用方按宽度决定）
    var columnCount: Int
    /// 单元间距（水平与垂直相同）
    var spacing: CGFloat

    struct Placement {
        var origin: CGPoint
        var size: CGSize
    }

    func makeCache(subviews: Subviews) -> [Placement] { [] }

    func updateCache(_ cache: inout [Placement], subviews: Subviews) {
        // 子视图数量或顺序变化时失效（尺寸变化由 sizeThatFits 重算覆盖）
        if cache.count != subviews.count { cache = [] }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Placement]) -> CGSize {
        let totalWidth = proposal.width ?? 0
        guard totalWidth > 0, !subviews.isEmpty else {
            cache = []
            return CGSize(width: max(0, totalWidth), height: 0)
        }

        let cols = max(1, columnCount)
        let columnWidth = max(1, (totalWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        var columnHeights = [CGFloat](repeating: 0, count: cols)
        var placements: [Placement] = []
        placements.reserveCapacity(subviews.count)

        for subview in subviews {
            let height = max(1, subview.sizeThatFits(
                ProposedViewSize(width: columnWidth, height: nil)
            ).height)
            // 放入当前最矮的列
            var target = 0
            for i in 1..<cols where columnHeights[i] < columnHeights[target] { target = i }
            let origin = CGPoint(
                x: CGFloat(target) * (columnWidth + spacing),
                y: columnHeights[target]
            )
            placements.append(Placement(origin: origin, size: CGSize(width: columnWidth, height: height)))
            columnHeights[target] = origin.y + height + spacing
        }

        cache = placements
        let height = max(0, (columnHeights.max() ?? 0) - spacing)
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Placement]) {
        guard cache.count == subviews.count else { return }
        for (index, subview) in subviews.enumerated() {
            let placement = cache[index]
            subview.place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(width: placement.size.width, height: placement.size.height)
            )
        }
    }
}

/// 媒体瀑布流单元：按媒体自身宽高比显示，图片填满格子（宽度固定、高度随比例）。
/// 高度由元数据算出，不依赖图片解码 —— 这是瀑布流测量的廉价性前提。
struct WaterfallMediaCell: View {
    let post: TwitterPost
    let media: TwitterMedia
    /// 容器给定宽度（由布局提供）
    var onTap: () -> Void
    /// 点击放大镜 → 打开媒体查看窗口（切换范围 = 整个瀑布流）
    var onOpenViewer: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.quaternary.opacity(0.4))
                        .overlay {
                            Image(systemName: media.type == .photo ? "photo" : "video.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                }

                // 视频/GIF 时长角标（右下）
                if media.type == .video || media.type == .gif {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(media.type == .gif ? "GIF" : durationText)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(6)
                }

                // 类型标签（右上，视频/GIF；图片不显示）——静态封面看不出是不是视频
                VStack {
                    HStack {
                        Spacer()
                        MediaTypeBadge(type: media.type)
                    }
                    Spacer()
                }
                .padding(6)

                // hover：与搜索用户网格**同一套按钮**（下载/已下载 + 详细查看）。
                // 此前这里只是一个放大图标、没有下载按钮——两处行为不一致是漂移的结果，
                // 现在共用 `MediaCardActions`。
                if hovering {
                    Color.black.opacity(0.18)
                    MediaCardActions(post: post, media: media, onOpenViewer: onOpenViewer)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .aspectRatio(cellAspectRatio, contentMode: .fit)
        .onHover { hovering = $0 }
        .onTapGesture { onTap() }
        .task(id: media.id) {
            guard image == nil, let urlString = thumbnailURL else { return }
            image = await ImageCache.shared.image(for: urlString, category: .mediaThumbnails, maxPixelSize: 600)
        }
    }

    /// 宽高比：优先媒体原始尺寸，其次视频信息里的比例，兜底 1:1
    private var cellAspectRatio: CGFloat {
        if let w = media.width, let h = media.height, w > 0, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        if let ar = media.videoInfo?.aspectRatio, ar.count == 2, ar[0] > 0, ar[1] > 0 {
            return CGFloat(ar[0]) / CGFloat(ar[1])
        }
        return 1
    }

    private var thumbnailURL: String? {
        guard let urlString = media.url, let url = URL(string: urlString) else { return nil }
        guard url.path.contains("/media/") else { return urlString }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return urlString }
        var items = comps.queryItems?.filter { $0.name != "name" } ?? []
        items.append(URLQueryItem(name: "name", value: "small"))
        comps.queryItems = items
        return comps.url?.absoluteString ?? urlString
    }

    private var durationText: String {
        guard let ms = media.videoInfo?.duration else { return L("视频") }
        let total = Int(ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
