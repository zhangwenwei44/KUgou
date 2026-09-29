import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// 封面回退：拿到真实图片之前，先用能拿到的最相关的一张顶上。
///
/// 数据链路经常缺图，规则是「就近取」：
/// - 歌单 → 歌单里第一首歌的专辑图
/// - 歌手 → 该歌手热门歌里的第一张专辑图
/// - 专辑 → 歌手的一张图
/// - 歌曲 → 专辑图 → 歌手图 → 按歌名哈希的渐变
///
/// 详情页加载完曲目后调用 `register`，列表里的小图就会自动跟着变。
final class CoverResolver {
    static let shared = CoverResolver()

    private let lock = NSLock()
    private var overrides: [String: URL] = [:]
    /// 「歌名|歌手」→ 补查到的专辑图，避免同一首歌反复搜。
    private var artworkCache: [String: URL] = [:]
    /// 正在进行的补查任务，重复调用共享同一个 Task。
    private var inflight: [String: Task<URL?, Never>] = [:]

    private init() {}

    /// key 用实体的稳定 id：`kg-rank:381` / `kg:B3A5...`
    func register(_ url: URL?, for key: String) {
        guard let url else { return }
        lock.lock()
        overrides[key] = url
        lock.unlock()
    }

    func register(_ url: URL?, for keys: [String]) {
        for key in keys { register(url, for: key) }
    }

    func url(for key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[key]
    }

    /// 依次尝试每个 key 的覆盖图，返回第一个存在的。
    func firstAvailable(_ keys: [String]) -> URL? {
        for key in keys {
            if let url = url(for: key) { return url }
        }
        return nil
    }

    func reset() {
        lock.lock()
        overrides.removeAll()
        artworkCache.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        lock.unlock()
    }

    // MARK: - 缺图补查

    /// 并发闸门：一次榜单可能 20+ 首全都没图，同时打 20 多个搜索请求容易超时。
    private actor CoverLookupGate {
        private let limit: Int
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { self.limit = limit }

        func enter() async {
            if active < limit {
                active += 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func leave() {
            if waiters.isEmpty {
                active -= 1
            } else {
                let next = waiters.removeFirst()
                next()
            }
        }
    }

    private static let gate = CoverLookupGate(limit: 4)

    /// 歌曲缺封面时按「歌名 + 歌手」去酷狗搜一次，把专辑图补回来。
    ///
    /// 榜单页不带图片字段，必须走搜索才能拿到真实的歌曲自带封面。
    /// 结果按 key 缓存，重复调用共享同一个 in-flight Task，并发数由闸门限制。
    func songArtwork(title: String, artist: String) async -> URL? {
        let key = "\(title)|\(artist)"
        lock.lock()
        if let cached = artworkCache[key] {
            lock.unlock()
            return cached
        }
        if let existing = inflight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<URL?, Never> { [weak self] in
            await Self.gate.enter()
            let found = await KugouClient.shared.coverLookup(title: title, artist: artist)
            await Self.gate.leave()
            guard let self else { return found }
            self.lock.lock()
            self.inflight[key] = nil
            if let found { self.artworkCache[key] = found }
            self.lock.unlock()
            return found
        }
        inflight[key] = task
        lock.unlock()
        return await task.value
    }

    // MARK: - 从歌曲反查

    /// 绑定时顺带把每首歌自己的 key 也登记上（列表里的小图能直接命中）。
    func bind(from songs: [Song], to entities: [String]) {
        guard let cover = songs.compactMap({ $0.artworkURL }).first else { return }
        register(cover, for: entities)
        let songKeys = songs.compactMap { song -> String? in
            guard !song.kugouHash.isEmpty else { return nil }
            return "kg:\(song.kugouHash)"
        }
        register(cover, for: songKeys)
    }

    /// 歌手页：热门歌之外的专辑也用第一张图兜住。
    func bindArtist(_ artistID: String, from songs: [Song]) {
        bind(from: songs, to: [artistID])
    }
}

/// 本地导入音频时把内嵌封面抽出来存到 Caches，返回可长期引用的文件地址。
enum LocalArtwork {
    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let folder = caches.appendingPathComponent("Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }()

    /// 读音频文件的内嵌封面；没有就按歌名生成一张带首字的图。
    static func cover(for fileURL: URL, title: String) async -> URL? {
        let destination = directory.appendingPathComponent("\(stableKey(for: fileURL)).jpg")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let image = await extract(from: fileURL) ?? render(title: title)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        try? data.write(to: destination, options: .atomic)
        return destination
    }

    private static func stableKey(for url: URL) -> String {
        var hash: UInt64 = 5381
        for byte in url.path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }

    private static func extract(from fileURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            guard let value = try? await item.load(.value) else { continue }
            if let image = value as? UIImage { return image }
            if let data = value as? Data { return UIImage(data: data) }
        }
        return nil
    }

    /// 没有内嵌图时画一张：取色渐变 + 歌名首字，避免列表里全是同一个占位图。
    private static func render(title: String) -> UIImage {
        let size = CGSize(width: 300, height: 300)
        let initial = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
        return UIGraphicsImageRenderer(size: size).image { context in
            let palette = ArtworkPaletteEngine.palette(for: nil, seed: title)
            let cgColors = palette.gradient.map { UIColor($0).cgColor } as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: cgColors,
                                         locations: [0, 0.4, 0.75, 1]) {
                context.cgContext.drawLinearGradient(gradient,
                                                     start: CGPoint(x: 0, y: 0),
                                                     end: CGPoint(x: size.width, y: size.height),
                                                     options: [])
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 130, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph,
            ]
            let text = initial as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                  y: (size.height - bounds.height) / 2),
                      withAttributes: attributes)
        }
    }
}
