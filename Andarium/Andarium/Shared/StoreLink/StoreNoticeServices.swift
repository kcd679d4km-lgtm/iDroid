// SPDX-License-Identifier: GPL-2.0-or-later

#if TESTFLIGHT_STORE_LINK

import UIKit

/// What the App Store notice asks of the build and of the system, in one place
/// a test replaces. A launch of the application has the live ones.
struct StoreNoticeServices {
    /// The page's identifier, from Info.plist; nil when it is absent or not an
    /// App Store identifier, which hides the card and the Info row.
    var link: @MainActor () -> StoreLink? = { StoreLinkConfiguration.link }
    /// Hands the address to the system, which opens the App Store's page (the
    /// call SwiftUI's `openURL` ends in). No web view, no StoreKit sheet.
    var open: @MainActor (URL) -> Void = { UIApplication.shared.open($0, options: [:], completionHandler: nil) }
    /// Whether the card was put away, kept for the installation.
    var record = StoreNoticeRecord()
}

extension AppModel {
    /// The page this build points to, when it names one.
    var storeLink: StoreLink? { storeNoticeServices.link() }

    /// The card is up: the build names the page and the person has not put it
    /// away.
    var storeNoticeShown: Bool {
        StoreNoticeRule.showsCard(link: storeLink, dismissed: storeNoticeDismissed)
    }

    /// Opens the application's App Store page. The card stays: only its close
    /// button puts it away.
    func openStoreLink() {
        guard let link = storeLink else { return }
        storeNoticeServices.open(link.url)
    }

    /// The person puts the card away, for good on this installation. Info keeps
    /// its row.
    func dismissStoreNotice() {
        storeNoticeServices.record.dismiss()
        storeNoticeDismissed = true
    }
}

#endif
