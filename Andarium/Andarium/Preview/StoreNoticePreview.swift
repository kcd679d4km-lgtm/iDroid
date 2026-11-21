// SPDX-License-Identifier: GPL-2.0-or-later

#if TESTFLIGHT_STORE_LINK

import Foundation
import UIKit

/// The Simulator preview's stand-ins for the App Store notice, so that a screen
/// does not depend on the Simulator's own state: the dismissal is kept in a
/// record of the launch's own (every launch starts with the card up), and the
/// button hands its address to an alert instead of the system, so nothing
/// leaves the application and no network is used. The address is the build's
/// (the arrangement's placeholder).
///
///     -storeNotice dismissed   the card is already put away: Home as it always was
enum StoreNoticePreview {
    private static let suite = "andarium.preview.storenotice"

    @MainActor
    static func configure(model: AppModel) {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let record = StoreNoticeRecord(defaults: defaults)
        if UserDefaults.standard.string(forKey: "storeNotice") == "dismissed" { record.dismiss() }
        model.storeNoticeServices = StoreNoticeServices(
            link: { StoreLinkConfiguration.link },
            open: { url in present(url) },
            record: record)
    }

    /// An alert over whatever is on screen that names the address the system
    /// would have been asked to open.
    @MainActor
    private static func present(_ url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(title: "Opens the App Store", message: url.absoluteString, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top.present(alert, animated: true)
    }
}

#endif
