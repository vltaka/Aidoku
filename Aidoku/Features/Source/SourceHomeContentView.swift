//
//  SourceHomeContentView.swift
//  Aidoku
//
//  Created by Skitty on 4/28/25.
//

import AidokuRunner
import SwiftUI

struct SourceHomeContentView: View {
    let source: AidokuRunner.Source

    @Binding var listings: [AidokuRunner.Listing]
    @Binding var headerListingSelection: Int // used only for listing header

    @State private var home: Home?
    @State private var listingHome: Home? // Home-like layout for current listing
    @State private var entries: [AidokuRunner.Manga] = []
    @State private var containerWidth: CGFloat = 0

    @State private var hasLoaded = false
    @State private var loading = true
    @State private var homeFullyLoaded = false
    @State private var listingSelection = 0
    @State private var page = 1
    @State private var hasMore = false
    @State private var bookmarkedItems: Set<String> = .init()

    @State private var error: Error?

    @State private var loadTask: Task<(), Never>?
    @State private var loadListingTask: Task<(), Never>?

    enum ListingLoadState {
        case loading
        case notLoading
        case allLoaded
    }

    @State private var listingLoadState: ListingLoadState = .loading

    // set while a listing switch is in flight; switching listings is
    // supposed to land at the top, so the scroll-anchor restore must
    // sit that load out
    @State private var listingSwitchInFlight = false
    // while the app is away from the foreground the rebuilt scroll view
    // reports the frames of wherever it restarted (the top), which must
    // not overwrite the remembered anchor before it can be restored
    @State private var anchorWritesSuspended = false
    // a restore to this entry has been issued but not yet confirmed by
    // the frame reports; while it is set, writes stay suspended and the
    // frame reports drive the restore instead (see updateScrollAnchor)
    @State private var pendingAnchorKey: String?
    @State private var anchorRestoreTask: Task<Void, Never>?
    // latest item frames reported by the grid, kept so the anchor
    // restore loop can tell which entries are realized right now
    @State private var latestItemFrames: [String: CGRect] = [:]
    @State private var entriesWereEmpty = true
    // entries whose cells currently exist, reported by the grid cells
    // themselves (appear/disappear). This is the second channel for
    // remembering the reading position: the frame reports above stop
    // cold during a fast fling, but a cell cannot be on screen without
    // having appeared, so this channel keeps up exactly where the
    // frame channel freezes
    @State private var visibleEntryKeys: Set<String> = []
    // when the frame channel last produced the top entry; the
    // visibility channel only writes when the frame channel has gone
    // quiet, since the frame value is the more precise of the two
    @State private var lastFrameAnchorWrite = Date.distantPast

    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var path: NavigationCoordinator

    private var currentListing: AidokuRunner.Listing? {
        listing(for: listingSelection)
    }

    private func listing(for selection: Int) -> AidokuRunner.Listing? {
        let listingIndex = selection - (source.features.providesHome ? 1 : 0)
        return listings[safe: listingIndex]
    }

    init(
        source: AidokuRunner.Source,
        holdingViewController: UIViewController,
        listings: Binding<[AidokuRunner.Listing]>,
        headerListingSelection: Binding<Int>
    ) {
        self.source = source
        self._listings = listings
        self._headerListingSelection = headerListingSelection
        self._path = StateObject(wrappedValue: NavigationCoordinator(rootViewController: holdingViewController))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { reader in
                ScrollView {
                    VStack {}.id(0) // indicator to scroll to the top

                    scrollContent(containerWidth: containerWidth)
                        .frame(maxWidth: .infinity)
                        .opacity(error != nil ? 0 : 1)
                }
                .overlay {
                    if let error {
                        ErrorView(
                            error: error,
                            restart: { try await source.restart() },
                            retry: { await reload() }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .padding()
                    }
                }
                .refreshable {
                    // nesting task prevents it from being cancelled
                    let task = Task {
                        try? await Task.sleep(nanoseconds: 100_000_000) // delay to fix animation
                        await reload()
                    }
                    await task.value
                }
                .onPreferenceChange(HomeItemFramesPreferenceKey.self) { frames in
                    latestItemFrames = frames
                    updateScrollAnchor(from: frames, using: reader)
                }
                .onChange(of: loading) { isLoading in
                    if !isLoading {
                        attemptScrollAnchorRestore(using: reader)
                    }
                }
                .onChange(of: entries.count) { _ in
                    // the load path hides the loading view before the
                    // entries land, so the loading trigger alone restores
                    // against an empty list and gives up; restoring again
                    // when the entries actually arrive covers that gap
                    if entriesWereEmpty && !entries.isEmpty {
                        attemptScrollAnchorRestore(using: reader)
                    }
                    entriesWereEmpty = entries.isEmpty
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                        case .active:
                            // coming back to the foreground: if the view
                            // tree was rebuilt while away, the scroll view
                            // restarted at the top with its content intact
                            // and no load ever fires — restore from the
                            // remembered anchor now. Frame reports stay
                            // suspended until they confirm the restore
                            // landed (see updateScrollAnchor); when there
                            // is no anchor to restore there is nothing to
                            // protect, so writes resume right away.
                            attemptScrollAnchorRestore(using: reader)
                            if pendingAnchorKey == nil {
                                anchorWritesSuspended = false
                            }
                        case .inactive, .background:
                            anchorWritesSuspended = true
                            anchorRestoreTask?.cancel()
                        default:
                            break
                    }
                }
                // update listingSelection when header selection changes;
                // a separate variable is used in order to perform the rest of the changes along with listingSelection
                // immediately rather than having a slight delay
                .onChange(of: headerListingSelection) { value in
                    listingSwitchInFlight = true
                    // a pending restore belongs to the outgoing listing
                    pendingAnchorKey = nil
                    anchorRestoreTask?.cancel()
                    // the visible set belongs to the outgoing listing
                    // too; the incoming listing's cells report fresh
                    visibleEntryKeys = []
                    loadListingTask?.cancel()
                    loadListingTask = Task {
                        defer { listingSwitchInFlight = false }
                        error = nil

                        if value != 0 || !source.features.providesHome {
                            // load listing. The selection flips right
                            // now, with the tap, and the incoming
                            // listing's skeleton takes the screen: the
                            // outgoing listing's content never lingers
                            // waiting for the new data, and nothing but
                            // the new listing's skeleton or its own
                            // content can appear in between. (This is
                            // the original app's switch shape, minus its
                            // staged waits.)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                listingSelection = value
                                entries = []
                                listingHome = nil
                                loading = true
                            }
                            reader.scrollTo(0)
                            await loadListing()
                        } else {
                            // switch to home: its content is already in
                            // memory, so this swap lands immediately too,
                            // with the same short fade as a listing swap
                            withAnimation(.easeInOut(duration: 0.2)) {
                                entries = []
                                listingHome = nil
                                listingSelection = value
                            }
                            reader.scrollTo(0)

                            if home == nil {
                                loading = true
                                homeFullyLoaded = false
                                await loadHome()
                            } else {
                                loading = false
                            }
                        }
                    }
                }
            }
            .coordinateSpace(name: "aidokuHomeScroll")
            .onChange(of: listings) { value in
                // reset listing selection to the first if the selected one disappears
                let maxListings = value.count - (source.features.providesHome ? 0 : 1)
                if listingSelection > maxListings {
                    headerListingSelection = 0
                } else if !source.features.providesHome || (source.features.providesHome && listingSelection > 0) {
                    // otherwise, reload current listing
                    Task {
                        await reload()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("refresh-content"))) { _ in
                loadTask?.cancel()
                loadTask = Task {
                    guard !Task.isCancelled else { return }
                    await reload()
                    // reload home page even if we're not on it
                    if source.features.providesHome && listingSelection != 0 {
                        await loadHome()
                    }
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await reload(initial: true)
            }
            .environmentObject(path)
            .onAppear {
                containerWidth = geometry.size.width
            }
            .onChange(of: geometry.size.width) { width in
                containerWidth = width
            }
        }
    }

    @ContentBuilder
    private func scrollContent(containerWidth: CGFloat) -> some View {
        if loading {
            // loading skeleton
            loadingView(width: containerWidth).transition(.opacity)
        } else if let home, listingSelection == 0 {
            // home page
            homeView(for: home, partial: !homeFullyLoaded)
        } else if listingSelection > 0 || !source.features.providesHome, let listing = currentListing {
            // listing page - check if source provides custom Home-like layout
            if let listingHome {
                homeView(for: listingHome, partial: false)
                    .transition(.opacity)
            } else {
                // Display listing with listing.kind
                Group {
                    switch listing.kind {
                        case .default:
                            HomeGridView(
                                source: source,
                                entries: entries,
                                containerWidth: containerWidth,
                                bookmarkedItems: $bookmarkedItems,
                                onItemVisibilityChange: { key, visible in
                                    if visible {
                                        visibleEntryKeys.insert(key)
                                    } else {
                                        visibleEntryKeys.remove(key)
                                    }
                                    updateVisibilityAnchor()
                                }
                            ) {
                                if hasMore && listingLoadState != .loading {
                                    await loadEntries()
                                }
                            }
                            .id(listingSelection) // Force recreation on listing change
                        case .list:
                            HomeListView(
                                source: source,
                                component: .init(title: nil, value: .mangaList(entries: entries.map { $0.intoLink() }))
                            ) {
                                if hasMore && listingLoadState != .loading {
                                    await loadEntries()
                                }
                            }
                            .id(listingSelection) // Force recreation on listing change
                            .padding(.bottom)
                    }
                }
                .transition(.opacity)
            }
        } else {
            loadingView(width: containerWidth).frame(height: 200).hidden()
        }
    }

    @ContentBuilder
    private func loadingView(width: CGFloat) -> some View {
        Group {
            if listingSelection == 0 && source.features.providesHome {
                SourceHomeSkeletonView(source: source)
            } else if let listing = currentListing {
                switch listing.kind {
                    case .default:
                        HomeGridView.placeholder(width: width)
                    case .list:
                        PlaceholderMangaHomeList(showTitle: false)
                }
            }
        }
    }

    @ContentBuilder
    private func homeView(for home: Home, partial: Bool) -> some View {
        VStack(spacing: 24) {
            ForEach(home.components.indices, id: \.self) { offset in
                let component = home.components[offset]
                switch component.value {
                    case .imageScroller:
                        HomeImageScrollerView(source: source, component: component, partial: partial)
                    case .bigScroller:
                        HomeBigScrollerView(source: source, component: component, partial: partial)
                    case .scroller:
                        HomeScrollerView(source: source, component: component, partial: partial)
                    case .mangaList:
                        HomeListView(source: source, component: component, partial: partial)
                            .id("listing-\(offset)") // Force recreation for listing components
                    case .mangaChapterList:
                        HomeChapterListView(source: source, component: component, partial: partial)
                    case .filters:
                        HomeFiltersView(source: source, component: component, partial: partial)
                    case .links:
                        HomeLinksView(source: source, component: component, partial: partial)
                }
            }
            .transition(.opacity)
        }
        .padding(.bottom)
    }
    /// Remember the entry currently sitting at the top of the scroll
    /// view, from the item frames the grid reports. While a restore is
    /// pending the frames are only used to drive and confirm that
    /// restore, never written down: the rebuilt scroll view sits at the
    /// top, and writing its top entry would overwrite the very position
    /// being restored, for good.
    private func updateScrollAnchor(from frames: [String: CGRect], using reader: ScrollViewProxy) {
        // while a listing switch is in flight the frames still come from
        // the outgoing listing's content; writing them down under the new
        // listing's key would poison its remembered position
        guard !listingSwitchInFlight else { return }
        let visible = frames.filter { $0.value.maxY > 0 }
        guard let top = visible.min(by: { lhs, rhs in
            if lhs.value.minY != rhs.value.minY { return lhs.value.minY < rhs.value.minY }
            return lhs.key < rhs.key
        }) else { return }
        if let pendingKey = pendingAnchorKey {
            if top.key == pendingKey {
                // the remembered entry is back at the top: the restore
                // landed, so frame reports can be trusted again
                pendingAnchorKey = nil
                anchorRestoreTask?.cancel()
                anchorWritesSuspended = false
                log("[anchor] restore confirmed", pendingKey, "listing", listingSelection)
            } else {
                // not there yet: the restore loop keeps relaying the
                // scroll toward it; these frames must not be written
                // down as the position in the meantime
                return
            }
        }
        guard !anchorWritesSuspended else { return }
        lastFrameAnchorWrite = Date()
        if HomeScrollAnchorStore.shared.anchor(sourceKey: source.key, listing: listingSelection) != top.key {
            HomeScrollAnchorStore.shared.setAnchor(
                sourceKey: source.key,
                listing: listingSelection,
                topKey: top.key
            )
            log("[anchor] frame write", top.key, "listing", listingSelection)
        }
    }

    /// The second channel for remembering the reading position: the
    /// grid cells report themselves appearing and disappearing, and
    /// the first visible entry in reading order is the position. The
    /// frame channel (updateScrollAnchor) is more precise, so this
    /// only writes when that channel has gone quiet — during a fast
    /// fling its reports stop entirely, which is exactly when the
    /// position used to freeze at whatever it was before the fling.
    private func updateVisibilityAnchor() {
        guard !listingSwitchInFlight else { return }
        guard pendingAnchorKey == nil, !anchorWritesSuspended else { return }
        guard Date().timeIntervalSince(lastFrameAnchorWrite) > 0.3 else { return }
        guard let topKey = entries.first(where: { visibleEntryKeys.contains($0.key) })?.key
        else { return }
        if HomeScrollAnchorStore.shared.anchor(sourceKey: source.key, listing: listingSelection) != topKey {
            HomeScrollAnchorStore.shared.setAnchor(
                sourceKey: source.key,
                listing: listingSelection,
                topKey: topKey
            )
            log("[anchor] visibility write", topKey, "listing", listingSelection)
        }
    }

    /// After content (re)loads, put the scroll position back where the
    /// user left it. The store always holds the last topmost entry, so
    /// when nothing was rebuilt this scrolls to where the user already
    /// is; when the tree was rebuilt in the background it restores the
    /// position that would otherwise be lost to the top. Called from
    /// every point where a restore could become possible (load finished,
    /// entries landed, app back in the foreground); it is a no-op while
    /// a listing switch is in flight, since switching listings is
    /// supposed to land at the top. Issuing a restore also marks it
    /// pending: anchor writes stay suspended until the frame reports
    /// confirm the entry is back at the top (see updateScrollAnchor).
    private func attemptScrollAnchorRestore(using reader: ScrollViewProxy) {
        guard !listingSwitchInFlight else { return }
        guard listingSelection != 0 || !source.features.providesHome else { return }
        guard
            let anchorKey = HomeScrollAnchorStore.shared.anchor(
                sourceKey: source.key,
                listing: listingSelection
            )
        else { return }
        if pendingAnchorKey != anchorKey {
            pendingAnchorKey = anchorKey
        }
        log("[anchor] restore start", anchorKey, "listing", listingSelection)
        anchorWritesSuspended = true
        if entries.contains(where: { $0.key == anchorKey }) {
            reader.scrollTo(anchorKey, anchor: .top)
        }
        // Relay the scroll the rest of the way. The target may sit in a
        // lazy stack far below what is realized right now, and a single
        // scrollTo cannot reach an entry that does not exist yet; it
        // stops at the deepest realized one. So keep stepping: scroll
        // to the deepest realized entry, let the next chunk realize,
        // and repeat until the target itself is realized and scrolled
        // to. The loop runs on a timer because once a step settles, no
        // further frame changes arrive to drive another attempt. It
        // ends when the frame reports confirm the target is back at
        // the top (see updateScrollAnchor), or after a few seconds so
        // it never fights the user for long.
        anchorRestoreTask?.cancel()
        anchorRestoreTask = Task { @MainActor in
            var ticks = 0
            while let key = pendingAnchorKey, ticks < 20 {
                ticks += 1
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard pendingAnchorKey == key, !Task.isCancelled else { return }
                if latestItemFrames[key] != nil || visibleEntryKeys.contains(key) {
                    reader.scrollTo(key, anchor: .top)
                } else if let stone = deepestMaterializedKey() {
                    reader.scrollTo(stone, anchor: .top)
                }
            }
            if pendingAnchorKey != nil {
                log("[anchor] restore gave up", key, "listing", listingSelection)
                pendingAnchorKey = nil
                anchorWritesSuspended = false
            }
        }
    }

    /// The realized entry furthest along the current list, from the
    /// frames the grid has reported. Used as a stepping stone by the
    /// anchor restore loop.
    private func deepestMaterializedKey() -> String? {
        let indexByKey = Dictionary(
            entries.enumerated().map { ($0.element.key, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        return latestItemFrames.keys.max(by: { (indexByKey[$0] ?? -1) < (indexByKey[$1] ?? -1) })
    }
}

extension SourceHomeContentView {
    func reload(initial: Bool = false) async {
        if listingSwitchInFlight {
            // a listing switch is mid-flight; cancelling it here would
            // strand the page on the old listing while the chip bar
            // already shows the new one — let it land first
            await loadListingTask?.value
        } else {
            loadListingTask?.cancel()
        }
        if error != nil {
            withAnimation {
                loading = true
                error = nil
            }
        }
        // only load listings when actually reloading
        // they're loaded in ListingsHeaderView initially
        if !initial {
            // don't fail the entire home screen if listings fail to load
            if let newListings = try? await source.getListings() {
                listings = newListings
            }
            guard !Task.isCancelled else { return }
        }
        homeFullyLoaded = false
        if source.features.providesHome && listingSelection == 0 {
            await loadHome()
        } else {
            await loadListing()
        }
    }

    func loadHome() async {
        await source.partialHomePublisher?.sink { @Sendable partialHome in
            Task { @MainActor in
                withAnimation {
                    self.home = partialHome
                    if headerListingSelection == 0 {
                        loading = false
                    }
                }
            }
        }
        do {
            let home = try await source.getHome()
            withAnimation {
                self.home = home
            }

            // update stored component types for skeleton loading
            let storedComponentsKey = "\(source.key).homeComponents"
            let storedComponents = UserDefaults.standard.array(forKey: storedComponentsKey)
            let componentCount = storedComponents.flatMap { $0.count / 2 } ?? 0
            if componentCount != home.components.count {
                let result = home.components.flatMap {
                    switch $0.value {
                        case let .mangaList(_, pageSize, entries, _):
                            return [3, min(pageSize ?? .max, entries.count)]
                        case let .mangaChapterList(pageSize, entries, _):
                            return [4, min(pageSize ?? .max, entries.count)]
                        default:
                            return [$0.value.intValue, 0]
                    }
                }
                UserDefaults.standard.set(result, forKey: storedComponentsKey)
            }
        } catch {
            self.home = nil
            withAnimation {
                self.error = error
            }
        }
        await source.partialHomePublisher?.removeSink()

        withAnimation {
            if headerListingSelection == 0 {
                loading = false
            }
            homeFullyLoaded = true
        }
    }

    func loadListing() async {
        page = 1
        await loadEntries(initial: true)
    }

    func loadEntries(initial: Bool = false) async {
        do {
            guard let listing = currentListing
            else { return }

            listingLoadState = .loading

            // Try to get Home-like layout first
            if initial {
                if let home = try await source.getListingHome(listing: listing) {
                    // Source provides custom Home-like layout for this
                    // listing. The selection already flipped when the
                    // switch started; only the layout lands here, in
                    // the same short fade as a regular swap.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        listingHome = home
                        entries = []
                        loading = false
                    }

                    listingLoadState = .allLoaded
                    return
                } else {
                    // No custom layout, use default pagination; any old
                    // listingHome is cleared when the results land below
                }
            } else if listingHome != nil {
                // If we have a listing home (Home-like layout), we shouldn't paginate
                // This prevents loading more when scrolling in Home-like view
                return
            }

            // start loading listing items. While this is in flight the
            // screen holds either the incoming listing's skeleton (on
            // a switch) or the current content (on a reload); the
            // results land in one step below.
            let resultTask = Task {
                try await source.getMangaList(listing: listing, page: page)
            }

            hasMore = false

            // load new results
            let result = try await resultTask.value

            guard !Task.isCancelled else { return }

            // a load-more that started before a listing switch must not
            // land: its page bump would skip a page of the new listing
            guard initial || !listingSwitchInFlight else { return }

            hasMore = result.hasNextPage
            listingLoadState = hasMore ? .notLoading : .allLoaded
            page += 1

            // load bookmark icons for stuff that's in our library
            let bookmarkedKeys: [String] = await CoreDataManager.shared.container.performBackgroundTask { context in
                var keys: [String] = []
                for manga in result.entries where CoreDataManager.shared.hasLibraryManga(
                    mangaId: manga.identifier,
                    context: context
                ) {
                    keys.append(manga.key)
                }
                return keys
            }
            bookmarkedItems.formUnion(bookmarkedKeys)

            // hide loading view (only ever shown when there was no
            // previous content to keep on screen)
            loading = false

            guard !Task.isCancelled else { return }

            if initial {
                // the one-step swap: the new entries land in a single
                // short fade. The selection already flipped when the
                // switch started, so what appears is only ever the new
                // listing's own content.
                withAnimation(.easeInOut(duration: 0.2)) {
                    listingHome = nil
                    entries = result.entries
                }
            } else {
                // append to existing entries
                withAnimation(.easeIn(duration: 0.2)) {
                    entries += result.entries
                }
            }
        } catch {
            guard !Task.isCancelled else { return }

            // the selection already flipped when the switch started,
            // so the error view's retry targets the right listing
            loading = false
            withAnimation {
                self.error = error
            }
        }
    }
}

/// The last topmost visible entry of each listing, remembered outside
/// the view tree. The home view tree is recreated when the app comes
/// back from the background (and its scroll view with it), which used
/// to drop the reading position back to the top; the grid reports the
/// top entry while scrolling, and the position is restored from here
/// once content finishes loading.
final class HomeScrollAnchorStore {
    static let shared = HomeScrollAnchorStore()

    private let lock = NSLock()
    private var anchors: [String: String] = [:]

    private func key(sourceKey: String, listing: Int) -> String {
        "\(sourceKey)|\(listing)"
    }

    func setAnchor(sourceKey: String, listing: Int, topKey: String) {
        lock.lock()
        defer { lock.unlock() }
        anchors[key(sourceKey: sourceKey, listing: listing)] = topKey
    }

    func anchor(sourceKey: String, listing: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return anchors[key(sourceKey: sourceKey, listing: listing)]
    }
}
