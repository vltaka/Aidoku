//
//  CoverAspectCache.swift
//  Aidoku
//
//  Stores the aspect ratio (width / height) of cover images once they have
//  been loaded, so waterfall layouts can size items correctly before the
//  image is shown again. Ratios are persisted across launches.
//

import UIKit

final class CoverAspectCache {
    static let shared = CoverAspectCache()
    static let didUpdateNotification = Notification.Name("CoverAspectCacheDidUpdate")

    private static let defaultsKey = "CoverAspectCache.ratios.v1"

    private var ratios: [String: CGFloat]
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        ratios = stored.mapValues { CGFloat($0) }
    }

    func aspectRatio(for url: String?) -> CGFloat? {
        guard let url else { return nil }
        return ratios[url]
    }

    func record(url: String, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let ratio = min(max(size.width / size.height, 0.2), 5)
        if let existing = ratios[url], abs(existing - ratio) < 0.01 { return }
        if ratios.count > 10000 {
            ratios.removeAll()
        }
        ratios[url] = ratio

        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(
                self.ratios.mapValues { Double($0) },
                forKey: Self.defaultsKey
            )
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)

        NotificationCenter.default.post(name: Self.didUpdateNotification, object: url)
    }
}

/// In-memory cache of cover images that have already been displayed.
/// SwiftUI cover views check this first, so when a view is recreated
/// (e.g. after the app returns from the background) the cover can be
/// shown immediately instead of flashing the placeholder.
final class CoverImageMemoryCache {
    static let shared = CoverImageMemoryCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    private func key(for url: String, downsampleWidth: CGFloat?) -> NSString {
        "\(url)|\(downsampleWidth ?? 0)" as NSString
    }

    func image(for url: String, downsampleWidth: CGFloat?) -> UIImage? {
        cache.object(forKey: key(for: url, downsampleWidth: downsampleWidth))
    }

    func store(_ image: UIImage, for url: String, downsampleWidth: CGFloat?) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key(for: url, downsampleWidth: downsampleWidth), cost: cost)
    }
}
