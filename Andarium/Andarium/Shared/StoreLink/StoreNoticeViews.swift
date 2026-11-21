// SPDX-License-Identifier: GPL-2.0-or-later

#if TESTFLIGHT_STORE_LINK

import SwiftUI

/// The App Store version's icon, small: the stack on the jade ground, as the
/// icon shows on the Home Screen. The TestFlight build's own icon is another
/// (`Shared/DuskEmber.icon`), so this is the picture of the version the notice
/// points to. Decorative.
struct StoreNoticeIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 30

    var body: some View {
        let radius = size * 0.225
        StackMark(lit: true, width: size * 0.64)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: ground, startPoint: .top, endPoint: .bottom))
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    /// The icon's own ground (`Shared/DuskJade.icon`), in each appearance.
    private var ground: [Color] {
        colorScheme == .dark
            ? [Color(red: 0.063, green: 0.098, blue: 0.090), Color(red: 0.012, green: 0.024, blue: 0.024)]
            : [Color(red: 0.082, green: 0.125, blue: 0.118), Color(red: 0.020, green: 0.039, blue: 0.035)]
    }
}

/// The words of the notice, in the `StoreLink` table. The three long texts
/// are shown with a no-break space inside "App Store", so that a line never
/// ends between its two words; the table holds the words as written.
enum StoreNoticeWords {
    static var title: String { String(localized: "Andarium is on the App Store", table: "StoreLink") }
    static var text: String {
        tied(String(
            localized: "Stay on this TestFlight beta for the latest features, or get the App Store version for a more stable experience.",
            table: "StoreLink"))
    }
    static var caution: String {
        tied(String(
            localized: "Switching keeps your virtual machine, but it may not start until the App Store version catches up with this beta.",
            table: "StoreLink"))
    }
    static var action: String { String(localized: "View in App Store", table: "StoreLink") }
    static var actionHint: String { String(localized: "Opens the App Store", table: "StoreLink") }
    static var row: String { String(localized: "Andarium on the App Store", table: "StoreLink") }
    static var rowNote: String {
        tied(String(
            localized: "New features arrive in this TestFlight beta first. The App Store version is more stable.",
            table: "StoreLink"))
    }

    /// `text` with a no-break space between the two words of the store's name.
    static func tied(_ text: String) -> String {
        text.replacingOccurrences(of: "App Store", with: "App\u{00A0}Store")
    }
}

/// The card that points a TestFlight tester to the App Store version, first
/// among Home's notices and under the title of Welcome: the notice component
/// with the App Store version's icon in place of a symbol, the message, the
/// caution, one button and the close mark. The button opens the App Store page
/// through the system; only the close mark puts the card away, for good.
struct StoreNoticeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.storeNoticeShown {
            NoticeCard(
                symbol: "arrow.down.app", color: .accentColor,
                title: StoreNoticeWords.title, text: StoreNoticeWords.text,
                action: NoticeAction(
                    label: StoreNoticeWords.action, hint: StoreNoticeWords.actionHint,
                    identifier: "store-notice-open", perform: { model.openStoreLink() }),
                onClose: { withAnimation { model.dismissStoreNotice() } },
                picture: AnyView(StoreNoticeIcon(size: 40)),
                note: StoreNoticeWords.caution,
                buttonIsOwnElement: true
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("store-notice")
        }
    }
}

/// The row of Info that opens the App Store page through the system, with a
/// note beneath it: the way back to the page once the card is gone.
struct StoreLinkSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if StoreNoticeRule.showsRow(link: model.storeLink), let link = model.storeLink {
            Section {
                Link(destination: link.url) {
                    HStack(spacing: 12) {
                        StoreNoticeIcon(size: 30)
                        Text(StoreNoticeWords.row)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(StoreNoticeWords.row)
                .accessibilityIdentifier("info-store-link")
                .environment(\.openURL, OpenURLAction { url in
                    model.storeNoticeServices.open(url)
                    return .handled
                })
            } footer: {
                Text(StoreNoticeWords.rowNote)
            }
        }
    }
}

#endif
