//
//  MangaCoverView.swift
//  Aidoku
//
//  Created by Skitty on 9/8/23.
//

import AidokuRunner
import SwiftUI
import Nuke
import NukeUI

struct MangaCoverView: View {
    var source: AidokuRunner.Source?

    let coverImage: String
    var width: CGFloat?
    var height: CGFloat?
    var downsampleWidth: CGFloat?
    var contentMode: ContentMode = .fill
    var placeholder = "MangaPlaceholder"
    var bookmarked: Bool = false
    // optional language badge for the cover's top-left corner, in the
    // same style as the waterfall items' badge; nil shows nothing
    var languageBadgeText: String? = nil

    var body: some View {
        SourceImageView(
            source: source,
            imageUrl: coverImage,
            width: width,
            height: height,
            downsampleWidth: downsampleWidth,
            contentMode: contentMode,
            placeholder: placeholder
        )
        .overlay(
            bookmarkView,
            alignment: .topTrailing
        )
        .overlay(
            languageBadgeView,
            alignment: .topLeading
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(UIColor.quaternarySystemFill), lineWidth: 1)
        )
    }

    @ContentBuilder
    var languageBadgeView: some View {
        if let languageBadgeText, !languageBadgeText.isEmpty {
            Text(languageBadgeText.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(5)
        } else {
            EmptyView()
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
