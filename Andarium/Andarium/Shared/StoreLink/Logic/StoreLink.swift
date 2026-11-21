// SPDX-License-Identifier: GPL-2.0-or-later

#if TESTFLIGHT_STORE_LINK

import Foundation

// The App Store notice's logic: the address of the application's App Store
// page, built from the identifier the build reads from the ignored local
// configuration, and the record of a dismissed card. The application compiles
// these files with the rest of the notice, and only where it is compiled in;
// the AndariumCore package compiles the same files for its tests
// (Andarium/README.md#app-store-notice).

/// The App Store page of this application, from its identifier ("id" and
/// digits, as the page's address spells it).
nonisolated struct StoreLink: Equatable, Sendable {
    let identifier: String

    /// nil unless the identifier is `id` and 5 to 15 digits: the one shape the
    /// App Store bundle check holds the build's identifier to
    /// (`Andarium/scripts/check-app-store-bundle.py`, which also refuses the
    /// all-zero placeholder the tests' arrangement uses in a TestFlight build).
    init?(identifier: String) {
        let bytes = Array(identifier.utf8)
        guard bytes.count >= 7, bytes.count <= 17, bytes[0] == 0x69, bytes[1] == 0x64 else { return nil }
        let digits = bytes.dropFirst(2)
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        self.identifier = identifier
    }

    /// The application's page, with no storefront in it and no action: the
    /// App Store opens it in the person's own.
    var url: URL {
        // The identifier holds letters and digits only, so the address is always valid.
        URL(string: "https://apps.apple.com/app/\(identifier)")!
    }
}

/// Where the identifier is read from.
nonisolated enum StoreLinkConfiguration {
    /// The Info.plist key the build writes the identifier to, only where the
    /// notice is compiled in (`Config/Andarium.xcconfig`). It is not Review on
    /// the App Store's key: a TestFlight build has no Review item.
    static let key = "AndariumStoreLinkID"

    /// The link in a property list (the application's Info.plist); nil when
    /// the key is absent or its value is not an App Store identifier, which
    /// hides the card and the Info row.
    static func link(in info: [String: Any]?) -> StoreLink? {
        guard let identifier = info?[key] as? String else { return nil }
        return StoreLink(identifier: identifier)
    }

    /// The link this build names.
    static var link: StoreLink? { link(in: Bundle.main.infoDictionary) }
}

/// Whether the card has been put away, kept for the installation in the
/// defaults database. It is permanent: nothing about the build number, the
/// virtual machine or an erase reads or clears it.
nonisolated struct StoreNoticeRecord {
    /// The stored value's key in the defaults database.
    static let key = "andarium.storenotice.dismissed"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The last value kept; false until the card is dismissed.
    var isDismissed: Bool { defaults.bool(forKey: Self.key) }

    func dismiss() {
        defaults.set(true, forKey: Self.key)
    }
}

/// What the notice shows. Pure, so a host test holds every case.
nonisolated enum StoreNoticeRule {
    /// The card (first on Home and on Welcome): the build names the page and
    /// the person has not dismissed it.
    static func showsCard(link: StoreLink?, dismissed: Bool) -> Bool {
        link != nil && !dismissed
    }

    /// The Info row, the way back to the page after the card is gone: the
    /// build names the page, whatever became of the card.
    static func showsRow(link: StoreLink?) -> Bool {
        link != nil
    }
}

#endif
