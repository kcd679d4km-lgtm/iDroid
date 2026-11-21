// SPDX-License-Identifier: GPL-2.0-or-later

#if TESTFLIGHT_STORE_LINK

import AndariumCore
import AndariumCoreTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The App Store notice of a TestFlight build, as the application draws it and
/// VoiceOver reads it: the card first on Home and on Welcome, and the row of
/// Info. A Debug build made with `STORE_LINK_ID=id0000000000` on the xcodebuild
/// line (a run without it does not build these tests); the identifiers here
/// are made up, and the system's `open` is replaced, so nothing opens and no
/// real address is in any test. SwiftUI publishes its accessibility elements
/// only while application accessibility is on (the Simulator preference
/// `ApplicationAccessibilityEnabled`), so a run without it fails with that
/// said.
@MainActor
@Suite(.serialized)
struct StoreNoticeTests {
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
    )
    private static let title = "Andarium is on the App Store"
    private static let button = "View in App Store"
    private static let row = "Andarium on the App Store"

    /// What the replaced `open` was asked to open, and the defaults the dismissal is kept in.
    @MainActor private final class Fixture {
        var urls: [URL] = []
        let suite = "andarium.tests.storenotice.\(UUID().uuidString)"
        let defaults: UserDefaults

        init(dismissed: Bool = false) {
            defaults = UserDefaults(suiteName: suite)!
            if dismissed { StoreNoticeRecord(defaults: defaults).dismiss() }
        }

        func services(link: String? = "id1234567890") -> StoreNoticeServices {
            StoreNoticeServices(
                link: { link.flatMap { StoreLink(identifier: $0) } },
                open: { self.urls.append($0) },
                record: StoreNoticeRecord(defaults: defaults))
        }

        func finish() { defaults.removePersistentDomain(forName: suite) }
    }

    private func model(guest: Bool = true, fixture: Fixture, link: String? = "id1234567890") -> AppModel {
        let model = AppModel(
            guest: guest ? Guest.fresh(on: host) : nil, host: host,
            system: SystemInfo(
                version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1)
        model.launchApplied = true
        model.driver = StubDriver(plan: .normal)
        model.phase = .home
        model.storeNoticeServices = fixture.services(link: link)
        return model
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func nodes(in node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        return [node] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    private func labels(in root: UIView) -> [String] { nodes(in: root).compactMap(\.accessibilityLabel) }

    /// The first element whose label is exactly `label`, or whose label holds it where `containing` is set.
    private func node(_ label: String, in root: UIView, containing: Bool = false) -> NSObject? {
        nodes(in: root).first {
            guard let text = $0.accessibilityLabel else { return false }
            return containing ? text.contains(label) : text == label
        }
    }

    private func top(of node: NSObject) -> CGFloat { node.accessibilityFrame.minY }

    /// A screen on the application's window.
    private func host<Content: View>(_ content: Content, in lease: HostWindow.Lease)
        -> UIHostingController<some View>
    {
        let controller = UIHostingController(rootView: content.frame(width: 402, height: 874))
        lease.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        return controller
    }

    private func home(_ model: AppModel, in lease: HostWindow.Lease) -> UIHostingController<some View> {
        host(HomeView(hints: ScreenHints()).environment(model), in: lease)
    }

    /// Waits for a screen to be drawn: `label` is on it.
    private func drawn(_ root: UIView, _ label: String) async throws {
        let shown = await eventually {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            return labels(in: root).contains(label)
        }
        try #require(shown, "\(label) was not drawn; is ApplicationAccessibilityEnabled on? \(labels(in: root))")
    }

    // MARK: Home

    @Test func theCardIsFirstAmongHomesNoticesAndAboveTheSections() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let model = model(fixture: fixture)
        // Another notice, which the card does not push aside.
        model.notice = .closedInBackground
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = home(model, in: lease)
        try await drawn(controller.view, "Dismiss")
        let card = try #require(node(Self.title, in: controller.view, containing: true), "\(labels(in: controller.view))")
        let other = try #require(node("iOS closed Andarium", in: controller.view, containing: true), "\(labels(in: controller.view))")
        let section = try #require(node("Virtual machine", in: controller.view), "\(labels(in: controller.view))")
        #expect(top(of: card) < top(of: other), "the card is above every other notice")
        #expect(top(of: other) < top(of: section), "the notices are above the sections")
    }

    @Test func theCardReadsAsTheMessageThenTheButtonThenDismiss() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = home(model(fixture: fixture), in: lease)
        try await drawn(controller.view, Self.button)
        // The title, the message and the caution read as one element.
        let message = try #require(
            node(Self.title, in: controller.view, containing: true), "\(labels(in: controller.view))")
        let spoken = try #require(message.accessibilityLabel)
        #expect(spoken.contains(Self.title))
        #expect(spoken.contains("Stay on this TestFlight beta for the latest features"))
        #expect(spoken.contains("Switching keeps your virtual machine"))
        // Then the button, with its hint, and the close mark. The icon is decoration.
        let button = try #require(node(Self.button, in: controller.view), "\(labels(in: controller.view))")
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.accessibilityHint == "Opens the App Store")
        let close = try #require(node("Dismiss", in: controller.view), "\(labels(in: controller.view))")
        #expect(close.accessibilityTraits.contains(.button))
        #expect(top(of: message) <= top(of: button))
        // The reading order is the message, the button, then the close mark (which sits at the top right, so
        // the frames do not say it).
        let order = labels(in: controller.view)
        let at = (
            message: order.firstIndex { $0.hasPrefix(Self.title) }, button: order.firstIndex(of: Self.button),
            close: order.firstIndex(of: "Dismiss"))
        let (first, second, third) = try (#require(at.message), #require(at.button), #require(at.close))
        #expect(first < second && second < third, "\(order)")
        let all = labels(in: controller.view)
        #expect(!all.contains("arrow.down.app") && !all.contains("StackMark"), "\(all)")
    }

    @Test func theButtonOpensTheAddressThroughTheSystemAndTheCardStays() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let model = model(fixture: fixture)
        let controller = home(model, in: lease)
        try await drawn(controller.view, Self.button)
        let button = try #require(node(Self.button, in: controller.view))
        let before = UserDefaults.standard.dictionaryRepresentation().keys.sorted()
        #expect(button.accessibilityActivate())
        #expect(await eventually { !fixture.urls.isEmpty })
        #expect(fixture.urls.map(\.absoluteString) == ["https://apps.apple.com/app/id1234567890"])
        #expect(fixture.urls.first?.query == nil && fixture.urls.first?.fragment == nil)
        // Nothing is kept about a tap, and the card stays where it was.
        #expect(!model.storeNoticeDismissed)
        #expect(!StoreNoticeRecord(defaults: fixture.defaults).isDismissed)
        #expect(UserDefaults.standard.dictionaryRepresentation().keys.sorted() == before)
        #expect(node(Self.title, in: controller.view, containing: true) != nil)
    }

    @Test func theCloseMarkPutsTheCardAwayForGoodAndInfoKeepsItsRow() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let model = model(fixture: fixture)
        let controller = home(model, in: lease)
        try await drawn(controller.view, "Dismiss")
        let close = try #require(node("Dismiss", in: controller.view))
        #expect(close.accessibilityActivate())
        let gone = await eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return node(Self.title, in: controller.view, containing: true) == nil
        }
        #expect(gone, "\(labels(in: controller.view))")
        #expect(fixture.urls.isEmpty, "the close mark opens nothing")
        #expect(model.storeNoticeDismissed)
        #expect(StoreNoticeRecord(defaults: fixture.defaults).isDismissed)
        // A later launch (a new model on the same defaults) shows no card, and Info still has its row.
        let later = self.model(fixture: fixture)
        #expect(later.storeNoticeDismissed && !later.storeNoticeShown)
        #expect(StoreNoticeRule.showsRow(link: later.storeLink))
        let info = host(InfoSheet(page: nil).environment(later), in: lease)
        try await drawn(info.view, "Project on GitHub")
        #expect(node(Self.row, in: info.view) != nil, "\(labels(in: info.view))")
    }

    @Test func aDismissedCardStaysAwayOnHomeAndOnWelcome() async throws {
        let fixture = Fixture(dismissed: true)
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let withGuest = home(model(fixture: fixture), in: lease)
        try await drawn(withGuest.view, "Virtual machine")
        #expect(node(Self.title, in: withGuest.view, containing: true) == nil)
        let welcome = host(WelcomeView().environment(model(guest: false, fixture: fixture)), in: lease)
        try await drawn(welcome.view, "No virtual machine yet")
        #expect(node(Self.title, in: welcome.view, containing: true) == nil)
    }

    @Test func withoutTheLocalValueThereIsNoCardAndNoRow() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        for link in [nil, "", "not an identifier"] as [String?] {
            let model = model(fixture: fixture, link: link)
            #expect(model.storeLink == nil && !model.storeNoticeShown, "\(link ?? "nil")")
            model.openStoreLink()
            #expect(fixture.urls.isEmpty, "a build with no page opens nothing")
        }
        let model = model(fixture: fixture, link: nil)
        let controller = home(model, in: lease)
        try await drawn(controller.view, "Virtual machine")
        #expect(node(Self.title, in: controller.view, containing: true) == nil)
        let info = host(InfoSheet(page: nil).environment(model), in: lease)
        try await drawn(info.view, "Project on GitHub")
        #expect(node(Self.row, in: info.view) == nil, "\(labels(in: info.view))")
    }

    @Test func theCardNeverCoversStart() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = home(model(fixture: fixture), in: lease)
        try await drawn(controller.view, Self.button)
        let card = try #require(node(Self.title, in: controller.view, containing: true))
        let start = try #require(node("Start", in: controller.view), "\(labels(in: controller.view))")
        #expect(!card.accessibilityFrame.intersects(start.accessibilityFrame))
        #expect(start.accessibilityTraits.contains(.button))
    }

    // MARK: Welcome

    @Test func onWelcomeTheCardIsUnderTheTitleBeforeAnyVirtualMachineExists() async throws {
        let fixture = Fixture()
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let model = model(guest: false, fixture: fixture)
        #expect(model.guest == nil && model.storeNoticeShown)
        let controller = host(WelcomeView().environment(model), in: lease)
        try await drawn(controller.view, "No virtual machine yet")
        try await drawn(controller.view, Self.button)
        let heading = try #require(node("No virtual machine yet", in: controller.view))
        let card = try #require(node(Self.title, in: controller.view, containing: true), "\(labels(in: controller.view))")
        let create = try #require(node("Set up virtual machine", in: controller.view), "\(labels(in: controller.view))")
        #expect(top(of: heading) < top(of: card) && top(of: card) < top(of: create))
        // The same close mark, and the same words.
        let close = try #require(node("Dismiss", in: controller.view))
        #expect(close.accessibilityActivate())
        #expect(await eventually { model.storeNoticeDismissed })
    }

    // MARK: Info

    @Test func theRowIsALinkWithItsNoteBetweenTheAppAndTheSystemInfo() async throws {
        let fixture = Fixture(dismissed: true)
        defer { fixture.finish() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let model = model(fixture: fixture)
        let controller = host(InfoSheet(page: nil).environment(model), in: lease)
        try await drawn(controller.view, "Project on GitHub")
        let row = try #require(node(Self.row, in: controller.view), "\(labels(in: controller.view))")
        #expect(row.accessibilityTraits.contains(.link))
        // The icon and the arrow are decoration: neither is read on its own.
        let spoken = labels(in: controller.view)
        #expect(!spoken.contains("arrow.up.right") && !spoken.contains("Up Right"), "\(spoken)")
        // The two words of the store's name are tied by a no-break space.
        #expect(spoken.contains("New features arrive in this TestFlight beta first. The App\u{00A0}Store version is more stable."), "\(spoken)")
        let build = try #require(node("Build", in: controller.view, containing: true), "\(spoken)")
        let version = try #require(node("Andarium", in: controller.view, containing: true), "\(spoken)")
        #expect(top(of: version) < top(of: row) && top(of: row) < top(of: build))
        // A tap opens the address through the system, whether or not the card was dismissed, and nothing else.
        #expect(row.accessibilityActivate())
        #expect(await eventually { !fixture.urls.isEmpty })
        #expect(fixture.urls.map(\.absoluteString) == ["https://apps.apple.com/app/id1234567890"])
        #expect(model.storeNoticeDismissed, "the row does not bring the card back")
    }

    // MARK: The build

    @Test func theBuildNamesTheArrangedIdentifierUnderItsOwnKeyAndTheModelReadsIt() {
        #expect(Bundle.main.object(forInfoDictionaryKey: StoreLinkConfiguration.key) as? String == "id0000000000")
        #expect(StoreLinkConfiguration.link?.url.absoluteString == "https://apps.apple.com/app/id0000000000")
        let live = AppModel(
            guest: nil, host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1)
        #expect(live.storeLink?.identifier == "id0000000000")
    }

    // MARK: The words

    /// The words, in each language the application ships, as the table holds them; English is the key itself.
    @Test func theTableHoldsTheWordsInEveryLanguage() throws {
        let words: [String: [String: String]] = [
            "ja": [
                "Andarium is on the App Store": "AndariumがApp Storeに登場",
                "View in App Store": "App Storeで見る",
                "Opens the App Store": "App Storeを開きます",
                "Andarium on the App Store": "App StoreのAndarium",
            ],
            "zh-Hans": [
                "Andarium is on the App Store": "Andarium已上架App Store",
                "View in App Store": "在App Store中查看",
                "Opens the App Store": "打开App Store",
                "Andarium on the App Store": "App Store上的Andarium",
            ],
            "zh-Hant": [
                "Andarium is on the App Store": "Andarium已在App Store上架",
                "View in App Store": "在App Store中檢視",
                "Opens the App Store": "打開App Store",
                "Andarium on the App Store": "App Store上的Andarium",
            ],
        ]
        let keys = [
            "Andarium is on the App Store",
            "Stay on this TestFlight beta for the latest features, or get the App Store version for a more stable experience.",
            "Switching keeps your virtual machine, but it may not start until the App Store version catches up with this beta.",
            "View in App Store", "Opens the App Store", "Andarium on the App Store",
            "New features arrive in this TestFlight beta first. The App Store version is more stable.",
        ]
        for (language, expected) in words {
            let path = try #require(
                Bundle.main.path(forResource: "StoreLink", ofType: "strings", inDirectory: nil, forLocalization: language),
                "the \(language) table")
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            #expect(Set(table.keys) == Set(keys), "\(language)")
            for (key, value) in expected { #expect(table[key] == value, "\(language): \(key)") }
            for key in keys {
                #expect(table[key] != key && table[key]?.contains("App Store") == true, "\(language): \(key)")
            }
        }
        // English is the key: the catalog's source language compiles no table of its own, and the
        // scheme's Test action pins English.
        for key in keys {
            #expect(Bundle.main.localizedString(forKey: key, value: nil, table: "StoreLink") == key, "\(key)")
        }
    }
}

#endif
