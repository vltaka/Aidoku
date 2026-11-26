//
//  CollectionView.swift
//  Aidoku
//
//  Created by Skitty on 1/1/25.
//

import SwiftUI

struct CollectionViewSection {
    let items: [AnyView]
}

struct CollectionView: UIViewControllerRepresentable {
    let sections: [CollectionViewSection]
    let layout: UICollectionViewCompositionalLayout
    // identifies the layout's parameters (e.g. the cover height); when it
    // changes, the live collection view swaps its layout in place instead
    // of the whole view being recreated
    var layoutToken: AnyHashable?
    let collectionViewController: UICollectionViewController

    init(sections: [CollectionViewSection], layout: UICollectionViewCompositionalLayout, layoutToken: AnyHashable? = nil) {
        self.sections = sections
        self.layout = layout
        self.layoutToken = layoutToken
        self.collectionViewController = UICollectionViewController(collectionViewLayout: layout)
    }

    func makeUIViewController(context: Context) -> UICollectionViewController {
        collectionViewController.collectionView.isScrollEnabled = false
        collectionViewController.collectionView.dataSource = context.coordinator
        collectionViewController.collectionView.register(UIHostingCollectionViewCell<AnyView>.self, forCellWithReuseIdentifier: "Cell")
        return collectionViewController
    }

    func updateUIViewController(_ uiViewController: UICollectionViewController, context: Context) {
        context.coordinator.parent = self
        // Reloading while a navigation transition is animating can shuffle
        // the hosted cells (they get reconfigured against mid-transition
        // geometry); defer the reload until the transition completes.
        if let transitionCoordinator = uiViewController.transitionCoordinator
            ?? uiViewController.navigationController?.transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak uiViewController] _ in
                guard let uiViewController else { return }
                context.coordinator.apply(to: uiViewController)
            }
        } else {
            context.coordinator.apply(to: uiViewController)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UICollectionViewDataSource {
        var parent: CollectionView
        private var appliedLayoutToken: AnyHashable?

        init(_ parent: CollectionView) {
            self.parent = parent
            self.appliedLayoutToken = parent.layoutToken
        }

        func apply(to viewController: UICollectionViewController) {
            let collectionView = viewController.collectionView
            // swap the layout in place when its parameters changed (e.g. the
            // cover height) instead of recreating the whole view, keeping
            // the scroll position
            if
                let collectionView,
                let token = parent.layoutToken,
                token != appliedLayoutToken
            {
                appliedLayoutToken = token
                let offset = collectionView.contentOffset
                collectionView.setCollectionViewLayout(parent.layout, animated: false)
                collectionView.contentOffset = offset
            }
            collectionView?.reloadData()
        }

        func numberOfSections(in collectionView: UICollectionView) -> Int {
           parent.sections.count
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.sections[section].items.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "Cell", for: indexPath)
                    as? UIHostingCollectionViewCell<AnyView>
            else { return UICollectionViewCell() }
            cell.configure(with: parent.sections[indexPath.section].items[indexPath.item])
            return cell
        }
    }
}

// MARK: - Layouts

typealias GetSection = (NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection

extension CollectionView {
    static func mangaListLayout(
        itemsPerPage: Int,
        totalItems: Int,
        itemHeight: CGFloat = 100
    ) -> (GetSection, CGFloat) {
        let spacing: CGFloat = 10

        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        ))

        let itemsPerPage = min(itemsPerPage, totalItems)
        let viewHeight = CGFloat(itemsPerPage) * itemHeight + CGFloat(itemsPerPage - 1) * spacing

        let getSection: (NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection = { environment in
            let columnsToFit = floor(environment.container.effectiveContentSize.width / 340)

            let regularGroup = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(0.9 / max(1, columnsToFit)),
                    heightDimension: .absolute(viewHeight)
                ),
                subitem: item,
                count: itemsPerPage
            )
            regularGroup.interItemSpacing = .fixed(spacing)
            regularGroup.edgeSpacing = .init(leading: .none, top: .none, trailing: .none, bottom: .none)

            let section = NSCollectionLayoutSection(group: regularGroup)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 40)
            section.orthogonalScrollingBehavior = totalItems > itemsPerPage ? .groupPaging : .none // disable paging if there are not enough items

            return section
        }

        return (getSection, viewHeight)
    }
}
