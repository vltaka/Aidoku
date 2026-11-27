//
//  MenuTapArea.swift
//  Aidoku
//

import Foundation

extension ReaderSettings {
    enum MenuTapArea: String, SettingsValue, CaseIterable {
        case full
        case third
        case half
        case twoThirds

        var title: String {
            switch self {
                case .full: NSLocalizedString("TAP_AREA_FULL")
                case .third: NSLocalizedString("TAP_AREA_THIRD")
                case .half: NSLocalizedString("TAP_AREA_HALF")
                case .twoThirds: NSLocalizedString("TAP_AREA_TWO_THIRDS")
            }
        }

        /// Width of the active center band as a fraction of the view width, or nil when taps anywhere count.
        var centerFraction: CGFloat? {
            switch self {
                case .full: nil
                case .third: 1.0 / 3.0
                case .half: 1.0 / 2.0
                case .twoThirds: 2.0 / 3.0
            }
        }
    }
}
