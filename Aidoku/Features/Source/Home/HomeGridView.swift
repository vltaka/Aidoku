//
//  HomeGridView.swift
//  Aidoku
//
//  Created by Skitty on 5/27/25.
//

import AidokuRunner
import SwiftUI

struct HomeGridView: View {
    let source: AidokuRunner.Source
    let entries: [AidokuRunner.Manga]
    let containerWidth: CGFloat
    @Binding var bookmarkedItems: Set<String>
    var loadMore: (() async -> Void)?
    var onSelect: ((AidokuRunner.Manga) -> Void)?

    @State private var loadingMore = false
    // the width the layout is actually computed from. it only follows
    // containerWidth while the app is active: in the app switcher the
    // system reports a transient size/orientation for this window, and
    // laying out at that size rebuilds the grid and drops the scroll
    // position before the user even comes back
    @State private var layoutWidth: CGFloat
    @State private var columns: [GridItem]
    @State private var itemsPerRow: Int = 1
    @State private var isWaterfall = false
    private let distributionCache = WaterfallDistributionCache.shared

    @EnvironmentObject private var path: NavigationCoordinator

    static let spacing: CGFloat = OldMangaCollectionViewController.itemSpacing

    init(
        source: AidokuRunner.Source,
        entries: [AidokuRunner.Manga],
        containerWidth: CGFloat,
        bookmarkedItems: Binding<Set<String>> = .constant([]),
        loadMore: (() async -> Void)? = nil,
        onSelect: ((AidokuRunner.Manga) -> Void)? = nil
    ) {
        self.source = source
        self.entries = entries
        self.containerWidth = containerWidth
        self._layoutWidth = State(initialValue: containerWidth)
        self._bookmarkedItems = bookmarkedItems
        self.loadMore = loadMore
        self.onSelect = onSelect
        self._columns = State(initialValue: Self.getColumns(itemsPerRow: 1))
    }

    private static var isLandscape: Bool {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let orientation = if #available(iOS 16.0, *) {
            scene?.effectiveGeometry.interfaceOrientation
        } else {
            scene?.interfaceOrientation
        }
        return orientation?.isLandscape ?? false
    }

    private static func getColumns(itemsPerRow: Int) -> [GridItem] {
        (0..<itemsPerRow).map { _ in GridItem(.flexible(), spacing: Self.spacing) }
    }

    var body: some View {
        Group {
            if isWaterfall {
                waterfallBody
            } else {
                LazyVGrid(
                    columns: columns,
                    spacing: Self.spacing
                ) {
                    ForEach(entries.indices, id: \.self) { index in
                        mangaGridItem(entry: entries[index])
                    }
                    loadMoreView
                }
                .padding([.horizontal, .bottom])
            }
        }
        .onAppear {
            updateItemsPerRow()
        }
        .onChange(of: entries) { _ in
            loadingMore = false
        }
        .onChange(of: containerWidth) { width in
            guard UIApplication.shared.applicationState == .active else {
                return
            }
            layoutWidth = width
            updateItemsPerRow()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // fixes bug where item per row is incorrect when closing and opening app
            layoutWidth = containerWidth
            updateItemsPerRow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .orientationDidChange)) { _ in
            updateItemsPerRow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init(AppSettings.appearance.layout.key))) { _ in
            updateItemsPerRow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init(AppSettings.appearance.customPortraitRows.key))) { _ in
            updateItemsPerRow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init(AppSettings.appearance.customLandscapeRows.key))) { _ in
            updateItemsPerRow()
        }
        .onChange(of: itemsPerRow) { newValue in
            columns = Self.getColumns(itemsPerRow: newValue)
        }
    }

    private var waterfallBody: some View {
        let columnCount = max(1, itemsPerRow)
        let horizontalPadding: CGFloat = 16
        let itemWidth = max(
            0,
            (layoutWidth - horizontalPadding * 2 - CGFloat(columnCount - 1) * Self.spacing) / CGFloat(columnCount)
        )
        // freeze the distribution (and the ratios it assumed) for a given
        // set of entries, so covers never change places once shown. the
        // signature covers every entry key plus the exact item width, and
        // the cache is shared, so a transient state (a refresh passing
        // through, the view being rebuilt) can never reshuffle items
        // that are already on screen
        var signatureHasher = Hasher()
        for entry in entries { signatureHasher.combine(entry.key) }
        let signature = "\(entries.count)|\(columnCount)|\(Int(itemWidth.rounded()))|\(signatureHasher.finalize())"
        let distribution = distributionCache.distribution(key: "home-\(source.key)", signature: signature) {
            var ratios: [String: CGFloat] = [:]
            let result = WaterfallDistributor.distribute(count: entries.count, columns: columnCount) { index in
                let entry = entries[index]
                let ratio = CoverAspectCache.shared.aspectRatio(for: entry.cover) ?? (2.0 / 3.0)
                ratios[entry.key] = ratio
                return itemWidth / ratio + WaterfallItemMetrics.textHeight(
                    title: entry.title,
                    tags: entry.tags ?? [],
                    width: itemWidth
                )
            }
            distributionCache.setValues(ratios, for: "home-\(source.key)")
            return result
        }
        let frozenRatios = distributionCache.values(for: "home-\(source.key)") ?? [:]
        return VStack(spacing: Self.spacing) {
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(distribution.indices, id: \.self) { column in
                    LazyVStack(spacing: Self.spacing) {
                        ForEach(distribution[column], id: \.self) { index in
                            mangaWaterfallItem(
                                entry: entries[index],
                                itemWidth: itemWidth,
                                aspectRatio: frozenRatios[entries[index].key] ?? (2.0 / 3.0)
                            )
                        }
                    }
                    .frame(width: itemWidth)
                }
            }
            loadMoreView
        }
        .padding([.horizontal, .bottom])
    }

    private func mangaWaterfallItem(entry: AidokuRunner.Manga, itemWidth: CGFloat, aspectRatio: CGFloat) -> some View {
        let inLibrary = bookmarkedItems.contains(entry.key)
        return Button {
            if let onSelect {
                onSelect(entry)
            } else {
                path.push(MangaViewController(source: source, manga: entry, parent: path.rootViewController))
            }
        } label: {
            MangaWaterfallGridItem(
                source: source,
                title: entry.title,
                coverImage: entry.cover ?? "",
                bookmarked: inLibrary,
                aspectRatio: aspectRatio,
                tags: entry.tags ?? [],
                language: CoverLanguageBadge.text(for: source),
                itemWidth: itemWidth
            )
        }
        .buttonStyle(MangaGridButtonStyle())
        .contextMenu {
            if entry.isLocal() {
                Button(role: .destructive) {
                    Task {
                        await LocalFileManager.shared.removeManga(with: entry.key)
                        NotificationCenter.default.post(name: .init("refresh-content"), object: nil)
                    }
                } label: {
                    Label(NSLocalizedString("REMOVE"), systemImage: "trash")
                }
            }
            if inLibrary {
                Button(role: .destructive) {
                    bookmarkedItems.remove(entry.key)
                    Task {
                        await MangaManager.shared.removeFromLibrary(mangaId: entry.identifier)
                    }
                } label: {
                    Label(NSLocalizedString("REMOVE_FROM_LIBRARY"), systemImage: "trash")
                }
            } else {
                Button {
                    Task {
                        if await MangaManager.shouldAskForCategories() {
                            let viewController = UINavigationController(rootViewController: CategorySelectViewController(manga: entry))
                            path.present(viewController)
                        } else {
                            bookmarkedItems.insert(entry.key)
                            await MangaManager.shared.addToLibrary(
                                manga: entry,
                                fetchMangaDetails: true
                            )
                        }
                    }
                } label: {
                    Label(NSLocalizedString("ADD_TO_LIBRARY"), systemImage: "plus.circle")
                }
            }
        }
        .id(entry.key)
    }

    private func mangaGridItem(entry: AidokuRunner.Manga) -> some View {
        let inLibrary = bookmarkedItems.contains(entry.key)
        return Button {
            if let onSelect {
                onSelect(entry)
            } else {
                path.push(MangaViewController(source: source, manga: entry, parent: path.rootViewController))
            }
        } label: {
            MangaGridItem(
                source: source,
                title: entry.title,
                coverImage: entry.cover ?? "",
                bookmarked: inLibrary
            )
        }
        .buttonStyle(MangaGridButtonStyle())
        .contextMenu {
            // add a remove button for manga from the local source
            if entry.isLocal() {
                Button(role: .destructive) {
                    Task {
                        await LocalFileManager.shared.removeManga(with: entry.key)
                        NotificationCenter.default.post(name: .init("refresh-content"), object: nil)
                    }
                } label: {
                    Label(NSLocalizedString("REMOVE"), systemImage: "trash")
                }
            }
            if inLibrary {
                Button(role: .destructive) {
                    bookmarkedItems.remove(entry.key)
                    Task {
                        await MangaManager.shared.removeFromLibrary(mangaId: entry.identifier)
                    }
                } label: {
                    Label(NSLocalizedString("REMOVE_FROM_LIBRARY"), systemImage: "trash")
                }
            } else {
                Button {
                    Task {
                        if await MangaManager.shouldAskForCategories() {
                            // open category select view
                            let viewController = UINavigationController(rootViewController: CategorySelectViewController(manga: entry))
                            path.present(viewController)
                        } else {
                            // add to library
                            bookmarkedItems.insert(entry.key)
                            await MangaManager.shared.addToLibrary(
                                manga: entry,
                                fetchMangaDetails: true
                            )
                        }
                    }
                } label: {
                    Label(NSLocalizedString("ADD_TO_LIBRARY"), systemImage: "plus.circle")
                }
            }
        }
        .id(entry.key)
    }

    @ContentBuilder
    var loadMoreView: some View {
        if !loadingMore, !entries.isEmpty, let loadMore {
            Spacer()
                .onAppear {
                    loadingMore = true
                    Task {
                        await loadMore()
                    }
                }
        } else {
            EmptyView()
        }
    }

    func updateItemsPerRow(width: CGFloat? = nil) {
        // never relayout while the app isn't active (see layoutWidth);
        // the didBecomeActive handler re-runs this with the real size
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        let layout = AppSettings.appearance.layout.get()
        let newIsWaterfall = layout == .waterfall
        let landscape = Self.isLandscape
        let effectiveWidth = width ?? layoutWidth
        let newItemsPerRow = OldMangaCollectionViewController.getGridItemsPerRow(
            containerWidth: effectiveWidth,
            isLandscape: landscape,
            layout: layout
        )
        // only touch the state when the result actually changed: assigning
        // the same values still invalidates the view, and a grid rebuilt
        // for no reason makes the scroll view drop its position (the page
        // lands back at the top after returning from the background)
        guard newItemsPerRow != itemsPerRow || newIsWaterfall != isWaterfall else { return }
        isWaterfall = newIsWaterfall
        itemsPerRow = newItemsPerRow
    }

    static func placeholder(width: CGFloat, availableWidth: CGFloat? = nil) -> some View {
        Placeholder(containerWidth: width, availableWidth: availableWidth ?? width)
    }

    private struct Placeholder: View {
        let containerWidth: CGFloat
        let availableWidth: CGFloat

        private var itemsPerRow: Int {
            OldMangaCollectionViewController.getGridItemsPerRow(
                containerWidth: containerWidth,
                isLandscape: HomeGridView.isLandscape,
                layout: AppSettings.appearance.layout.get()
            )
        }

        var body: some View {
            let itemCount = 30
            let itemsPerRow = itemsPerRow
            let containerPadding: CGFloat = 16
            let itemWidth = max(0, (availableWidth - containerPadding * 2 - CGFloat(itemsPerRow - 1) * HomeGridView.spacing) / CGFloat(itemsPerRow))

            VStack(alignment: .leading, spacing: HomeGridView.spacing) {
                let rowCount = (itemCount + itemsPerRow - 1) / itemsPerRow
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: HomeGridView.spacing) {
                        ForEach(0..<itemsPerRow, id: \.self) { column in
                            if row * itemsPerRow + column < itemCount {
                                MangaGridItem.placeholder
                                    .frame(width: itemWidth, height: itemWidth * 3 / 2)
                                    .clipped()
                            }
                        }
                    }
                }
            }
            .shimmering()
            .padding([.horizontal, .bottom])
        }
    }
}
