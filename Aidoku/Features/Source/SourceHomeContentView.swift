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

    // set while a listing switch is in flight, so a load-more that
    // started under the outgoing listing cannot land in the new one
    @State private var listingSwitchInFlight = false
    // bumped on every listing switch; the scroll view branch watches
    // it to jump back to the top for the incoming listing
    @State private var topScrollSignal = 0

    @StateObject private var path: NavigationCoordinator

    private var currentListing: AidokuRunner.Listing? {
        listing(for: listingSelection)
    }

    private func listing(for selection: Int) -> AidokuRunner.Listing? {
        let listingIndex = selection - (source.features.providesHome ? 1 : 0)
        return listings[safe: listingIndex]
    }

    // the default-kind listing page is a UIKit collection view (see
    // ListingGridView): it keeps its scroll position across the app
    // going to the background and coming back, which the SwiftUI grid
    // never managed. It is only shown once content has landed; while
    // loading (or when a listing provides its own home-like layout)
    // the SwiftUI side below renders instead.
    private var showListingGrid: Bool {
        guard !loading, error == nil, listingHome == nil else { return false }
        guard listingSelection > 0 || !source.features.providesHome else { return false }
        return currentListing?.kind == .default
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
            Group {
                if showListingGrid {
                    ListingGridView(
                        entries: entries,
                        bookmarkedItems: bookmarkedItems,
                        onLoadMore: { loadMoreIfNeeded() },
                        onRefresh: { await reload() }
                    )
                    .transition(.opacity)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack {}.id(0) // indicator to scroll to the top

                            scrollContent(containerWidth: containerWidth)
                                .frame(maxWidth: .infinity)
                        }
                        .refreshable {
                            // nesting task prevents it from being cancelled
                            let task = Task {
                                try? await Task.sleep(nanoseconds: 100_000_000) // delay to fix animation
                                await reload()
                            }
                            await task.value
                        }
                        .onChange(of: topScrollSignal) { _ in
                            reader.scrollTo(0)
                        }
                    }
                }
            }
            .opacity(error != nil ? 0 : 1)
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
            // update listingSelection when header selection changes;
            // a separate variable is used in order to perform the rest of the changes along with listingSelection
            // immediately rather than having a slight delay
            .onChange(of: headerListingSelection) { value in
                listingSwitchInFlight = true
                loadListingTask?.cancel()
                loadListingTask = Task {
                    defer { listingSwitchInFlight = false }
                    error = nil

                    if value != 0 || !source.features.providesHome {
                        // load listing. The selection flips right now,
                        // with the tap, and the incoming listing's
                        // skeleton takes the screen: the outgoing
                        // listing's content never lingers waiting for
                        // the new data, and nothing but the new
                        // listing's skeleton or its own content can
                        // appear in between.
                        withAnimation(.easeInOut(duration: 0.2)) {
                            listingSelection = value
                            entries = []
                            listingHome = nil
                            loading = true
                        }
                        topScrollSignal += 1
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
                        topScrollSignal += 1

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
                // Display listing with listing.kind. The .default kind
                // never reaches this view: the body routes it to the
                // UIKit ListingGridView instead.
                Group {
                    switch listing.kind {
                        case .default:
                            EmptyView()
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

    /// The UIKit listing grid asking for the next page. Mirrors the
    /// guard the SwiftUI surfaces use: only when more pages exist and
    /// no page load is already running.
    private func loadMoreIfNeeded() {
        guard hasMore, listingLoadState != .loading else { return }
        Task {
            await loadEntries()
        }
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
                    // listing; the selection already flipped when the
                    // switch started, so only the layout lands here,
                    // in the same short fade as a regular swap.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        listingHome = home
                        entries = []
                        loading = false
                    }

                    listingLoadState = .allLoaded
                    return
                } else {
                    // No custom layout, use default pagination
                }
            } else if listingHome != nil {
                // If we have a listing home (Home-like layout), we shouldn't paginate
                // This prevents loading more when scrolling in Home-like view
                return
            }

            // load the listing items; the listing's skeleton (or the
            // UIKit grid, on a reload) stays on screen untouched while
            // this is in flight, and the results land in one step below
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

            guard !Task.isCancelled else { return }

            if initial {
                // the one-step swap: the new entries land together in
                // a single short fade. The selection already flipped
                // when the switch started, so what appears is only
                // ever the new listing's own content.
                withAnimation(.easeInOut(duration: 0.2)) {
                    listingHome = nil
                    entries = result.entries
                    loading = false
                }
            } else {
                // append to existing entries
                withAnimation(.easeIn(duration: 0.2)) {
                    entries += result.entries
                }
                loading = false
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
