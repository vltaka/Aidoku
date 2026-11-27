//
//  HomeListView.swift
//  Aidoku
//
//  Created by Skitty on 10/13/23.
//

import AidokuRunner
import SafariServices
import SwiftUI

/// Identity for one home component entry, so a row's view state follows
/// its manga when a list reloads instead of staying bound to the row's
/// position. Position-bound state is what let a reloaded list keep the
/// previous entry's cover view (and its image state) on a new entry.
func homeEntryIdentity(_ entry: HomeComponent.Value.Link) -> String {
    switch entry.value {
        case .manga(let manga): "manga:\(manga.key)"
        case .url(let urlString): "url:\(urlString)"
        case .listing(let listing): "listing:\(listing.name)"
    }
}

/// The identities for a whole component, parallel to its entries;
/// repeats of the same entry get a suffix so ids stay unique within
/// the list.
func homeEntryIdentities(_ entries: [HomeComponent.Value.Link]) -> [String] {
    var counts: [String: Int] = [:]
    return entries.map { entry in
        let base = homeEntryIdentity(entry)
        let occurrence = counts[base, default: 0]
        counts[base] = occurrence + 1
        return occurrence == 0 ? base : "\(base)#\(occurrence)"
    }
}

struct HomeListView: View {
    let source: AidokuRunner.Source
    let component: HomeComponent
    let partial: Bool
    @Binding var bookmarkedItems: Set<String>
    var loadMore: (() async -> Void)?
    var onSelect: ((AidokuRunner.Manga) -> Void)?

    private let ranking: Bool
    private let pageSize: Int?
    private let entries: [HomeComponent.Value.Link]
    private let listing: AidokuRunner.Listing?

    private let usesBookmarksState: Bool

    @State private var loadingMore = false
    @State private var bookmarkedItemsState: Set<String> = .init()
    @State private var loadedBookmarks: Bool
    @State private var coverHeight: CGFloat = 100
    @State private var coverFit: Bool = false

    @EnvironmentObject private var path: NavigationCoordinator

    init(
        source: AidokuRunner.Source,
        component: HomeComponent,
        partial: Bool = false,
        bookmarkedItems: Binding<Set<String>>? = nil,
        loadMore: (() async -> Void)? = nil,
        onSelect: ((AidokuRunner.Manga) -> Void)? = nil
    ) {
        self.source = source
        self.component = component
        self.partial = partial
        self.loadMore = loadMore
        self.onSelect = onSelect
        if let bookmarkedItems {
            self._loadedBookmarks = State(initialValue: true)
            self._bookmarkedItems = bookmarkedItems
            self.usesBookmarksState = false
        } else {
            self._loadedBookmarks = State(initialValue: false)
            self._bookmarkedItems = Binding.constant([])
            self.usesBookmarksState = true
        }

        guard case let .mangaList(ranking, pageSize, entries, listing) = component.value else {
            fatalError("invalid component type")
        }
        self.ranking = ranking
        self.pageSize = pageSize
        self.entries = entries
        self.listing = listing
        self._coverHeight = State(initialValue: CGFloat(AppSettings.appearance.listCoverHeight.get()))
        self._coverFit = State(initialValue: AppSettings.appearance.listCoverFit.get())
    }

    var body: some View {
        VStack(alignment: .leading) {
            if let title = component.title {
                TitleView(
                    title: title,
                    subtitle: component.subtitle,
                    onTitleClick: listing == nil ? nil : {
                        if let listing {
                            path.push(SourceListingViewController(source: source, listing: listing))
                        }
                    }
                )
            }

            if partial && entries.isEmpty {
                PlaceholderMangaHomeList.mainView(itemCount: 6)
                    .redacted(reason: .placeholder)
                    .shimmering()
            } else {
                Group {
                    if let pageSize {
                        let (getSection, height) = CollectionView.mangaListLayout(
                            itemsPerPage: pageSize,
                            totalItems: entries.count,
                            itemHeight: coverHeight
                        )
                        CollectionView(
                            sections: [
                                CollectionViewSection(
                                    items: entries.indices.map { offset in
                                        AnyView(view(
                                            for: entries[offset],
                                            position: offset
                                        ).ignoresSafeArea())
                                    }
                                )
                            ],
                            layout: UICollectionViewCompositionalLayout { _, layoutEnvironment in
                                getSection(layoutEnvironment)
                            },
                            layoutToken: coverHeight
                        )
                        .frame(height: height)
                    } else {
                        LazyVStack {
                            let entryIds = homeEntryIdentities(entries)
                            ForEach(entries.indices, id: \.self) { offset in
                                view(
                                    for: entries[offset],
                                    position: offset
                                )
                                .id(entryIds[offset])
                            }
                            loadMoreView
                        }
                    }
                }
                .task {
                    if !loadedBookmarks {
                        await loadBookmarked()
                    }
                }
                .onChange(of: entries) { _ in
                    loadingMore = false
                    Task {
                        if !loadedBookmarks {
                            await loadBookmarked()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(NotificationCenter.default.publisher(for: .init(AppSettings.appearance.listCoverHeight.key))) { _ in
            coverHeight = CGFloat(AppSettings.appearance.listCoverHeight.get())
        }
        .onReceive(NotificationCenter.default.publisher(for: .init(AppSettings.appearance.listCoverFit.key))) { _ in
            coverFit = AppSettings.appearance.listCoverFit.get()
        }
    }

    @ContentBuilder
    var loadMoreView: some View {
        if loadingMore {
            EmptyView()
        } else {
            Spacer()
                .onAppear {
                    loadingMore = true
                    Task {
                        await loadMore?()
                    }
                }
        }
    }

    @ContentBuilder
    func view(for entry: HomeComponent.Value.Link, position: Int) -> some View {
        let label = HStack(alignment: .top, spacing: 12) {
            let mangaKey: String? = switch entry.value {
                case .manga(let manga): manga.key
                default: nil
            }
            MangaCoverView(
                source: source,
                coverImage: entry.imageUrl ?? "",
                width: coverHeight * 2/3,
                height: coverHeight,
                downsampleWidth: 200,
                contentMode: coverFit ? .fit : .fill,
                bookmarked: mangaKey.flatMap { (usesBookmarksState ? bookmarkedItemsState : bookmarkedItems).contains($0) } ?? false
            )

            // the text column is exactly as tall as the cover: the title
            // runs vertically down it (columns flowing left to right),
            // and the subtitle and tag lines stay horizontal at the
            // bottom — one reserved line each, so with no tags the
            // title simply gets that line's height too
            let titleStack = VStack(alignment: .leading, spacing: 4) {
                VerticalTitleView(text: entry.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if case .manga(let manga) = entry.value, let tags = manga.tags, !tags.isEmpty {
                    if pageSize != nil {
                        GeometryReader { geo in
                            HStack(spacing: 4) {
                                let availableTags = numberOfItemsThatFit(in: geo.size.width, items: tags)
                                let tagCount = min(availableTags, tags.count)

                                if tagCount > 0 {
                                    ForEach(tags.prefix(tagCount), id: \.self) { tag in
                                        LabelView(text: tag)
                                    }
                                }

                                Spacer(minLength: 0)
                            }
                        }
                        .frame(height: 20)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(tags, id: \.self) { tag in
                                    LabelView(text: tag)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .frame(height: coverHeight)

            if ranking {
                HStack(alignment: .top) {
                    Text("\(position + 1)")
                        .bold()
                        .padding(.horizontal, 2)

                    titleStack
                }
            } else {
                titleStack
            }

            Spacer()
        }
        .padding(.horizontal)
        if let value = entry.value {
            Button {
                switch value {
                    case .url(let urlString):
                        guard
                            let url = URL(string: urlString),
                            url.scheme == "http" || url.scheme == "https"
                        else { return }
                        path.present(SFSafariViewController(url: url))
                    case .listing(let listing):
                        path.push(SourceListingViewController(source: source, listing: listing))
                    case .manga(let manga):
                        if let onSelect {
                            onSelect(manga)
                        } else {
                            path.push(MangaViewController(source: source, manga: manga, parent: path.rootViewController))
                        }
                }
            } label: {
                label
            }
            .foregroundStyle(.primary)
            .buttonStyle(.borderless)
        }
    }

    func loadBookmarked() async {
        guard !entries.isEmpty, usesBookmarksState else { return }
        bookmarkedItemsState = await CoreDataManager.shared.container.performBackgroundTask { context in
            var keys: Set<String> = .init()
            for entry in entries {
                let mangaId: MangaIdentifier? = switch entry.value {
                    case .manga(let manga): manga.identifier
                    default: nil
                }
                if let mangaId {
                    if CoreDataManager.shared.hasLibraryManga(
                        mangaId: mangaId,
                        context: context
                    ) {
                        keys.insert(mangaId.mangaKey)
                    }
                }
            }
            return keys
        }
        loadedBookmarks = true
    }

    private func numberOfItemsThatFit(in availableWidth: CGFloat, items: [String]) -> Int {
        var totalWidth: CGFloat = 0
        var count = 0

        for item in items {
            // padding of 8 on both sides, plus 8 for the spacing in between
            let padding: CGFloat = 8 + 8 + 8
            let itemWidth = item
                .size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption2)])
                .width + padding
            if totalWidth + itemWidth > availableWidth {
                break
            }
            totalWidth += itemWidth
            count += 1
        }

        return count
    }
}

/// A title set vertically: characters run top to bottom and columns
/// flow left to right, so a long title uses the full height of the
/// narrow column beside a list cover instead of being cut off after
/// two horizontal lines. SwiftUI has no vertical typesetting, so the
/// title is chunked into single-character cells by hand; latin letters
/// and digits stack one per cell, like a vertical sign. Whatever does
/// not fit in the available columns ends with an ellipsis.
private struct VerticalTitleView: View {
    let text: String

    // one character cell, sized for the default body font the list
    // titles use: a full-width glyph plus a little air
    private let cellWidth: CGFloat = 20
    private let cellHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let charsPerColumn = max(1, Int(geometry.size.height / cellHeight))
            let maxColumns = max(1, Int(geometry.size.width / cellWidth))
            let columns = makeColumns(charsPerColumn: charsPerColumn, maxColumns: maxColumns)
            HStack(alignment: .top, spacing: 0) {
                ForEach(columns.indices, id: \.self) { columnIndex in
                    VStack(spacing: 0) {
                        ForEach(columns[columnIndex].indices, id: \.self) { charIndex in
                            Text(columns[columnIndex][charIndex])
                                .frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func makeColumns(charsPerColumn: Int, maxColumns: Int) -> [[String]] {
        let chars = text.filter { $0 != "\n" }.map(String.init)
        var columns: [[String]] = []
        var index = 0
        while index < chars.count && columns.count < maxColumns {
            let end = min(index + charsPerColumn, chars.count)
            var column = Array(chars[index..<end])
            if end < chars.count && columns.count == maxColumns - 1 && column.count > 1 {
                // more text than fits: mark the cut at the end of the
                // last visible column
                column[column.count - 1] = "…"
            }
            columns.append(column)
            index = end
        }
        return columns
    }
}

struct PlaceholderMangaHomeList: View {
    var showTitle = true
    var itemCount = 5

    var body: some View {
        VStack(alignment: .leading) {
            if showTitle {
                Text("Loading")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
            }

            Self.mainView(itemCount: itemCount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .shimmering()
    }

    static func mainView(itemCount: Int) -> some View {
        let coverHeight = CGFloat(AppSettings.appearance.listCoverHeight.get())
        return LazyVStack {
            ForEach(0..<itemCount, id: \.self) { _ in
                HStack {
                    Rectangle()
                        .fill(Color(.secondarySystemFill))
                        .frame(width: coverHeight * 2/3, height: coverHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading Title")
                        Text("Loading")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
    }
}
