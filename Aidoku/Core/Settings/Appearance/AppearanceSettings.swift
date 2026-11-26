//
//  AppearanceSettings.swift
//  Aidoku
//
//  Created by skitty on 8/29/26.
//

import UIKit

struct AppearanceSettings: Sendable {
    var keys: [any SettingsDefault] {
        [
            useSystemAppearance,
            appearance,
            layout,
            customPortraitRows,
            customLandscapeRows,
            listCoverHeight,
            scrollerCoverHeight,
            listCoverFit
        ]
    }

    let useSystemAppearance = SettingsKey<Bool>("General.useSystemAppearance", default: true)
    let appearance = SettingsKey<Int>("General.appearance", default: 0)

    let layout = SettingsKey<Layout>("Appearance.layout", default: .standard)
    let customPortraitRows = SettingsKey<Int>("Appearance.customPortraitRows", default: UIDevice.current.userInterfaceIdiom == .pad ? 5 : 2)
    let customLandscapeRows = SettingsKey<Int>("Appearance.customLandscapeRows", default: UIDevice.current.userInterfaceIdiom == .pad ? 6 : 4)

    let listCoverHeight = SettingsKey<Double>("Appearance.listCoverHeight", default: 100)
    let scrollerCoverHeight = SettingsKey<Double>("Appearance.scrollerCoverHeight", default: 180)
    // when true, home ranking list covers are shown in full (aspect fit) instead of cropped (aspect fill)
    let listCoverFit = SettingsKey<Bool>("Appearance.listCoverFit", default: false)
}
