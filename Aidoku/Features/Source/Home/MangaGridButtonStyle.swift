//
//  MangaGridButtonStyle.swift
//  Aidoku
//
//  Created by Skitty on 10/13/23.
//

import SwiftUI

struct MangaGridButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // no pressed overlay: the cover used to be painted 50% black for
        // as long as it was pressed, which read as the cover "going
        // black" on every long press before the context menu appeared.
        // The menu's lifted preview is the only press feedback now.
        configuration.label
    }
}
