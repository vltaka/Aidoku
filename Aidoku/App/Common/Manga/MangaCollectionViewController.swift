//
//  MangaCollectionViewController.swift
//  Aidoku
//
//  Created by Skitty on 11/19/25.
//

import AidokuRunner
import Combine
import SwiftUI

class MangaCollectionViewController: BaseCollectionViewController {
    var usesListLayout = false

    private var waterfallRelayoutWorkItem: DispatchWorkItem?

    /// Coalesce cover aspect ratio updates into a single waterfall relayout,
    /// so a page of covers loading at once doesn't cause repeated layout passes.
    func scheduleWaterfallRelayout() {
        guard collectionView.collectionViewLayout is MangaWaterfallLayout else { return }
        waterfallRelayoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.collectionView.collectionViewLayout is MangaWaterfallLayout else { return }
            if self.collectionView.isDragging || self.collectionView.isDecelerating {
                // don't reshuffle cells mid-scroll; retry once scrolling settles
                self.scheduleWaterfallRelayout()
                return
            }
            self.collectionView.collectionViewLayout.invalidateLayout()
        }
        waterfallRelayoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    lazy var dataSource = makeDataSource()
    lazy var refreshControl = UIRefreshControl()
    lazy var errorView = SourceErrorView()

    var entries: [AidokuRunner.Manga] = []
    var bookmarkedItems: Set<String> = []

    struct SkeletonView: View {
        let usesListLayout: Bool
        let containerWidth: CGFloat

        var body: some View {
            if usesListLayout {
                PlaceholderMangaHomeList.mainView(itemCount: 10)
                    .redacted(reason: .placeholder)
                    .shimmering()
            } else {
                GeometryReader { geometry in
                    HomeGridView.placeholder(width: containerWidth, availableWidth: geometry.size.width)
                }
            }
        }
    }
    lazy var skeletonViewController = {
        let hostingController = UIHostingController(rootView: SkeletonView(usesListLayout: usesListLayout, containerWidth: 0))
        hostingController.view.backgroundColor = .clear
        hostingController.view.clipsToBounds = false
        return hostingController
    }()

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let width = collectionView.bounds.width
        guard skeletonViewController.parent != nil, skeletonViewController.rootView.containerWidth != width else { return }
        skeletonViewController.rootView = SkeletonView(usesListLayout: usesListLayout, containerWidth: width)
    }

    override func configure() {
        super.configure()
        collectionView.dataSource = dataSource
        collectionView.contentInset = UIEdgeInsets(
            top: 0,
            left: 0,
            bottom: 10,
            right: 0
        )
        collectionView.keyboardDismissMode = .onDrag

        // pull to refresh
        refreshControl.addTarget(self, action: #selector(refresh(_:)), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        errorView.hide(animated: false)
        view.addSubview(errorView)

        addChild(skeletonViewController)
        collectionView.addSubview(skeletonViewController.view)
        skeletonViewController.didMove(toParent: self)
    }

    override func constrain() {
        super.constrain()

        errorView.translatesAutoresizingMaskIntoConstraints = false
        skeletonViewController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            errorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            errorView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            skeletonViewController.view.topAnchor.constraint(equalTo: collectionView.safeAreaLayoutGuide.topAnchor),
            skeletonViewController.view.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
            skeletonViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeletonViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func observe() {
        super.observe()

        addObserver(forName: AppSettings.appearance.layout.key) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.collectionView.collectionViewLayout = self.makeCollectionViewLayout()
            }
        }
        for key in [AppSettings.appearance.customPortraitRows.key, AppSettings.appearance.customLandscapeRows.key] {
            addObserver(forName: key) { [weak self] _ in
                Task { @MainActor in
                    self?.collectionView.collectionViewLayout.invalidateLayout()
                }
            }
        }
        addObserver(forName: CoverAspectCache.didUpdateNotification) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleWaterfallRelayout()
            }
        }

        addObserver(forName: .addToLibrary) { [weak self] notification in
            guard
                let self,
                let id = notification.object as? MangaIdentifier,
                let index = self.entries.firstIndex(where: { $0.identifier == id }),
                let entry = self.dataSource.itemIdentifier(for: IndexPath(item: index, section: 0))
            else {
                return
            }
            if self.bookmarkedItems.insert(entry.key).inserted {
                self.updateBookmarkBadge(for: entry)
            }
        }

        addObserver(forName: .removeFromLibrary) { [weak self] notification in
            guard
                let self,
                let id = notification.object as? MangaIdentifier,
                let index = self.entries.firstIndex(where: { $0.identifier == id }),
                let entry = self.dataSource.itemIdentifier(for: IndexPath(item: index, section: 0))
            else {
                return
            }
            if self.bookmarkedItems.remove(entry.key) != nil {
                self.updateBookmarkBadge(for: entry)
            }
        }
    }

    /// Update a manga's bookmark badge in place, without reloading its cell.
    /// Reloading the cell resets its cover to the placeholder and re-runs
    /// the image request, which leaves a visible hole while the (possibly
    /// slow) request completes — the badge is the only thing that changes.
    func updateBookmarkBadge(for manga: AidokuRunner.Manga) {
        guard
            let indexPath = dataSource.indexPath(for: manga),
            let cell = collectionView.cellForItem(at: indexPath)
        else { return }
        let bookmarked = bookmarkedItems.contains(manga.key)
        if let cell = cell as? MangaGridCell {
            cell.showsBookmark = bookmarked
        } else if let cell = cell as? MangaListCell {
            cell.setBookmarked(bookmarked)
        } else if let cell = cell as? MangaWaterfallCell {
            cell.showsBookmark = bookmarked
        }
    }

    // MARK: Collection View Layout
    override func makeCollectionViewLayout() -> UICollectionViewLayout {
        if !usesListLayout, AppSettings.appearance.layout.get() == .waterfall {
            let layout = MangaWaterfallLayout()
            layout.delegate = self
            return layout
        }
        return UICollectionViewCompositionalLayout { sectionIndex, environment in
            switch Section(rawValue: sectionIndex) {
                case .regular:
                    if self.usesListLayout {
                        return OldMangaCollectionViewController.makeListLayoutSection(environment: environment)
                    } else {
                        return OldMangaCollectionViewController.makeGridLayoutSection(environment: environment)
                    }
                case nil:
                    return nil
            }
        }
    }
}

extension MangaCollectionViewController {
    @objc func refresh(_ control: UIRefreshControl) {
        control.endRefreshing()
    }

    func hideLoadingView() {
        UIView.animate(withDuration: CATransaction.animationDuration()) {
            self.skeletonViewController.view.alpha = 0
        } completion: { _ in
            self.skeletonViewController.view.removeFromSuperview()
            self.skeletonViewController.removeFromParent()
        }
    }
}

extension MangaCollectionViewController {
    // MARK: Cell Registration
    typealias GridCellRegistration = UICollectionView.CellRegistration<MangaGridCell, AidokuRunner.Manga>
    typealias ListCellRegistration = UICollectionView.CellRegistration<MangaListCell, AidokuRunner.Manga>

    func makeGridCellRegistration() -> GridCellRegistration {
        GridCellRegistration { [weak self] cell, _, manga in
            cell.identifier = MangaIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key)
            cell.title = manga.title
            cell.showsBookmark = self?.bookmarkedItems.contains(manga.key) ?? false
            Task {
                await cell.loadImage(url: manga.cover.flatMap { URL(string: $0) })
            }
        }
    }

    func makeListCellRegistration() -> ListCellRegistration {
        ListCellRegistration { [weak self] cell, _, manga in
            cell.configure(with: manga, isBookmarked: self?.bookmarkedItems.contains(manga.key) ?? false)
        }
    }

    // MARK: Data Source
    enum Section: Int, CaseIterable {
        case regular
    }

    func makeDataSource() -> UICollectionViewDiffableDataSource<Section, AidokuRunner.Manga> {
        if usesListLayout {
            return UICollectionViewDiffableDataSource(
                collectionView: collectionView,
                cellProvider: makeListCellRegistration().cellProvider
            )
        } else {
            collectionView.register(MangaWaterfallCell.self, forCellWithReuseIdentifier: "MangaWaterfallCell")
            let gridProvider = makeGridCellRegistration().cellProvider
            return UICollectionViewDiffableDataSource(
                collectionView: collectionView
            ) { [weak self] collectionView, indexPath, manga in
                // the waterfall layout uses the text-below-cover cell;
                // the regular grid keeps the overlay-title cell
                if collectionView.collectionViewLayout is MangaWaterfallLayout {
                    // swiftlint:disable:next force_cast
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: "MangaWaterfallCell",
                        for: indexPath
                    ) as! MangaWaterfallCell
                    self?.configure(cell: cell, manga: manga)
                    return cell
                }
                return gridProvider(collectionView, indexPath, manga)
            }
        }
    }

    func configure(cell: MangaWaterfallCell, manga: AidokuRunner.Manga) {
        cell.identifier = MangaIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key)
        cell.setContent(
            title: manga.title,
            tags: manga.tags ?? [],
            language: CoverLanguageBadge.text(for: SourceManager.shared.store.source(for: manga.sourceKey)),
            aspectRatio: CoverAspectCache.shared.aspectRatio(for: manga.cover) ?? (2.0 / 3.0),
            bookmarked: bookmarkedItems.contains(manga.key)
        )
        Task {
            await cell.loadImage(url: manga.cover.flatMap { URL(string: $0) })
        }
    }

    func updateDataSource() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, AidokuRunner.Manga>()
        snapshot.appendSections([.regular])
        snapshot.appendItems(entries.unique(), toSection: .regular)
        dataSource.apply(snapshot)
    }

    func clearEntries() {
        dataSource.apply(.init())
    }
}

// MARK: UICollectionViewDelegate
extension MangaCollectionViewController {
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        let cell = collectionView.cellForItem(at: indexPath)
        if let cell = cell as? MangaGridCell {
            cell.highlight()
        } else if let cell = cell as? MangaListCell {
            cell.highlight()
        } else if let cell = cell as? MangaWaterfallCell {
            cell.highlight()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        let cell = collectionView.cellForItem(at: indexPath)
        if let cell = cell as? MangaGridCell {
            cell.unhighlight()
        } else if let cell = cell as? MangaListCell {
            cell.unhighlight()
        } else if let cell = cell as? MangaWaterfallCell {
            cell.unhighlight()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let manga = dataSource.itemIdentifier(for: indexPath) else {
            return
        }
        let viewController = MangaViewController(manga: manga, parent: self)
        if #available(iOS 18.0, *) {
            viewController.preferredTransition = .zoom { context in
                guard
                    let detailViewController = context.zoomedViewController as? MangaViewController,
                    let indexPath = self.dataSource.indexPath(for: detailViewController.manga),
                    let cell = self.collectionView.cellForItem(at: indexPath)
                else {
                    return nil
                }
                if let cell = cell as? MangaListCell {
                    return cell.coverImageView
                } else {
                    return cell.contentView
                }
            }
        }
        navigationController?.pushViewController(viewController, animated: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            indexPaths.count == 1,
            let indexPath = indexPaths.first,
            let entry = dataSource.itemIdentifier(for: indexPath)
        else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ -> UIMenu? in
            guard let self else { return nil }

            var actions: [UIAction] = []

            if entry.isLocal() {
                actions.append(UIAction(
                    title: NSLocalizedString("REMOVE"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    Task {
                        await LocalFileManager.shared.removeManga(with: entry.key)
                        NotificationCenter.default.post(name: .init("refresh-content"), object: nil)
                    }
                })
            }

            let inLibrary = bookmarkedItems.contains(entry.key)
            if inLibrary {
                actions.append(UIAction(
                    title: NSLocalizedString("REMOVE_FROM_LIBRARY"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in
                    let isTracking = TrackerManager.shared.isTracking(mangaId: entry.identifier)
                    @MainActor
                    func commit() {
                        // remove bookmark icon
                        self.bookmarkedItems.remove(entry.key)
                        self.updateBookmarkBadge(for: entry)
                        // remove from library
                        Task {
                            await MangaManager.shared.removeFromLibrary(mangaId: entry.identifier)
                        }
                    }
                    if isTracking {
                        self.presentAlert(
                            title: NSLocalizedString("REMOVE_FROM_LIBRARY_CONFIRM"),
                            message: NSLocalizedString("REMOVE_FROM_LIBRARY_CONFIRM_TEXT"),
                            actions: [
                                UIAlertAction(title: NSLocalizedString("CANCEL"), style: .cancel),
                                UIAlertAction(title: NSLocalizedString("REMOVE"), style: .destructive) { _ in
                                    commit()
                                }
                            ]
                        )
                    } else {
                        commit()
                    }
                })
            } else {
                actions.append(UIAction(
                    title: NSLocalizedString("ADD_TO_LIBRARY"),
                    image: UIImage(systemName: "plus.circle")
                ) { _ in
                    Task {
                        if await MangaManager.shouldAskForCategories() {
                            // open category select view
                            let viewController = UINavigationController(rootViewController: CategorySelectViewController(manga: entry))
                            self.present(viewController, animated: true)
                        } else {
                            // add bookmark icon
                            self.bookmarkedItems.insert(entry.key)
                            self.updateBookmarkBadge(for: entry)

                            // add to library
                            await MangaManager.shared.addToLibrary(
                                manga: entry,
                                fetchMangaDetails: true
                            )
                        }
                    }
                })
            }

            return UIMenu(title: "", children: actions)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        guard
            let cell = collectionView.cellForItem(at: indexPath),
            cell is MangaListCell
        else {
            return nil
        }

        // add some padding to list cell
        let parameters = UIPreviewParameters()
        let padding: CGFloat = 8
        let rect = cell.bounds.insetBy(dx: -padding, dy: -padding)
        parameters.visiblePath = UIBezierPath(roundedRect: rect, cornerRadius: 12)

        return UITargetedPreview(view: cell.contentView, parameters: parameters)
    }
}

// MARK: - Waterfall Layout Delegate
extension MangaCollectionViewController: MangaWaterfallLayoutDelegate {
    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        aspectRatioForItemAt indexPath: IndexPath
    ) -> CGFloat {
        let cover = dataSource.itemIdentifier(for: indexPath)?.cover
        return CoverAspectCache.shared.aspectRatio(for: cover) ?? (2.0 / 3.0)
    }

    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        textHeightForItemAt indexPath: IndexPath,
        width: CGFloat
    ) -> CGFloat {
        guard let manga = dataSource.itemIdentifier(for: indexPath) else { return 0 }
        return WaterfallItemMetrics.textHeight(
            title: manga.title,
            tags: manga.tags ?? [],
            width: width
        )
    }

    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        itemIdentifierAt indexPath: IndexPath
    ) -> AnyHashable? {
        dataSource.itemIdentifier(for: indexPath).map {
            AnyHashable("\($0.sourceKey)|\($0.key)|\($0.cover ?? "")")
        }
    }
}
