//
//  ReaderSettings.swift
//  Aidoku
//
//  Created by skitty on 8/29/26.
//

struct ReaderSettings: Sendable {
    var keys: [any SettingsDefault] {
        [
            autoScrollPosition,
            upscaleQuality,
            menuTapArea,
            autoScrollPauseOnBars
        ]
    }

    // todo: move reader settings here

    let autoScrollPosition = SettingsKey<AutoScrollPosition>("Reader.autoScrollPosition", default: .right)
    let upscaleQuality = SettingsKey<UpscaleQuality>("Reader.upscaleQuality", default: .fast)
    let menuTapArea = SettingsKey<MenuTapArea>("Reader.menuTapArea", default: .half)
    let autoScrollPauseOnBars = SettingsKey<Bool>("Reader.autoScrollPauseOnBars", default: true)
}
