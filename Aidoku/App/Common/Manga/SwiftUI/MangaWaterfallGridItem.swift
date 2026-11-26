//
//  MangaWaterfallGridItem.swift
//  Aidoku
//
//  A grid item that keeps its cover's original aspect ratio instead of
//  cropping it into a uniform 2:3 frame, for use in waterfall layouts.
//  The title and tag chips sit below the cover (nhentai-style), with an
//  optional language badge on the cover's top-left corner and an
//  optional source badge on its top-right corner (history only).
//

import AidokuRunner
import SwiftUI

/// Shared metrics for waterfall items with text below the cover. Every
/// waterfall surface (SwiftUI and UIKit) derives its item heights from
/// these numbers, so heights are known before anything renders and the
/// layout never has to reflow once text appears.
enum WaterfallItemMetrics {
    static let textTopSpacing: CGFloat = 6
    static let titleFont = UIFont.systemFont(ofSize: 15, weight: .medium)
    static let titleLineHeight: CGFloat = 20
    static let titleMaxLines = 2
    static let tagsTopSpacing: CGFloat = 4
    static let tagFont = UIFont.systemFont(ofSize: 11)
    static let tagChipHeight: CGFloat = 21
    static let tagRowSpacing: CGFloat = 4
    static let tagChipSpacing: CGFloat = 6
    static let tagChipHorizontalPadding: CGFloat = 16 // 8 on each side
    static let tagMaxRows = 2

    static func titleLineCount(title: String, width: CGFloat) -> Int {
        guard width > 0 else { return 1 }
        guard !title.isEmpty else { return 0 }
        let rect = (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont],
            context: nil
        )
        let lines = Int(ceil(rect.height / titleFont.lineHeight))
        return min(max(lines, 1), titleMaxLines)
    }

    /// Greedy packing of tag chips into at most `tagMaxRows` rows.
    static func tagRows(tags: [String], width: CGFloat) -> [[String]] {
        guard !tags.isEmpty, width > 0 else { return [] }
        var rows: [[String]] = []
        var current: [String] = []
        var currentWidth: CGFloat = 0
        for tag in tags {
            let chipWidth = ceil((tag as NSString).size(withAttributes: [.font: tagFont]).width)
                + tagChipHorizontalPadding
            let needed = current.isEmpty ? chipWidth : currentWidth + tagChipSpacing + chipWidth
            if needed <= width {
                current.append(tag)
                currentWidth = needed
            } else {
                rows.append(current)
                if rows.count == tagMaxRows { return rows }
                current = [tag]
                currentWidth = chipWidth
            }
        }
        if !current.isEmpty, rows.count < tagMaxRows {
            rows.append(current)
        }
        return rows
    }

    /// Height of the text block (title + tag chips) below a cover of the
    /// given width. Zero when there is nothing to show.
    static func textHeight(title: String, tags: [String], width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        let lines = titleLineCount(title: title, width: width)
        if lines > 0 {
            height += textTopSpacing + CGFloat(lines) * titleLineHeight
        }
        let rows = tagRows(tags: tags, width: width).count
        if rows > 0 {
            height += tagsTopSpacing + CGFloat(rows) * tagChipHeight + CGFloat(rows - 1) * tagRowSpacing
        }
        return height
    }
}

/// Language badge text for a cover. Manga data has no per-manga language
/// field, so a badge is only shown when the language is unambiguous:
/// either a chapter's own language, or a source that declares exactly
/// one language. Display form is the primary code, uppercased (ZH, EN…).
enum CoverLanguageBadge {
    static func text(forLanguageCode code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let primary = code.split(separator: "-").first.map(String.init) ?? code
        return primary.uppercased()
    }

    static func text(for source: AidokuRunner.Source?) -> String? {
        guard let source, source.languages.count == 1 else { return nil }
        return text(forLanguageCode: source.languages.first)
    }
}

struct MangaWaterfallGridItem: View {
    var source: AidokuRunner.Source?
    let title: String
    let coverImage: String
    var bookmarked: Bool = false
    let aspectRatio: CGFloat // width / height
    var tags: [String] = []
    var language: String?
    var sourceBadge: String?
    var itemWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverView

            if !title.isEmpty {
                Text(title)
                    .foregroundStyle(.primary)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(WaterfallItemMetrics.titleMaxLines)
                    .padding(.top, WaterfallItemMetrics.textTopSpacing)
            }

            if !tags.isEmpty {
                tagChips
            }
        }
    }

    @ViewBuilder
    private var coverView: some View {
        let view = Rectangle()
            .fill(Color.clear)
            .aspectRatio(min(max(aspectRatio, 0.2), 5), contentMode: .fill)
            .background {
                SourceImageView(
                    source: source,
                    imageUrl: coverImage,
                    downsampleWidth: 400
                )
            }
            .overlay(
                languageBadgeView,
                alignment: .topLeading
            )
            .overlay(
                trailingBadgeView,
                alignment: .topTrailing
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(UIColor.quaternarySystemFill), lineWidth: 1)
            )
        if coverImage.hasSuffix("gif") {
            view
        } else {
            view.drawingGroup()
        }
    }

    @ViewBuilder
    private var languageBadgeView: some View {
        if let language, !language.isEmpty {
            Text(language.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(5)
        }
    }

    @ViewBuilder
    private var trailingBadgeView: some View {
        if let sourceBadge, !sourceBadge.isEmpty {
            Text(sourceBadge)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(5)
        } else if bookmarked {
            Image("bookmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
                .frame(width: 17, height: 27, alignment: .topTrailing)
                .padding(.trailing, 8)
        }
    }

    private var tagChips: some View {
        let rows = WaterfallItemMetrics.tagRows(tags: tags, width: itemWidth)
        return VStack(alignment: .leading, spacing: WaterfallItemMetrics.tagRowSpacing) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: WaterfallItemMetrics.tagChipSpacing) {
                    ForEach(rows[row], id: \.self) { tag in
                        LabelView(text: tag)
                    }
                }
            }
        }
        .padding(.top, WaterfallItemMetrics.tagsTopSpacing)
    }
}

/// Greedy shortest-column distribution for SwiftUI waterfall layouts.
enum WaterfallDistributor {
    static func distribute(
        count: Int,
        columns: Int,
        heightForItem: (Int) -> CGFloat
    ) -> [[Int]] {
        guard columns > 0 else { return [] }
        var result = [[Int]](repeating: [], count: columns)
        var heights = [CGFloat](repeating: 0, count: columns)
        for index in 0..<count {
            var column = 0
            for candidate in 1..<columns where heights[candidate] < heights[column] {
                column = candidate
            }
            result[column].append(index)
            heights[column] += heightForItem(index)
        }
        return result
    }
}

/// Memoizes waterfall distributions so that late-arriving cover aspect
/// ratios (or other view updates) don't reshuffle items that are already
/// on screen. A distribution is recomputed only when its signature
/// changes (entries or column count).
final class WaterfallDistributionCache {
    private var distributions: [String: [[Int]]] = [:]
    private var signatures: [String: String] = [:]
    private var storedValues: [String: [String: CGFloat]] = [:]

    func distribution(key: String, signature: String, compute: () -> [[Int]]) -> [[Int]] {
        if signatures[key] == signature, let cached = distributions[key] {
            return cached
        }
        let result = compute()
        distributions[key] = result
        signatures[key] = signature
        return result
    }

    /// Aspect ratios captured when a distribution was computed, so items
    /// render with the exact ratios their placement assumed.
    func setValues(_ values: [String: CGFloat], for key: String) {
        storedValues[key] = values
    }

    func values(for key: String) -> [String: CGFloat]? {
        storedValues[key]
    }
}
