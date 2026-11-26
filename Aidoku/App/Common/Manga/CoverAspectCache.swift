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
///
/// This deliberately does not use NSCache: the system purges NSCache
/// contents while the app is in the background, which is exactly when
/// these images are needed (the multitasking snapshot is rendered from
/// a fresh view pass). A plain dictionary with a manual LRU cap is
/// only evicted by the limits below or by the app terminating.
final class CoverImageMemoryCache {
    static let shared = CoverImageMemoryCache()

    private let lock = NSLock()
    private var images: [NSString: UIImage] = [:]
    private var costs: [NSString: Int] = [:]
    private var order: [NSString] = [] // least recently used first
    private var totalCost = 0

    private let countLimit = 500
    private let costLimit = 96 * 1024 * 1024

    private init() {}

    private func key(for url: String, downsampleWidth: CGFloat?) -> NSString {
        "\(url)|\(downsampleWidth ?? 0)" as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    func image(for url: String, downsampleWidth: CGFloat?) -> UIImage? {
        let key = key(for: url, downsampleWidth: downsampleWidth)
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    func store(_ image: UIImage, for url: String, downsampleWidth: CGFloat?) {
        let key = key(for: url, downsampleWidth: downsampleWidth)
        let cost = Self.cost(of: image)
        lock.lock()
        defer { lock.unlock() }
        if let oldCost = costs[key] {
            totalCost -= oldCost
            order.removeAll { $0 == key }
        }
        images[key] = image
        costs[key] = cost
        totalCost += cost
        order.append(key)

        while images.count > countLimit || totalCost > costLimit, let victim = order.first {
            order.removeFirst()
            if let victimCost = costs.removeValue(forKey: victim) {
                totalCost -= victimCost
            }
            images.removeValue(forKey: victim)
        }
    }
}
