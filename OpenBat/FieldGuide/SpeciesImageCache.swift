//
//  SpeciesImageCache.swift
//  OpenBat
//
//  Disk cache for field-guide species photos.
//
//  Guide photos are arbitrary remote URLs — every current entry happens to be
//  Wikimedia, but `imageURL` is a free-text field a contributor fills in, so
//  nothing guarantees the host. They also point at *originals*: one live entry
//  (Big Brown Bat) is a 10 MB PNG being drawn into a 260pt hero. Plain
//  `AsyncImage` re-downloads that through the small shared `URLCache`, and
//  upload.wikimedia.org sends neither `Cache-Control` nor `Expires`, so even
//  that hit rate rests on URLCache's heuristic freshness rather than anything
//  the server promised.
//
//  So each photo is fetched once and kept as a *downscaled, re-encoded
//  derivative* — the original bytes are never stored. Two mechanisms, because
//  they solve different halves of the problem:
//
//    1. `wikimediaThumbnailURL` rewrites a Commons original to Commons' own
//       pre-rendered thumbnail. Host-specific, but the only one that saves the
//       *download* rather than just the disk.
//    2. Local downscale + JPEG re-encode at cache-write time. Works for any
//       host, but only after the full original has come over the air.
//
//  Licensing: resizing and re-encoding for display is a technical modification
//  under CC 4.0 §2(a)(4), which the licensor grants outright and which
//  explicitly does not produce Adapted Material — so it trips neither
//  ShareAlike nor NoDerivatives. Nothing is distributed either way: these
//  derivatives never leave the device. Attribution is unaffected because the
//  credit is rendered from `imageCredit` in the guide JSON, not from anything
//  embedded in the image (re-encoding does drop EXIF/IPTC, which is why the
//  credit living outside the bytes matters). If these derivatives are ever
//  shipped *inside* the app bundle, that becomes distribution and this
//  reasoning has to be revisited.
//

import SwiftUI
import UIKit
import ImageIO
import CryptoKit

/// Longest edge, in pixels, that a cached derivative is downscaled to.
/// Deliberately coarse — two tiers cover every call site, and each extra tier
/// is a whole second copy of every photo on disk.
enum SpeciesImageSize: Int, CaseIterable {
    /// Row thumbnails (50pt) and grid cards (~190pt) — 400px covers the card
    /// at 2x with room to spare.
    case thumbnail = 400
    /// The full-bleed detail-page hero at 260pt tall on the widest iPad.
    case hero = 1200
}

actor SpeciesImageCache {
    static let shared = SpeciesImageCache()

    /// Total budget for derivatives on disk. At ~150-250 KB each this is
    /// thousands of photos — the cap exists to bound a pathological guide, not
    /// to ration the current 19 species.
    private static let maxCacheBytes: Int64 = 128 * 1024 * 1024

    /// JPEG rather than HEIC: marginally larger, but decodable by anything and
    /// with no encoder-availability caveat. Quality 0.8 is the usual knee —
    /// visually indistinguishable at these sizes, a fraction of the bytes.
    private static let jpegQuality: CGFloat = 0.8

    /// Decoded images, so a scroll back up a list doesn't re-read and re-decode
    /// from disk. Bounded by count rather than bytes; `UIImage`'s own cost
    /// accounting for a JPEG is unreliable enough that a byte limit would be
    /// guesswork either way.
    private let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        return c
    }()

    /// Dedupes concurrent requests for the same photo — a list and its
    /// prefetch can both ask for one row's thumbnail in the same frame, and
    /// without this each starts its own download.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    /// On-demand fetches: the user is looking at this page right now, so any
    /// network is fair game.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = ["User-Agent": SpeciesImageCache.userAgent]
        return URLSession(configuration: cfg)
    }()

    /// Speculative fetches for photos nobody has asked to see. Cellular is
    /// allowed: data allowances are generous enough now that withholding a few
    /// MB of thumbnails mainly hurts the case the preload exists for — someone
    /// opening the app on the way out, with the guide they'll want offline
    /// later still unfetched.
    ///
    /// Low Data Mode is still honoured (`allowsConstrainedNetworkAccess =
    /// false`), because that one isn't a guess about the user's plan — it's the
    /// user having said, explicitly, not to do exactly this.
    private static let preloadSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.allowsConstrainedNetworkAccess = false
        cfg.waitsForConnectivity = false
        // Wikimedia answers a burst of parallel requests with 429s (measured
        // while sizing these photos), and a preload has no deadline worth
        // risking that for.
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.httpAdditionalHeaders = ["User-Agent": SpeciesImageCache.userAgent]
        return URLSession(configuration: cfg)
    }()

    /// Wikimedia's User-Agent policy requires a descriptive agent for non-WMF
    /// clients — same string `WikipediaSpeciesImageService` sends.
    private static let userAgent =
        "OpenBat/1.0 (https://github.com/search?q=OpenBat+bat+detector; open-source, non-commercial iOS app)"

    /// Application Support, not Caches, and deliberately so: this app is used
    /// in a field at night with no signal, and Caches is exactly what iOS
    /// purges under disk pressure — which would drop every photo at the moment
    /// they can't be re-fetched. Excluded from backup below, since it is all
    /// re-downloadable; the point is only that *iOS* doesn't get to decide when.
    private static let directory: URL = {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeciesImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    // MARK: Lookup

    /// The cached derivative for `url` at `size`, fetching and building it if
    /// this is the first time it's been asked for. Returns nil rather than
    /// throwing — every call site's fallback is the same placeholder either way.
    func image(for url: URL, size: SpeciesImageSize) async -> UIImage? {
        let key = Self.key(for: url, size: size)
        if let hit = memory.object(forKey: key as NSString) { return hit }

        if let existing = inFlight[key] { return await existing.value }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            if let onDisk = await Self.readFromDisk(key: key) {
                await self.store(onDisk, key: key)
                return onDisk
            }
            guard let data = await Self.download(url, size: size, using: Self.session),
                  let derivative = Self.downscale(data, to: size)
            else { return nil }
            Self.writeToDisk(derivative.data, key: key)
            await self.store(derivative.image, key: key)
            return derivative.image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func store(_ image: UIImage, key: String) {
        memory.setObject(image, forKey: key as NSString)
    }

    // MARK: Preload

    /// Warms the cache for photos nobody has opened yet. Only ever called with
    /// URLs already known locally — the guide's own `imageURL`s plus Wikipedia
    /// lookups resolved on a previous run — so this never triggers a live
    /// Wikipedia API call, only the image fetches themselves.
    ///
    /// Wi-Fi only, three at a time, and a no-op for anything already cached.
    func preload(_ urls: [URL], size: SpeciesImageSize) async {
        let pending = urls.filter { url in
            let key = Self.key(for: url, size: size)
            return memory.object(forKey: key as NSString) == nil
                && !FileManager.default.fileExists(atPath: Self.path(for: key).path)
        }
        guard !pending.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var next = pending.makeIterator()
            var running = 0
            while running < 3, let url = next.next() {
                group.addTask { await Self.preloadOne(url, size: size) }
                running += 1
            }
            while await group.next() != nil {
                if let url = next.next() {
                    group.addTask { await Self.preloadOne(url, size: size) }
                }
            }
        }
    }

    /// Writes straight to disk without touching the memory cache — a preloaded
    /// photo is one nobody is looking at, so holding a decoded copy in memory
    /// would evict images that *are* on screen.
    private static func preloadOne(_ url: URL, size: SpeciesImageSize) async {
        guard let data = await download(url, size: size, using: preloadSession),
              let derivative = downscale(data, to: size)
        else { return }
        writeToDisk(derivative.data, key: key(for: url, size: size))
    }

    // MARK: Housekeeping

    /// Drops derivatives for photos the guide no longer references, then
    /// enforces the size cap oldest-first.
    ///
    /// This is what runs on a guide `dataVersion` bump — a *sweep*, not a
    /// flush. Photos aren't derived from the guide JSON, they're independent
    /// URLs it happens to list, so clearing them because a habits field gained
    /// a comma would re-download every photo for nothing. A contributor
    /// swapping an `imageURL` needs no invalidation at all: the new URL is a
    /// different key and simply misses, and this call is what eventually
    /// collects the file the old one left behind.
    func sweep(keeping urls: [URL]) {
        let live = Set(SpeciesImageSize.allCases.flatMap { size in
            urls.map { Self.key(for: $0, size: size) }
        })
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: Self.directory,
                                                      includingPropertiesForKeys: keys)
        else { return }

        var survivors: [(url: URL, date: Date, size: Int64)] = []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            if !live.contains(name) {
                try? fm.removeItem(at: file)
                continue
            }
            let values = try? file.resourceValues(forKeys: Set(keys))
            survivors.append((file,
                              values?.contentModificationDate ?? .distantPast,
                              Int64(values?.fileSize ?? 0)))
        }

        var total = survivors.reduce(Int64(0)) { $0 + $1.size }
        guard total > Self.maxCacheBytes else { return }
        for victim in survivors.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: victim.url)
            total -= victim.size
            if total <= Self.maxCacheBytes { break }
        }
    }

    // MARK: Wikimedia thumbnails

    /// Widths Wikimedia will actually serve to a direct (hotlinked) request.
    /// Arbitrary widths are rejected outright with a 400 — a rule tightened in
    /// production under T414805, and one that silently costs you the whole
    /// optimisation if you don't honour it: the fetch falls back to the
    /// original, so a wrong width shows up as "the photo still works, it's just
    /// still 10 MB" rather than as a visible failure. Verified against live
    /// Commons: 400px and 1200px both 400, 500px and 1280px both fine.
    private static let standardThumbnailWidths = [20, 40, 60, 120, 250, 330, 500, 960, 1280, 1920, 3840]

    /// Rewrites a Wikimedia Commons *original* to Commons' own pre-rendered
    /// thumbnail, at the smallest standard width that still covers
    /// `maxPixelSize`:
    ///
    ///   /wikipedia/commons/6/6c/Foo.png
    ///     -> /wikipedia/commons/thumb/6/6c/Foo.png/1280px-Foo.png
    ///
    /// The served width is therefore usually a little larger than the tier
    /// being cached, which is fine — the local downscale takes it the rest of
    /// the way to an exact size, and the saving being chased here is the
    /// download, not the last few hundred pixels.
    ///
    /// Returns nil for anything that isn't a Commons original — a different
    /// host, an already-thumbnailed URL, or a path that doesn't match the
    /// `/<project>/<x>/<xy>/<file>` shape. Callers fall back to the URL as
    /// given, so an unrecognised host costs nothing but the bigger download.
    ///
    /// Query strings are dropped: several live entries carry `utm_*` tracking
    /// params copied out of the Commons UI, which the thumbnail path doesn't
    /// want and which would otherwise fragment the cache key for one photo.
    static func wikimediaThumbnailURL(for url: URL, maxPixelSize: Int) -> URL? {
        guard url.host == "upload.wikimedia.org" else { return nil }
        let width = standardThumbnailWidths.first { $0 >= maxPixelSize } ?? standardThumbnailWidths.last!
        let parts = url.path.split(separator: "/").map(String.init)
        // ["wikipedia", "commons", "6", "6c", "Foo.png"]
        guard parts.count == 5, parts.first == "wikipedia", parts[2] != "thumb" else { return nil }
        let file = parts[4]

        // Commons renders vector and multi-page sources to PNG, so the
        // thumbnail keeps the source extension *and* gains .png.
        let ext = (file as NSString).pathExtension.lowercased()
        let rendersToPNG = ["svg", "pdf", "djvu", "tif", "tiff"].contains(ext)
        let thumbName = "\(width)px-\(file)\(rendersToPNG ? ".png" : "")"

        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.path = "/wikipedia/\(parts[1])/thumb/\(parts[2])/\(parts[3])/\(file)/\(thumbName)"
        return components.url
    }

    // MARK: Fetch / transform / disk

    /// Tries the Commons thumbnail first and falls back to the original on any
    /// non-200 — a rewrite that guesses wrong (an extension Commons renders
    /// differently, a file with no thumbnail) degrades to the old behaviour
    /// instead of losing the photo.
    private static func download(_ url: URL, size: SpeciesImageSize, using session: URLSession) async -> Data? {
        if let thumb = wikimediaThumbnailURL(for: url, maxPixelSize: size.rawValue),
           let data = await fetch(thumb, using: session) {
            return data
        }
        return await fetch(url, using: session)
    }

    private static func fetch(_ url: URL, using session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = session.configuration.timeoutIntervalForRequest
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return data
    }

    /// Decodes straight to the target size via ImageIO rather than loading the
    /// full image and shrinking it — `kCGImageSourceThumbnailMaxPixelSize`
    /// never materialises the full-resolution bitmap, which for the 10 MB PNG
    /// is the difference between a few MB of peak memory and a few hundred.
    private static func downscale(_ data: Data, to size: SpeciesImageSize) -> (image: UIImage, data: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
            // Decode once, here, off the main thread — otherwise the first
            // draw of every photo pays for it during a scroll.
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cgImage)

        // JPEG has no alpha channel, and encoding a transparent source to it
        // composites the transparent areas to black rather than failing — a
        // silent visual bug in a photo nobody would think to re-check. No
        // current guide entry has alpha (checked), but `imageURL` is a
        // free-text field, so fall back to PNG for the ones that do. Costs
        // more bytes, on the rare entry where correctness needs them.
        let hasAlpha: Bool
        switch cgImage.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            hasAlpha = true
        default:
            hasAlpha = false
        }
        guard let encoded = hasAlpha ? image.pngData()
                                     : image.jpegData(compressionQuality: jpegQuality)
        else { return nil }
        return (image, encoded)
    }

    private static func readFromDisk(key: String) async -> UIImage? {
        let file = path(for: key)
        guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { return nil }
        // Touch it so the size-cap eviction in `sweep` treats "recently viewed"
        // as recently used, rather than evicting by download date forever.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
    }

    private static func writeToDisk(_ data: Data, key: String) {
        try? data.write(to: path(for: key), options: .atomic)
    }

    /// A neutral extension rather than `.jpg`, because the encoding depends on
    /// whether the source had alpha (see `downscale`). Nothing reads these by
    /// extension — `UIImage(data:)` sniffs the container — so the honest name
    /// is the one that doesn't claim a format the file might not be.
    private static func path(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("img")
    }

    /// Keyed on the URL *as the guide gives it*, not the rewritten thumbnail —
    /// so whether the Commons rewrite applied, and whether it later stops
    /// applying, doesn't change where a photo lands.
    private static func key(for url: URL, size: SpeciesImageSize) -> String {
        let input = Data("\(url.absoluteString)|\(size.rawValue)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

/// Drop-in replacement for the `AsyncImage` the guide used to draw photos
/// with, backed by `SpeciesImageCache` instead of the shared `URLCache`.
///
/// Deliberately not a general-purpose image view: it takes a
/// `SpeciesImageSize` rather than sizing itself, because the whole point is
/// that the cached derivative is built once at a known size. Every call site
/// keeps its own placeholder — a silhouette tile in the lists, flat grey
/// behind the hero — so that stays a parameter.
struct CachedSpeciesImage<Placeholder: View>: View {
    let url: URL?
    let size: SpeciesImageSize
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        // Keyed on the URL so a recycled row rebuilding with a different
        // species drops the previous photo instead of showing it under the new
        // name until the replacement lands.
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await SpeciesImageCache.shared.image(for: url, size: size)
        }
    }
}
