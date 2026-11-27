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
    // the url the current imageRequest was built for; the image on
    // screen may only be recorded under the current url while the two
    // agree — see the write in the lazy image's content below
    @State private var imageRequestUrl: String?
    // the last image this view actually displayed, kept in the view's own
    // state so a re-render (e.g. the multitasking snapshot pass) can draw
    // it synchronously instead of falling back to the placeholder. The pin
    // is labelled with the url it belongs to: when a view instance is
    // reused for a different manga (positional identity in lists and
    // hosting cells), an unlabelled pin kept painting the previous
    // manga's cover into the new cell, and since the lazy image below
    // wasn't in the tree while the pin was shown, nothing ever replaced
    // it — the cover stayed wrong until the view was thrown away.
    @State private var pinnedImage: UIImage?
    @State private var pinnedImageUrl: String?

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
        // a recreated view doesn't flash the placeholder either. The pin
        // only counts while it still belongs to the current url — a pin
        // from a previous manga falls through to the lazy image, which
        // then loads the cover this view is actually for.
        if let pinnedImage, pinnedImageUrl == imageUrl {
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
                        // record the displayed image under the current
                        // url only if it really came from a request for
                        // that url. When this view is reused for another
                        // manga (home lists identify rows by position),
                        // there is a pass where the url is already the
                        // new manga's while the request — and the image
                        // still on screen — is the previous manga's;
                        // recording then would file the previous cover
                        // under the new url in the pin and both shared
                        // caches, and since those are checked before any
                        // real load, the wrong cover would never correct
                        // itself. A request taken from the shared
                        // request cache is keyed by this url, so it
                        // counts as belonging to it (imageRequest nil).
                        if let container = state.imageContainer,
                           imageRequest == nil || imageRequestUrl == imageUrl {
                            pinnedImage = container.image
                            pinnedImageUrl = imageUrl
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
            imageRequestUrl = nil
            pinnedImage = nil
            pinnedImageUrl = nil
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
            imageRequestUrl = url
            CoverRequestCache.shared.store(request, sourceKey: source?.key, url: url)
            return
        }
        guard let source, let urlObject, !urlObject.isFileURL else {
            imageRequest = ImageRequest(url: urlObject)
            imageRequestUrl = url
            return
        }
        let request = ImageRequest(
            urlRequest: await source.getModifiedImageRequest(url: urlObject, context: nil),
            userInfo: [.processesKey: source.features.processesCovers]
        )
        CoverRequestCache.shared.store(request, sourceKey: source.key, url: url)
        // this view may have been reused for a different cover while the
        // request was being built; a stale request completing late must
        // never paint the previous manga's cover into the new cell
        // (covers landing in the wrong places after views rebuild)
        guard imageUrl == url else { return }
        imageRequest = request
        imageRequestUrl = url
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
