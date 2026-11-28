//
//  ListingGridView.swift
//  Aidoku
//
//  The category/listing grid as a UIKit collection view, hosted in
//  the source home's SwiftUI tree. The SwiftUI grid this replaces
//  realized its cells lazily and steered scrolling by item identity,
//  which lost the scroll position whenever the view tree was rebuilt
//  (e.g. after the app spent time in the background): the position
//  came back at the top, and scroll-to bookkeeping could never
//  reliably put it back, because an item that does not exist yet
//  cannot be scrolled to. The collection view below computes every
//  item's frame up front (see MangaWaterfallLayout) and simply keeps
//  its scroll offset, so the position survives by construction — the
//  same reason the library and history pages never had the problem.
//

import AidokuRunner
import SwiftUI
import UIKit

struct ListingGridView: UIViewControllerRepresentable {
    let entries: [AidokuRunner.Manga]
    let bookmarkedItems: Set<String>
    var onLoadMore: () -> Void
    var onRefresh: () async -> Void

    func makeUIViewController(context: Context) -> ListingMangaCollectionViewController {
        let viewController = ListingMangaCollectionViewController()
        viewController.onLoadMore = onLoadMore
        viewController.onRefresh = onRefresh
        viewController.entries = entries
        viewController.bookmarkedItems = bookmarkedItems
        viewController.updateDataSource()
        return viewController
    }

    func updateUIViewController(_ viewController: ListingMangaCollectionViewController, context: Context) {
        viewController.onLoadMore = onLoadMore
        viewController.onRefresh = onRefresh
        if viewController.bookmarkedItems != bookmarkedItems {
            let changed = viewController.bookmarkedItems.symmetricDifference(bookmarkedItems)
            viewController.bookmarkedItems = bookmarkedItems
            for entry in viewController.entries where changed.contains(entry.key) {
                viewController.updateBookmarkBadge(for: entry)
            }
        }
        if viewController.entries != entries {
            viewController.entries = entries
            viewController.updateDataSource()
        }
    }
}

final class ListingMangaCollectionViewController: MangaCollectionViewController {
    var onLoadMore: (() -> Void)?
    var onRefresh: (() async -> Void)?

    override func configure() {
        super.configure()
        // the parent only shows this controller once content has
        // landed, so its skeleton is removed outright rather than
        // faded (a fade would flash the skeleton over the real grid
        // on every listing switch)
        skeletonViewController.view.removeFromSuperview()
        skeletonViewController.removeFromParent()
        // the base controller's refresh control only ends its own
        // animation; swap in one that actually reloads the listing
        collectionView.refreshControl = nil
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
        collectionView.refreshControl = control
    }

    @objc private func pullToRefresh(_ control: UIRefreshControl) {
        guard let onRefresh else {
            control.endRefreshing()
            return
        }
        Task {
            await onRefresh()
            control.endRefreshing()
        }
    }
}

extension ListingMangaCollectionViewController {
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        // start the next page before the last items reach the screen;
        // the parent decides whether more pages exist and whether a
        // load is already running
        if indexPath.item >= entries.count - 9 {
            onLoadMore?()
        }
    }
}
