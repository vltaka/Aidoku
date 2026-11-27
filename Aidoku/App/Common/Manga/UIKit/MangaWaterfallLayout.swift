//
//  MangaWaterfallLayout.swift
//  Aidoku
//
//  A masonry (waterfall) collection view layout: items keep the aspect
//  ratio of their cover image instead of being cropped into a uniform
//  grid. Frames for every item are computed once per layout pass and
//  cached, so scrolling performs no per-frame work.
//

import UIKit

protocol MangaWaterfallLayoutDelegate: AnyObject {
    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        aspectRatioForItemAt indexPath: IndexPath
    ) -> CGFloat

    /// Height of the text block (title + tag chips) shown below the cover
    /// for the item at the given width. Zero for cover-only items.
    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        textHeightForItemAt indexPath: IndexPath,
        width: CGFloat
    ) -> CGFloat

    /// A stable identifier for the item, if the data source has one.
    /// When provided, the layout pins the height it first computes for
    /// that item (per column width) and never revises it: cover ratios
    /// arriving later, or any other relayout, then can't move items
    /// that are already placed.
    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        itemIdentifierAt indexPath: IndexPath
    ) -> AnyHashable?
}

extension MangaWaterfallLayoutDelegate {
    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        textHeightForItemAt indexPath: IndexPath,
        width: CGFloat
    ) -> CGFloat {
        0
    }

    func waterfallLayout(
        _ layout: MangaWaterfallLayout,
        itemIdentifierAt indexPath: IndexPath
    ) -> AnyHashable? {
        nil
    }
}

final class MangaWaterfallLayout: UICollectionViewLayout {
    weak var delegate: MangaWaterfallLayoutDelegate?

    var itemSpacing: CGFloat = OldMangaCollectionViewController.itemSpacing
    var sectionInset: UIEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    var headerHeight: CGFloat = 0

    /// Column counts supplied by the owning controller. Nil follows the
    /// global custom rows; the library sets its own counts so its
    /// waterfall sizes independently of the global setting.
    var rowsOverride: (portrait: Int, landscape: Int)?

    private var cellAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var headerAttributes: UICollectionViewLayoutAttributes?
    private var contentHeight: CGFloat = 0

    /// Total item heights pinned by item identifier (and column width):
    /// the first height computed for an item is the height it keeps.
    private var pinnedHeights: [AnyHashable: CGFloat] = [:]

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        cellAttributes.removeAll()
        headerAttributes = nil

        let width = collectionView.bounds.width
        let isLandscape = width > collectionView.bounds.height
        let unclampedColumns = if let rowsOverride {
            isLandscape ? rowsOverride.landscape : rowsOverride.portrait
        } else {
            OldMangaCollectionViewController.getGridItemsPerRow(
                containerWidth: width,
                isLandscape: isLandscape,
                layout: .custom
            )
        }
        let columns = max(1, unclampedColumns)
        let contentWidth = width - sectionInset.left - sectionInset.right
        let columnWidth = (contentWidth - CGFloat(columns - 1) * itemSpacing) / CGFloat(columns)

        var columnHeights = [CGFloat](repeating: sectionInset.top, count: columns)

        if headerHeight > 0 {
            let attributes = UICollectionViewLayoutAttributes(
                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                with: IndexPath(item: 0, section: 0)
            )
            attributes.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            headerAttributes = attributes
            columnHeights = [CGFloat](repeating: headerHeight, count: columns)
        }

        for section in 0..<collectionView.numberOfSections {
            if section > 0 {
                let start = (columnHeights.max() ?? sectionInset.top) + itemSpacing
                columnHeights = [CGFloat](repeating: start, count: columns)
            }
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                let height: CGFloat
                let pinKey = delegate?.waterfallLayout(self, itemIdentifierAt: indexPath)
                    .map { AnyHashable("\($0)|\(Int(columnWidth.rounded()))") }
                if let pinKey, let pinned = pinnedHeights[pinKey] {
                    height = pinned
                } else {
                    let ratio = delegate?.waterfallLayout(self, aspectRatioForItemAt: indexPath) ?? (2.0 / 3.0)
                    let textHeight = delegate?.waterfallLayout(
                        self,
                        textHeightForItemAt: indexPath,
                        width: columnWidth
                    ) ?? 0
                    height = columnWidth / min(max(ratio, 0.2), 5) + textHeight
                    if let pinKey {
                        if pinnedHeights.count > 20000 { pinnedHeights.removeAll() }
                        pinnedHeights[pinKey] = height
                    }
                }

                var column = 0
                for index in 1..<columns where columnHeights[index] < columnHeights[column] {
                    column = index
                }

                let x = sectionInset.left + CGFloat(column) * (columnWidth + itemSpacing)
                let y = columnHeights[column]
                let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                attributes.frame = CGRect(x: x, y: y, width: columnWidth, height: height)
                cellAttributes[indexPath] = attributes
                columnHeights[column] = y + height + itemSpacing
            }
        }

        let maxHeight = columnHeights.max() ?? sectionInset.top
        contentHeight = if cellAttributes.isEmpty {
            maxHeight
        } else {
            maxHeight - itemSpacing + sectionInset.bottom
        }
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result = cellAttributes.values.filter { $0.frame.intersects(rect) }
        if let headerAttributes, headerAttributes.frame.intersects(rect) {
            result.append(headerAttributes)
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cellAttributes[indexPath]
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        elementKind == UICollectionView.elementKindSectionHeader ? headerAttributes : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let oldBounds = collectionView?.bounds else { return false }
        return oldBounds.width != newBounds.width || oldBounds.height != newBounds.height
    }
}
