//
//  MangaWaterfallGridItem.swift
//  Aidoku
//
//  A grid item that keeps its cover's original aspect ratio instead of
//  cropping it into a uniform 2:3 frame, for use in waterfall layouts.
//  Visually mirrors MangaGridItem (gradient + title overlay).
//

import AidokuRunner
import SwiftUI

struct MangaWaterfallGridItem: View {
    var source: AidokuRunner.Source?
    let title: String
    let coverImage: String
    var bookmarked: Bool = false
    let aspectRatio: CGFloat // width / height

    var body: some View {
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
                LinearGradient(
                    gradient: MangaGridItem.gradient,
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                bookmarkView,
                alignment: .topTrailing
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(UIColor.quaternarySystemFill), lineWidth: 1)
            )
            .overlay(
                Text(title)
                    .foregroundStyle(.white)
                    .font(.system(size: 15, weight: .medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .padding(8),
                alignment: .bottomLeading
            )
        if coverImage.hasSuffix("gif") {
            view
        } else {
            view.drawingGroup()
        }
    }

    @ContentBuilder
    var bookmarkView: some View {
        if bookmarked {
            Image("bookmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
                .frame(width: 17, height: 27, alignment: .topTrailing)
                .padding(.trailing, 8)
        } else {
            EmptyView()
        }
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
