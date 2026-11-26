//
//  HistoryView.swift
//  Aidoku
//
//  Created by Skitty on 7/30/25.
//

import AidokuRunner
import LocalAuthentication
import SwiftUI
import SwiftUIIntrospect

struct HistoryView: View {
    @StateObject private var viewModel = ViewModel()

    @State private var searchText = ""
    @State private var entryToDelete: HistoryEntry?
    @State private var showClearHistoryConfirm = false
    @State private var showDeleteConfirm = false

    @State private var triggerLoadMoreVisibleCheck = false
    @State private var loadTask: Task<(), Never>?

    @State private var locked = UserDefaults.standard.bool(forKey: "History.lockHistoryTab")

    // 0 = list, 1 = grid, 2 = waterfall
    @AppStorage("History.displayMode") private var displayMode = 0
    @State private var aspectCacheVersion = 0

    @State private var listSelection: String? // fix for list highlighting being buggy

    @State private var openingLastRead = false

    @EnvironmentObject private var path: NavigationCoordinator

    var body: some View {
        Group {
            if locked {
                lockedView
            } else if viewModel.filteredHistory.isEmpty && viewModel.loadingState == .complete {
                UnavailableView(
                    NSLocalizedString("NO_HISTORY"),
                    systemImage: "book.fill",
                    description: Text(NSLocalizedString("NO_HISTORY_TEXT"))
                )
                .ignoresSafeArea()
            } else if displayMode != 0 {
                historyGridContent
            } else {
                List(selection: $listSelection) {
                    let sections = viewModel.filteredHistory.values.sorted { $0.daysAgo < $1.daysAgo }
                    ForEach(sections, id: \.daysAgo) { section in
                        if !section.entries.isEmpty {
                            Section {
                                ForEach(section.entries, id: \.chapterId) { entry in
                                    cellView(entry: entry)
                                }
                            } header: {
                                headerView(daysAgo: section.daysAgo)
                            }
                        }
                    }

                    loadMoreView
                }
                .listStyle(.grouped)
                .environment(\.defaultMinListRowHeight, 1)
                .environment(\.defaultMinListHeaderHeight, 1) // for ios 15
                .listSectionSpacingPlease(10)
                .scrollBackgroundHiddenPlease()
                .scrollDismissesKeyboardImmediately()
                .background(Color(uiColor: .systemBackground))
            }
        }
        .customSearchable(
            text: $searchText,
            stacked: false,
            onSubmit: {
                Task {
                    await viewModel.search(query: searchText, delay: false)
                }
            },
            onCancel: {
                Task {
                    await viewModel.search(query: searchText, delay: false)
                }
            }
        )
        .environment(\.autocorrectionDisabled, true)
        .onChange(of: searchText) { newValue in
            Task {
                await viewModel.search(query: newValue, delay: true)
            }
        }
        .animation(.default, value: viewModel.filteredHistory)
        .navigationTitle(NSLocalizedString("HISTORY"))
        .navigationBarTitleDisplayMode(.automatic)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("显示模式", selection: $displayMode) {
                        Text("列表").tag(0)
                        Text("网格").tag(1)
                        Text("瀑布流").tag(2)
                    }
                } label: {
                    Image(systemName: displayMode == 0 ? "list.bullet" : displayMode == 1 ? "square.grid.2x2" : "square.grid.3x3")
                }
                if UserDefaults.standard.bool(forKey: "History.lockHistoryTab") {
                    Button {
                        if locked {
                            Task {
                                await unlock()
                            }
                        } else {
                            locked = true
                        }
                    } label: {
                        Image(systemName: locked ? "lock" : "lock.open")
                    }
                }
                Button {
                    showClearHistoryConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialogOrAlert(NSLocalizedString("CLEAR_READ_HISTORY"), isPresented: $showClearHistoryConfirm, titleVisibility: .visible) {
            Button(NSLocalizedString("CLEAR"), role: .destructive) {
                viewModel.clearHistory()
            }
        } message: {
            Text(NSLocalizedString("CLEAR_READ_HISTORY_TEXT"))
        }
        .confirmationDialogOrAlert(NSLocalizedString("CLEAR_READ_HISTORY"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(NSLocalizedString("REMOVE"), role: .destructive) {
                if let entryToDelete {
                    Task {
                        await viewModel.removeHistory(entry: entryToDelete)
                    }
                }
            }
            Button(NSLocalizedString("REMOVE_ALL_MANGA_HISTORY"), role: .destructive) {
                if let entryToDelete {
                    Task {
                        await viewModel.removeHistory(entry: entryToDelete, all: true)
                    }
                }
            }
        } message: {
            Text(NSLocalizedString("CLEAR_READ_HISTORY_TEXT"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyLockTabSetting)) { _ in
            // update locked state when the setting changes
            locked = UserDefaults.standard.bool(forKey: "History.lockHistoryTab")
        }
        .onReceive(NotificationCenter.default.publisher(for: CoverAspectCache.didUpdateNotification)) { _ in
            aspectCacheVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // lock the view when the app is backgrounded
            locked = UserDefaults.standard.bool(forKey: "History.lockHistoryTab")
        }
        .onReceive(NotificationCenter.default.publisher(for: .historyTabReselected)) { _ in
            // the history tab was selected while already at the top of the list
            Task {
                await continueReading()
            }
        }
    }

    var lockedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text(NSLocalizedString("HISTORY_LOCKED"))
                .fontWeight(.medium)

            Button(NSLocalizedString("VIEW_HISTORY")) {
                Task {
                    await unlock()
                }
            }
        }
        .padding(.top, -52) // slight offset to account for search bar and make the view more centered
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func headerView(daysAgo: Int) -> some View {
        Text(Date.makeRelativeDate(days: daysAgo))
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .foregroundColor(.primary) // for ios 15
            .textCase(.none)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }

    func cellView(entry: HistoryEntry) -> some View {
        let source = viewModel.sourceCache[entry.chapterId.sourceKey]
        let manga = viewModel.mangaCache[entry.chapterId.mangaIdentifier]
        return HistoryEntryCell(
            entry: entry,
            source: source,
            manga: manga,
            chapter: viewModel.chapterCache[entry.chapterId]
        ) {
            if let manga {
                path.push(MangaViewController(manga: manga, parent: path.rootViewController))
            }
        }
        .equatable()
        .contentShape(Rectangle())
        .listRowSeparator(.hidden, edges: .top)
        .listRowSeparator(.visible, edges: .bottom)
        .introspect(.listCell, on: .iOS(.v16, .v17, .v18, .v26, .v27)) { entity in
            // match cell background color to list background color when not selected (plain cell style)
            guard let cell = entity as? UICollectionViewListCell, cell.tag != 1 else { return }
            cell.backgroundConfiguration = UIBackgroundConfiguration.listPlainCell()
            cell.tag = 1
        }
        .swipeActions(edge: .trailing) {
            Button {
                entryToDelete = entry
                showDeleteConfirm = true
            } label: {
                Label(NSLocalizedString("DELETE"), systemImage: "trash")
            }
            .tint(.red) // adding destructive role breaks animation, so do this instead
        }
        .id(entry.chapterId)
        .tag(entry.chapterId)
        .offsetListSeparator()
    }

    @ContentBuilder
    var loadMoreView: some View {
        VStack {
            if viewModel.loadingState != .complete {
                ProgressView()
                    .progressViewStyle(.circular)
                    .onReportScrollVisibilityChange(trigger: $triggerLoadMoreVisibleCheck) { visible in
                        Task {
                            await loadTask?.value
                            if visible {
                                tryLoadingMore()
                            }
                        }
                    }
                    .onChange(of: viewModel.filteredHistory) { _ in
                        // trigger check to see if the loading more view is still visible after content is added
                        Task {
                            try? await Task.sleep(nanoseconds: 10_000_000) // wait 10ms
                            triggerLoadMoreVisibleCheck = true
                        }
                    }
                    .onAppear {
                        tryLoadingMore()
                    }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(.zero)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // grid (mode 1) and waterfall (mode 2) rendering of the history entries,
    // still grouped into date sections like the list
    private var historyGridContent: some View {
        GeometryReader { geometry in
            let _ = aspectCacheVersion
            let columnCount = OldMangaCollectionViewController.getGridItemsPerRow(
                containerWidth: geometry.size.width,
                isLandscape: geometry.size.width > geometry.size.height,
                layout: .custom
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    let sections = viewModel.filteredHistory.values.sorted { $0.daysAgo < $1.daysAgo }
                    ForEach(sections, id: \.daysAgo) { section in
                        if !section.entries.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(Date.makeRelativeDate(days: section.daysAgo))
                                    .font(.body.weight(.medium))
                                    .padding(.horizontal, 20)

                                if displayMode == 1 {
                                    LazyVGrid(
                                        columns: Array(
                                            repeating: GridItem(.flexible(), spacing: 12),
                                            count: columnCount
                                        ),
                                        spacing: 12
                                    ) {
                                        ForEach(section.entries, id: \.chapterId) { entry in
                                            historyCoverItem(entry: entry, aspectRatio: 2.0 / 3.0)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                } else {
                                    let itemWidth = max(
                                        0,
                                        (geometry.size.width - 32 - CGFloat(columnCount - 1) * 12) / CGFloat(columnCount)
                                    )
                                    let distribution = WaterfallDistributor.distribute(
                                        count: section.entries.count,
                                        columns: columnCount
                                    ) { index in
                                        let manga = viewModel.mangaCache[section.entries[index].chapterId.mangaIdentifier]
                                        let ratio = CoverAspectCache.shared.aspectRatio(for: manga?.cover) ?? (2.0 / 3.0)
                                        return itemWidth / ratio + 44 // cover plus title/subtitle text
                                    }
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(distribution.indices, id: \.self) { column in
                                            LazyVStack(spacing: 12) {
                                                ForEach(distribution[column], id: \.self) { index in
                                                    let entry = section.entries[index]
                                                    let manga = viewModel.mangaCache[entry.chapterId.mangaIdentifier]
                                                    historyCoverItem(
                                                        entry: entry,
                                                        aspectRatio: CoverAspectCache.shared.aspectRatio(for: manga?.cover) ?? (2.0 / 3.0)
                                                    )
                                                }
                                            }
                                            .frame(width: itemWidth)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }

                    if viewModel.loadingState != .complete {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .onAppear {
                                tryLoadingMore()
                            }
                    }
                }
                .padding(.vertical, 10)
            }
            .background(Color(uiColor: .systemBackground))
        }
    }

    private func historyCoverItem(entry: HistoryEntry, aspectRatio: CGFloat) -> some View {
        let source = viewModel.sourceCache[entry.chapterId.sourceKey]
        let manga = viewModel.mangaCache[entry.chapterId.mangaIdentifier]
        let chapter = viewModel.chapterCache[entry.chapterId]
        return Button {
            if let manga {
                path.push(MangaViewController(manga: manga, parent: path.rootViewController))
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(Color.clear)
                    .aspectRatio(aspectRatio, contentMode: .fill)
                    .background {
                        SourceImageView(
                            source: source,
                            imageUrl: manga?.cover ?? "",
                            downsampleWidth: 400
                        )
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color(UIColor.quaternarySystemFill), lineWidth: 1)
                    )

                Text(manga?.title ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(historySubtitle(entry: entry, chapter: chapter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func historySubtitle(entry: HistoryEntry, chapter: AidokuRunner.Chapter?) -> String {
        var components: [String] = []
        if let volumeNum = chapter?.volumeNumber, volumeNum >= 0 {
            if let chapterNum = chapter?.chapterNumber, chapterNum >= 0 {
                components.append([
                    String(format: NSLocalizedString("VOL_X"), volumeNum),
                    String(format: NSLocalizedString("CH_X"), chapterNum)
                ].joined(separator: " "))
            } else {
                components.append(String(format: NSLocalizedString("VOL_SPACE_X"), volumeNum))
            }
        } else if let chapterNum = chapter?.chapterNumber, chapterNum >= 0 {
            components.append(String(format: NSLocalizedString("CH_SPACE_X"), chapterNum))
        } else if let title = chapter?.title, chapter?.chapterNumber == nil && chapter?.volumeNumber == nil {
            components.append(title)
        }
        if let currentPage = entry.currentPage, let totalPages = entry.totalPages, currentPage > 0, currentPage < totalPages {
            components.append(String(format: NSLocalizedString("PAGE_X_OF_X"), currentPage, totalPages))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        components.append(formatter.string(from: entry.date))
        return components.joined(separator: " - ")
    }

    // load more history entries if the loading state is idle
    func tryLoadingMore() {
        loadTask = Task {
            if viewModel.loadingState == .idle {
                await viewModel.loadMore()
            }
        }
    }

    // open the most recently read manga, resuming from the chapter it left off on
    func continueReading() async {
        guard !locked, !openingLastRead else { return }
        openingLastRead = true
        defer { openingLastRead = false }

        let mangaId = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getRecentHistory(limit: 1, offset: 0, context: context)
                .first
                .map { $0.identifier.mangaIdentifier }
        }
        guard let mangaId else { return }

        var manga = viewModel.mangaCache[mangaId]
        if manga == nil {
            manga = await CoreDataManager.shared.container.performBackgroundTask { context in
                CoreDataManager.shared.getManga(
                    mangaId: mangaId,
                    context: context
                )?.toNewManga()
            }
        }

        let (chapters, nextChapter) = await MangaManager.shared.getNextChapter(
            mangaId: mangaId,
            fallbackChapters: manga?.chapters,
            fetchIfNeeded: true
        )

        var targetManga = manga ?? AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: "")
        if !chapters.isEmpty {
            targetManga.chapters = chapters
        }

        // the user can navigate elsewhere while the chapters are loading
        guard
            let rootViewController = path.rootViewController,
            rootViewController.view.window != nil,
            rootViewController.navigationController?.topViewController === rootViewController
        else { return }

        guard
            let chapter = nextChapter,
            let source = SourceManager.shared.store.source(for: mangaId.sourceKey)
        else {
            // nothing left to read (or the source is missing), so open the manga page instead.
            // without a source to load details from or anything stored to show, the page would be blank
            guard
                SourceManager.shared.store.isInstalled(sourceKey: mangaId.sourceKey) || !targetManga.title.isEmpty
            else {
                return
            }
            path.push(MangaViewController(manga: targetManga, parent: rootViewController))
            return
        }

        let readerController = ReaderViewController(
            source: source,
            manga: targetManga,
            chapter: chapter
        )
        let navigationController = ReaderNavigationController(readerViewController: readerController)
        navigationController.modalPresentationStyle = .fullScreen
        path.present(navigationController)
    }

    // prompt for biometrics to unlock the view
    func unlock() async {
        let context = LAContext()
        let success: Bool

        do {
            success = try await context.evaluatePolicy(
                .defaultPolicy,
                localizedReason: NSLocalizedString("AUTH_FOR_HISTORY")
            )
        } catch {
            // The error is to be displayed to users, so we can ignore it.
            return
        }

        guard success else {
            return
        }

        locked = false
    }
}

private struct HistoryEntryCell: View, @MainActor Equatable {
    let entry: HistoryEntry

    let source: AidokuRunner.Source?
    let manga: AidokuRunner.Manga?
    let chapter: AidokuRunner.Chapter?

    var onPressed: (() -> Void)?

    private static let coverImageWidth: CGFloat = 56

    var body: some View {
        Button {
            onPressed?()
        } label: {
            HStack(spacing: 12) {
                MangaCoverView(
                    source: source,
                    coverImage: manga?.cover ?? "",
                    width: Self.coverImageWidth,
                    height: Self.coverImageWidth * 3/2,
                    downsampleWidth: Self.coverImageWidth
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(manga?.title ?? "")
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text(makeSubtitle())
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let additionalEntryCount = entry.additionalEntryCount, additionalEntryCount > 0 {
                        let text = Text(String(format: NSLocalizedString("%lld_PLUS_MORE"), additionalEntryCount))
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                            .lineLimit(1)
                        if #available(iOS 16.0, *) {
                            text.contentTransition(.numericText())
                        } else {
                            text
                        }
                    }
                }
                Spacer()
            }
        }
        .tint(.primary)
    }

    func makeSubtitle() -> String {
        var components: [String] = []
        if let volumeNum = chapter?.volumeNumber, volumeNum >= 0 {
            if let chapterNum = chapter?.chapterNumber, chapterNum >= 0 {
                // both volume number and chapter number
                components.append([
                    String(format: NSLocalizedString("VOL_X"), volumeNum),
                    String(format: NSLocalizedString("CH_X"), chapterNum)
                ].joined(separator: " "))
            } else {
                // only volume number
                components.append(String(format: NSLocalizedString("VOL_SPACE_X"), volumeNum))
            }
        } else if let chapterNum = chapter?.chapterNumber, chapterNum >= 0 {
            // no volume number, just use chapter number
            components.append(String(format: NSLocalizedString("CH_SPACE_X"), chapterNum))
        } else if let title = chapter?.title, chapter?.chapterNumber == nil && chapter?.volumeNumber == nil {
            // no volume or chapter number, just use the title
            components.append(title)
        }
        if let currentPage = entry.currentPage, let totalPages = entry.totalPages, currentPage > 0, currentPage < totalPages {
            components.append(String(format: NSLocalizedString("PAGE_X_OF_X"), currentPage, totalPages))
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        components.append(formatter.string(from: entry.date))
        return components.joined(separator: " - ")
    }

    static func == (lhs: HistoryEntryCell, rhs: HistoryEntryCell) -> Bool {
        lhs.entry == rhs.entry && lhs.manga == rhs.manga && lhs.chapter == rhs.chapter
    }
}
