//
//  SourceImageView.swift
//  Aidoku
//
//  Created by Skitty on 4/26/25.
//

import AidokuRunner
import Nuke
import NukeUI
import SwiftUI

struct SourceImageView: View {
    var source: AidokuRunner.Source?

    let imageUrl: String
    var width: CGFloat?
    var height: CGFloat?
    var downsampleWidth: CGFloat?
    var contentMode: ContentMode = .fill
    var placeholder = "MangaPlaceholder"

    @State private var imageRequest: ImageRequest?
    // the last image this view actually displayed, kept in the view's own
    // state so a re-render (e.g. the multitasking snapshot pass) can draw
    // it synchronously instead of falling back to the placeholder
    @State private var pinnedImage: UIImage?

    private var processors: [ImageProcessing] {
        var processors: [ImageProcessing] = []
        if let downsampleWidth {
            processors.append(DownsampleProcessor(width: downsampleWidth))
        }
        if let source, source.features.processesCovers {
            processors.append(CoverInterceptorProcessor(source: source))
        }
        return processors
    }

    var body: some View {
        // if this view already showed the cover, draw the pinned image
        // synchronously; otherwise fall back to the shared memory cache so
        // a recreated view doesn't flash the placeholder either
        if let pinnedImage {
            Image(uiImage: pinnedImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(width: width, height: height)
        } else if let cachedImage = CoverImageMemoryCache.shared.image(for: imageUrl, downsampleWidth: downsampleWidth) {
            Image(uiImage: cachedImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(width: width, height: height)
        } else {
            lazyImage
        }
    }

    /// The request for this cover: the one built for this view, or the
    /// shared one an earlier view already built for the same cover, so a
    /// recreated view can ask the image cache for its cover immediately
    /// instead of waiting for the async request-building hop first (that
    /// hop is what made already-loaded covers flash the placeholder when
    /// scrolling back).
    private var effectiveRequest: ImageRequest? {
        imageRequest ?? CoverRequestCache.shared.request(sourceKey: source?.key, url: imageUrl)
    }

    private var lazyImage: some View {
        LazyImage(
            request: effectiveRequest,
            transaction: .init(animation: .default)
        ) { state in
            if state.imageContainer?.type == .gif, let data = state.imageContainer?.data {
                GIFImage(
                    data: data,
                    contentMode: contentMode
                )
                    .frame(width: width, height: height)
                    .id(state.image != nil ? imageUrl : "placeholder") // ensures only opacity is animated
            } else {
                let result = if let image = state.image {
                    image
                } else {
                    Image(placeholder)
                }
                result
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: width, height: height)
                    .id(state.image != nil ? imageUrl : "placeholder") // ensures only opacity is animated
                    .onAppear {
                        if let container = state.imageContainer {
                            pinnedImage = container.image
                            CoverImageMemoryCache.shared.store(
                                container.image,
                                for: imageUrl,
                                downsampleWidth: downsampleWidth
                            )
                            CoverAspectCache.shared.record(url: imageUrl, size: container.image.size)
                        }
                    }
            }
        }
        .processors(processors)
        .onAppear {
            guard imageRequest == nil, effectiveRequest == nil else { return }
            Task {
                await loadImageRequest(url: imageUrl)
            }
        }
        .onChange(of: imageUrl) { newValue in
            imageRequest = nil
            pinnedImage = nil
            Task {
                await loadImageRequest(url: newValue)
            }
        }
    }

    func loadImageRequest(url: String) async {
        let urlObject = URL(string: url)
        if let fileUrl = urlObject?.toAidokuFileUrl() {
            let request = ImageRequest(url: fileUrl)
            imageRequest = request
            CoverRequestCache.shared.store(request, sourceKey: source?.key, url: url)
            return
        }
        guard let source, let urlObject, !urlObject.isFileURL else {
            imageRequest = ImageRequest(url: urlObject)
            return
        }
        let request = ImageRequest(
            urlRequest: await source.getModifiedImageRequest(url: urlObject, context: nil),
            userInfo: [.processesKey: source.features.processesCovers]
        )
        imageRequest = request
        CoverRequestCache.shared.store(request, sourceKey: source.key, url: url)
    }
}

/// Image requests already built for covers, shared across views.
/// Building a request can require an async round-trip through the
/// source, so a cover view recreated while scrolling shouldn't have to
/// wait for that before it can even ask the image cache for its cover.
/// Entries expire after ten minutes so a source handing out signed,
/// short-lived cover URLs still gets fresh requests regularly.
final class CoverRequestCache {
    static let shared = CoverRequestCache()

    private let lock = NSLock()
    private var requests: [String: (request: ImageRequest, storedAt: Date)] = [:]
    private let lifetime: TimeInterval = 600

    private func key(sourceKey: String?, url: String) -> String {
        "\(sourceKey ?? "")|\(url)"
    }

    func request(sourceKey: String?, url: String) -> ImageRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = requests[key(sourceKey: sourceKey, url: url)] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < lifetime else { return nil }
        return entry.request
    }

    func store(_ request: ImageRequest, sourceKey: String?, url: String) {
        lock.lock()
        defer { lock.unlock() }
        if requests.count > 1000 { requests.removeAll() }
        requests[key(sourceKey: sourceKey, url: url)] = (request, Date())
    }
}
