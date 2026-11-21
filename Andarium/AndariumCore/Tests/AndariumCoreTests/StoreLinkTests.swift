// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumStoreLinkLogic

/// The App Store notice's logic: the address it opens, the reading of the
/// build's Info.plist, the record of a dismissed card and the rule that says
/// what shows. The package compiles the application's own source for this,
/// with the notice's condition set. The identifier here is the placeholder of
/// the tracked example, never the application's own.
struct StoreLinkTests {
    // MARK: The address

    @Test func theAddressIsTheApplicationsPageWithNoStorefrontAndNoAction() throws {
        let link = try #require(StoreLink(identifier: "id1234567890"))
        #expect(link.url.absoluteString == "https://apps.apple.com/app/id1234567890")
        #expect(link.url.scheme == "https" && link.url.host == "apps.apple.com")
        // No two-letter storefront segment before `app`, and no query: not the write-review page.
        #expect(link.url.pathComponents == ["/", "app", "id1234567890"])
        #expect(link.url.query == nil && link.url.fragment == nil)
    }

    @Test func onlyAnIdentifierOfTheAppStoresShapeBuildsALink() {
        // The placeholder of the tests' arrangement has the shape; only the bundle check refuses it in a TestFlight build.
        for good in ["id123456", "id1234567890", "id100000", "id123456789012345", "id0000000000", "id00000"] {
            #expect(StoreLink(identifier: good) != nil, "\(good)")
        }
        let bad = [
            "", "id", "id0000", "1234567890", "ID1234567890", "id1234",
            "id1234567890123456", "id12345a7890", "id123456/../x", "id123456?x=1", "id 123456", "id123456\n",
            "https://apps.apple.com/us/app/andarium/id1234567890", "id１２３４５６７",
        ]
        for value in bad {
            #expect(StoreLink(identifier: value) == nil, "\(value.debugDescription)")
        }
    }

    // MARK: The configuration

    @Test func theBuildNamesTheLinkUnderItsOwnKey() {
        #expect(StoreLinkConfiguration.key == "AndariumStoreLinkID")
        let info: [String: Any] = [StoreLinkConfiguration.key: "id1234567890"]
        #expect(StoreLinkConfiguration.link(in: info)?.identifier == "id1234567890")
    }

    @Test func aBuildThatNamesNothingHasNoLink() {
        // The local value absent: the build writes no key.
        #expect(StoreLinkConfiguration.link(in: nil) == nil)
        #expect(StoreLinkConfiguration.link(in: [:]) == nil)
        // An empty or malformed value, or one that is not text, names no page.
        #expect(StoreLinkConfiguration.link(in: [StoreLinkConfiguration.key: ""]) == nil)
        #expect(StoreLinkConfiguration.link(in: [StoreLinkConfiguration.key: "not an identifier"]) == nil)
        #expect(StoreLinkConfiguration.link(in: [StoreLinkConfiguration.key: 1_234_567_890]) == nil)
    }

    @Test func reviewOnTheAppStoresKeyIsNoLink() {
        // A build that names an identifier for Review on the App Store only (an AppStore build) has no notice.
        #expect(StoreLinkConfiguration.link(in: ["AndariumReviewID": "id1234567890"]) == nil)
    }

    // MARK: The record

    private func record() throws -> (StoreNoticeRecord, UserDefaults, String) {
        let suite = "andarium.tests.storenotice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (StoreNoticeRecord(defaults: defaults), defaults, suite)
    }

    @Test func aFreshInstallHasNotDismissedTheCard() throws {
        let (record, defaults, suite) = try record()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!record.isDismissed)
    }

    @Test func aDismissalIsKeptForTheInstallation() throws {
        let (record, defaults, suite) = try record()
        defer { defaults.removePersistentDomain(forName: suite) }
        record.dismiss()
        #expect(record.isDismissed)
        // A later launch reads it from the same defaults.
        #expect(StoreNoticeRecord(defaults: defaults).isDismissed)
        record.dismiss()
        #expect(StoreNoticeRecord(defaults: defaults).isDismissed)
    }

    @Test func theRecordIsOneBooleanThatNoBuildNumberKeys() throws {
        let (record, defaults, suite) = try record()
        defer { defaults.removePersistentDomain(forName: suite) }
        record.dismiss()
        let kept = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(kept.keys.sorted() == [StoreNoticeRecord.key])
        #expect(kept[StoreNoticeRecord.key] as? Bool == true)
        #expect(!StoreNoticeRecord.key.contains("build"))
    }

    // MARK: The rule

    @Test func theCardShowsWhenTheBuildNamesThePageAndItIsNotDismissed() throws {
        let link = try #require(StoreLink(identifier: "id1234567890"))
        #expect(StoreNoticeRule.showsCard(link: link, dismissed: false))
    }

    @Test func noCardWithoutTheLocalValue() throws {
        #expect(!StoreNoticeRule.showsCard(link: nil, dismissed: false))
        #expect(!StoreNoticeRule.showsCard(link: nil, dismissed: true))
        #expect(!StoreNoticeRule.showsRow(link: nil))
    }

    @Test func aDismissedCardStaysAwayAndTheRowStays() throws {
        let link = try #require(StoreLink(identifier: "id1234567890"))
        #expect(!StoreNoticeRule.showsCard(link: link, dismissed: true))
        #expect(StoreNoticeRule.showsRow(link: link), "the row shows whether or not the card is dismissed")
    }
}
