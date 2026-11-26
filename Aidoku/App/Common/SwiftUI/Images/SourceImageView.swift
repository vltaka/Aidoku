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

    private var lazyImage: some View {
        LazyImage(
            request: imageRequest,
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
            guard imageRequest == nil else { return }
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
        let url = URL(string: url)
        if let fileUrl = url?.toAidokuFileUrl() {
            imageRequest = ImageRequest(url: fileUrl)
            return
        }
        guard let source, let url, !url.isFileURL else {
            imageRequest = ImageRequest(url: url)
            return
        }
        imageRequest = ImageRequest(
            urlRequest: await source.getModifiedImageRequest(url: url, context: nil),
            userInfo: [.processesKey: source.features.processesCovers]
        )
    }
}
