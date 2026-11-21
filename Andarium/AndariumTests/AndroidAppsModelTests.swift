// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import AndariumCoreTestSupport
import CoreSpotlight
import Foundation
import Testing
@testable import Andarium

/// What the application's index is told, in order, instead of the system's.
/// A write can be held until the test lets it go, and made to fail.
@MainActor
final class RecordingAppsIndex: AndroidAppsSearchIndexing {
    private(set) var offered: [[String]] = []
    private(set) var added: [[String]] = []
    private(set) var withdrawn = 0
    private(set) var shortcutUpdates = 0
    /// Every write and every tile update, in the order the system took them.
    private(set) var events: [String] = []
    /// Whether the system takes what it is given.
    var accepts = true
    /// The next offer waits here until `letGo()`.
    var holdsNextOffer = false
    private var held: CheckedContinuation<Void, Never>?
    /// The next withdrawal and the next selective add wait until `letGoWithdraw()` and `letGoAdd()`.
    var holdsNextWithdraw = false
    var holdsNextAdd = false
    private var heldWithdraw: CheckedContinuation<Void, Never>?
    private var heldAdd: CheckedContinuation<Void, Never>?

    func offer(_ entities: [AndroidAppEntity]) async -> Bool {
        if holdsNextOffer {
            holdsNextOffer = false
            events.append("offer-started")
            await withCheckedContinuation { held = $0 }
        }
        guard accepts else { events.append("offer-failed"); return false }
        offered.append(entities.map(\.id))
        events.append("offer")
        return true
    }

    func add(_ entities: [AndroidAppEntity]) async -> Bool {
        if holdsNextAdd {
            holdsNextAdd = false
            events.append("add-started")
            await withCheckedContinuation { heldAdd = $0 }
        }
        guard accepts else { return false }
        added.append(entities.map(\.id))
        events.append("add")
        return true
    }

    func withdraw() async -> Bool {
        if holdsNextWithdraw {
            holdsNextWithdraw = false
            events.append("withdraw-started")
            await withCheckedContinuation { heldWithdraw = $0 }
        }
        guard accepts else { events.append("withdraw-failed"); return false }
        withdrawn += 1
        events.append("withdraw")
        return true
    }

    func shortcutsChanged() {
        shortcutUpdates += 1
        events.append("tiles")
    }

    func letGo() {
        held?.resume()
        held = nil
    }

    func letGoWithdraw() {
        heldWithdraw?.resume()
        heldWithdraw = nil
    }

    func letGoAdd() {
        heldAdd?.resume()
        heldAdd = nil
    }
}

/// Add to Home Screen as the model plays it: the list a refresh keeps and what
/// it tells the system, a request made as an App Intent makes it while Android
/// runs, while it starts and while it is off, what a request that must wait
/// waits for, how each failure ends, and what an erase leaves. The runtime is
/// a stub and the tool is the played one (`ScriptedAndroidApps`).
@Suite(.serialized)
@MainActor
final class AndroidAppsModelTests {
    init() async { await AndroidAppsHubLock.shared.acquire() }
    deinit { Task { await AndroidAppsHubLock.shared.release() } }

    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000)
    private let system = SystemInfo(
        version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1")
    private let comet = ScriptedAndroidApps.installedApps[0]
    private let inkleaf = ScriptedAndroidApps.installedApps[1]

    private struct Rig {
        let model: AppModel
        let driver: StubDriver
        let scripted: ScriptedAndroidApps
        let index: RecordingAppsIndex
        let directory: URL
        var state: AndroidAppsState { model.androidApps }
        var tool: ScriptedAppsTool { scripted.tool }
    }

    /// A model over a stub runtime, a cache of its own and the played tool.
    /// Nothing is asked slowly: each answer takes a millisecond.
    private func rig(phase: Phase = .home, plan: StartPlan = .normal, guest: Bool = true) throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-apps-test-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(
            guest: guest ? Guest.fresh(on: host) : nil, host: host, system: system, capabilities: .device,
            createRequirementBytes: 1)
        let driver = StubDriver(plan: plan)
        model.driver = driver
        model.plan = plan
        model.phase = phase
        model.session.storageReady = true
        let scripted = ScriptedAndroidApps()
        scripted.tool.delay = .milliseconds(1)
        scripted.readyDelay = .milliseconds(1)
        model.scriptedAndroidApps = scripted
        AndroidAppsHub.shared.configure(directory: directory)
        AndroidAppsHub.shared.attach(model)
        let index = RecordingAppsIndex()
        AndroidAppsHub.shared.searchIndex = index
        let state = model.androidApps
        state.store = AndroidAppsHub.shared.store
        AndroidAppsHub.shared.preference = AndroidAppSearchPreference(
            defaults: try #require(UserDefaults(suiteName: "andarium-apps-test-\(UUID().uuidString)")))
        state.searchOn = true
        state.adoptCache()
        return Rig(model: model, driver: driver, scripted: scripted, index: index, directory: directory)
    }

    private func eventually(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: The list

    @Test func aRefreshKeepsTheListAndItsIconsAndTellsTheSystem() async throws {
        let rig = try rig(phase: .running(.normal))
        #expect(await rig.model.refreshAndroidApps())
        let state = rig.state
        #expect(state.listed && !state.failed && !state.refreshing)
        #expect(state.apps.count == ScriptedAndroidApps.sampleApps.count)
        #expect(state.store.icon(forID: comet.id) != nil)
        // The cache answers without a model: the App Intent's query reads it.
        #expect(AndroidAppsHub.shared.entities().map(\.id) == state.apps.map(\.id))
        #expect(rig.index.offered.count == 1 && rig.index.offered[0] == state.apps.map(\.id))
        #expect(rig.index.shortcutUpdates == 1)
    }

    @Test func aRefreshOfAnUnchangedListAsksOnlyTheDigest() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let listings = rig.tool.listingsAsked
        await rig.model.refreshAndroidApps()
        #expect(rig.tool.listingsAsked == listings)
        #expect(rig.tool.digestsAsked >= 2)
        #expect(rig.index.offered.count == 1, "nothing changed, so nothing is offered again")
    }

    @Test func anInstalledAppReachesTheListAndTheSystem() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let extra = AndroidApp(
            component: try #require(AndroidComponent(packageName: "com.example.newcomer", activityClass: "com.example.newcomer.Main")),
            label: "Newcomer", builtIn: false, iconTag: "0000000000000001")
        rig.tool.install(extra)
        await rig.model.refreshAndroidApps()
        #expect(rig.state.apps.contains { $0.id == extra.id })
        #expect(rig.index.offered.count == 2 && rig.index.offered[1].contains(extra.id))
    }

    @Test func noRefreshIsAskedWhereTheToolCannotBe() async throws {
        let home = try rig(phase: .home)
        #expect(await home.model.refreshAndroidApps() == false)
        let recovery = try rig(phase: .running(.recovery))
        #expect(await recovery.model.refreshAndroidApps() == false)
        let paused = try rig(phase: .running(.normal))
        paused.model.spacePause = SpacePause(freeBytes: 0, stage: .pausing)
        #expect(await paused.model.refreshAndroidApps() == false)
        #expect(paused.tool.digestsAsked == 0)
    }

    @Test func anImageWithoutTheToolOffersNothing() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        #expect(!rig.state.apps.isEmpty)
        // An earlier image listed apps; this one has no tool. What it listed is withdrawn everywhere.
        rig.tool.answer(listing: .unavailable, digest: .unavailable)
        rig.state.invalidated()
        await rig.model.refreshAndroidApps()
        #expect(rig.state.unavailable)
        #expect(!rig.model.offersAddToHomeScreen)
        #expect(rig.state.apps.isEmpty && rig.state.store.catalog() == nil)
        #expect(AndroidAppsHub.shared.entities().isEmpty)
        #expect(rig.index.offered.last == [], "Spotlight holds none of them")
        #expect(rig.index.events.last != "offer-failed")
    }

    @Test func aRefreshThatGotNoAnswerKeepsWhatWasCached() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let before = rig.state.apps
        rig.tool.install(try #require(ScriptedAndroidApps.installedApps.first))  // the digest changes
        rig.tool.answer(listing: .failed, digest: .digest("changed"))
        await rig.model.refreshAndroidApps()
        #expect(rig.state.failed && rig.state.apps == before)
        #expect(rig.state.listedAt != nil)
    }

    // MARK: Search

    @Test func theSwitchWithdrawsTheAppsAndOffersThemAgain() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        rig.model.setAndroidAppsInSearch(false)
        #expect(await eventually { rig.index.withdrawn == 1 })
        #expect(!rig.state.searchOn && !AndroidAppsHub.shared.preference.isOn)
        // The list still reaches the shortcut tiles, which are the route to the Home Screen.
        #expect(AndroidAppsHub.shared.entities().count == rig.state.apps.count)
        rig.model.setAndroidAppsInSearch(true)
        #expect(await eventually { rig.index.offered.count == 2 })
        #expect(AndroidAppsHub.shared.preference.isOn)
    }

    @Test func aRefreshWhileTheSwitchIsOffOffersNothing() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.state.searchOn = false
        AndroidAppsHub.shared.preference.keep(false)
        rig.tool.install(try #require(ScriptedAndroidApps.installedApps.last))
        await rig.model.refreshAndroidApps()
        #expect(rig.index.offered.isEmpty && rig.index.withdrawn == 1)
    }

    // MARK: A request while Android runs

    @Test func aRequestWhileAndroidRunsOpensTheAppAndClosesWhatCoversIt() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.model.sessionSettingsOpen = true
        rig.model.session.sideKeysOpen = true
        rig.model.requestAndroidApp(comet.component)
        #expect(!rig.model.sessionSettingsOpen && !rig.model.session.sideKeysOpen)
        #expect(rig.state.open.pending?.stage == .opening)
        #expect(await eventually { rig.tool.opened == [comet.component] })
        #expect(await eventually { rig.state.open.pending == nil })
        #expect(rig.state.open.banner == nil)
        #expect(rig.driver.begun.isEmpty, "Android runs: nothing is started")
        #expect(rig.scripted.readinessAsked == 1)
    }

    @Test func aRequestNamesTheAppAsItsEntityDid() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readyDelay = .seconds(3600)
        #expect(rig.model.requestAndroidApp(identifier: comet.id, label: "Comet Hop"))
        #expect(rig.state.open.pending?.request.label == "Comet Hop")
        #expect(rig.state.open.pending?.request.component == comet.component)
        rig.model.dontOpenAndroidApp()
    }

    @Test func aValueThatIsNoComponentIsNoRequest() throws {
        let rig = try rig(phase: .running(.normal))
        #expect(!rig.model.requestAndroidApp(identifier: "not-a-component"))
        #expect(!rig.model.requestAndroidApp(identifier: ""))
        #expect(rig.state.open.pending == nil)
    }

    @Test func aNewerRequestReplacesAnOlderOne() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readyDelay = .milliseconds(200)
        rig.model.requestAndroidApp(comet.component)
        rig.model.requestAndroidApp(inkleaf.component)
        #expect(await eventually { rig.state.open.pending == nil })
        #expect(rig.tool.opened == [inkleaf.component])
    }

    @Test func dontOpenDropsTheRequestAndNothingIsOpenedLater() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readyDelay = .milliseconds(100)
        rig.model.requestAndroidApp(comet.component)
        rig.model.dontOpenAndroidApp()
        #expect(rig.state.open.pending == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.tool.opened.isEmpty)
    }

    @Test func theRunEndingDropsTheRequestAndTheBanner() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readyDelay = .seconds(3600)
        rig.model.requestAndroidApp(comet.component)
        rig.model.runEnded(RunEnd(result: 0), uptimeSeconds: nil)
        #expect(rig.state.open.pending == nil && rig.state.open.banner == nil)
        #expect(!rig.state.listed)
        #expect(rig.tool.opened.isEmpty)
    }

    // MARK: A request while Android is off

    @Test func aRequestWhileAndroidIsOffStartsItAsStartDoesAndOpensTheAppWhenItIsUp() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        rig.model.requestAndroidApp(comet.component)
        #expect(rig.driver.begun.count == 1 && rig.driver.begun.first?.mode == .normal)
        #expect(rig.model.phase == .booting(.normal))
        #expect(rig.state.open.pending?.stage == .starting)
        #expect(rig.tool.opened.isEmpty)
        rig.model.phase = .running(.normal)
        rig.model.finishBoot(.normal)
        #expect(await eventually { rig.tool.opened == [comet.component] })
        #expect(await eventually { rig.state.open.pending == nil })
    }

    @Test func aRequestWhileAndroidIsStartingJoinsTheStart() throws {
        let rig = try rig(phase: .booting(.normal))
        rig.model.requestAndroidApp(comet.component)
        #expect(rig.driver.begun.isEmpty, "no second start")
        #expect(rig.state.open.pending?.stage == .starting)
    }

    @Test func aRequestWaitsAtHomeForAnUnfinishedUpdateAndStartsWithTheAnswer() async throws {
        let rig = try rig(phase: .home, plan: .unfinishedUpdate(to: "r2", canRetry: true, canRestore: true))
        rig.model.requestAndroidApp(comet.component)
        guard case .waiting(.update, _)? = rig.state.open.pending?.stage else {
            Issue.record("the request should wait for the answer to the update: \(String(describing: rig.state.open.pending))")
            return
        }
        #expect(rig.driver.begun.isEmpty)
        // The person answers: Update and start.
        rig.model.plan = .update(from: "r1", to: "r2")
        rig.model.start(.normal)
        #expect(rig.driver.begun.count == 1)
        #expect(rig.state.open.pending?.stage == .starting)
    }

    @Test func aRequestWaitsAtHomeWhileThereIsNoRoomToStart() throws {
        var tight = host
        tight.freeStorageBytes = 1_000_000
        let model = AppModel(guest: Guest.fresh(on: tight), host: tight, system: system, capabilities: .device, createRequirementBytes: 1)
        model.driver = StubDriver(plan: .normal)
        model.plan = .normal
        model.scriptedAndroidApps = ScriptedAndroidApps()
        AndroidAppsHub.shared.configure(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("andarium-apps-test-\(UUID().uuidString)"))
        model.androidApps.store = AndroidAppsHub.shared.store
        model.requestAndroidApp(comet.component)
        guard case .waiting(.space, _)? = model.androidApps.open.pending?.stage else {
            Issue.record("the request should wait for space: \(String(describing: model.androidApps.open.pending))")
            return
        }
    }

    @Test func aRequestWithNoVirtualMachineSaysTheAppIsNotInAndroid() throws {
        let rig = try rig(phase: .home, plan: .firstStart, guest: false)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.model.alert?.title == AndroidAppsWords.notInAndroidTitle("Comet Hop"))
        #expect(rig.model.alert?.message == AndroidAppsWords.noAndroidText)
        #expect(rig.state.open.pending == nil)
    }

    @Test func aRequestInRecoveryIsRefusedWithABanner() throws {
        let rig = try rig(phase: .running(.recovery))
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.state.open.banner?.failure == .recovery)
        #expect(rig.state.open.pending == nil && rig.tool.opened.isEmpty)
    }

    // MARK: How an open ends

    @Test func anAppThatIsGoneEndsWithABannerAndAListAskedAgain() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        rig.tool.remove(comet.id)
        rig.model.requestAndroidApp(comet.component)
        #expect(await eventually { rig.state.open.banner?.failure == .notInAndroid })
        #expect(rig.state.open.banner?.app == comet.component)
        #expect(rig.state.open.banner?.component == nil, "no Try Again for an app that is not there")
        // The cache was dropped and read again, so the app is out of the list.
        #expect(await eventually { !rig.state.apps.contains { $0.id == comet.id } && rig.state.listed })
    }

    @Test func androidTakingTooLongEndsWithABannerAndTryAgainOpensTheApp() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.tool.answer(open: comet.component, .failed)
        rig.model.requestAndroidApp(comet.component)
        #expect(await eventually { rig.state.open.banner?.failure == .tookTooLong })
        rig.tool.answer(open: comet.component, .opened)
        rig.model.retryAndroidAppOpen()
        #expect(rig.state.open.banner == nil)
        #expect(await eventually { rig.tool.opened.count == 2 && rig.state.open.pending == nil })
        #expect(rig.state.open.banner == nil)
    }

    @Test func androidNeverBecomingReadyEndsWithTheSameBanner() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readiness = .timedOut
        rig.model.requestAndroidApp(comet.component)
        #expect(await eventually { rig.state.open.banner?.failure == .tookTooLong })
        #expect(rig.tool.opened.isEmpty)
    }

    @Test func androidsUnfinishedSetupEndsWithABannerThatOffersTryAgain() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readiness = .setupUnfinished
        rig.model.requestAndroidApp(comet.component)
        #expect(await eventually { rig.state.open.banner?.failure == .setupUnfinished })
        #expect(rig.state.open.banner?.component == comet.component)
        #expect(rig.tool.opened.isEmpty)
        rig.model.dismissAndroidAppBanner()
        #expect(rig.state.open.banner == nil)
    }

    // MARK: Erase and the entities

    @Test func anEraseDropsTheCacheAndKeepsTheRecordOfEachIcon() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        #expect(rig.state.store.record(forID: comet.id)?.label == "Comet Hop")
        rig.model.androidAppsErased()
        #expect(rig.state.apps.isEmpty && rig.state.store.catalog() == nil)
        #expect(AndroidAppsHub.shared.entities().isEmpty)
        #expect(rig.state.store.record(forID: comet.id)?.label == "Comet Hop")
        // What was offered to Search is replaced by nothing.
        #expect(await eventually { rig.index.offered.last == [] })
    }

    @Test func anIconAfterAnEraseStillResolvesToItsAppAndWorksAfterAReinstall() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        rig.model.androidAppsErased()
        let query = AndroidAppQuery()
        let leftover = try await query.entities(for: [comet.id])
        #expect(leftover.map(\.name) == ["Comet Hop"], "the leftover icon keeps its app's name")
        // The app is installed in a new Android: the same identifier opens it again.
        rig.model.phase = .running(.normal)
        rig.model.session.storageReady = true
        await rig.model.refreshAndroidApps()
        let again = try await query.entities(for: [comet.id])
        #expect(again.map(\.id) == [comet.id])
        #expect(rig.model.requestAndroidApp(identifier: again[0].id, label: again[0].name))
        #expect(await eventually { rig.tool.opened == [comet.component] })
    }

    @Test func theQueryAnswersFromTheCacheWhileAndroidIsOff() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        rig.model.phase = .home
        let query = AndroidAppQuery()
        let all = try await query.allEntities()
        #expect(all.count == ScriptedAndroidApps.sampleApps.count)
        #expect(all.map(\.id) == rig.state.apps.map(\.id))
        #expect(try await query.suggestedEntities().count == all.count)
        // An identifier that is no component names nothing.
        #expect(try await query.entities(for: ["nothing"]).isEmpty)
    }

    @Test func anEntityCarriesTheAppsNameItsIdentifierAndItsIcon() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let entity = try #require(AndroidAppsHub.shared.entities().first { $0.id == comet.id })
        #expect(entity.name == "Comet Hop")
        #expect(entity.id == "com.example.comethop/com.example.comethop.MainActivity")
        #expect(entity.attributeSet.title == "Comet Hop")
        #expect(entity.attributeSet.thumbnailData != nil)
    }

    // MARK: The row

    @Test func theRowIsOfferedOnlyWhileAndroidRuns() throws {
        let running = try rig(phase: .running(.normal))
        #expect(running.model.offersAddToHomeScreen)
        for phase in [Phase.home, .booting(.normal), .running(.recovery), .failed] {
            let other = try rig(phase: phase)
            #expect(!other.model.offersAddToHomeScreen, "no row in \(phase)")
        }
    }

    @Test func aMacHasNoHomeScreenToAddTo() throws {
        let rig = try rig(phase: .running(.normal))
        rig.model.host.idiom = .mac
        #expect(!rig.model.offersAddToHomeScreen)
    }

    // MARK: Where the feature is not offered

    @Test func aMacWritesNothingToSpotlightAndHasNoEntities() async throws {
        let rig = try rig(phase: .running(.normal))
        // The cache holds apps (a listing made when the hub was set up elsewhere), and the host offers none.
        await rig.model.refreshAndroidApps()
        let writes = rig.index.events.count
        rig.model.host.idiom = .mac
        AndroidAppsHub.shared.attach(rig.model)
        #expect(!AndroidAppsHub.shared.hostOffers)
        #expect(AndroidAppsHub.shared.entities().isEmpty)
        let query = AndroidAppQuery()
        #expect(try await query.allEntities().isEmpty)
        #expect(try await query.suggestedEntities().isEmpty)
        #expect(try await query.entities(for: [comet.id]).isEmpty)
        await rig.model.syncAndroidAppsIndex()
        try await query.reindexAllEntities(indexDescription: CSSearchableIndexDescription())
        try await query.reindexEntities(for: [comet.id], indexDescription: CSSearchableIndexDescription())
        #expect(rig.index.events.count == writes, "no index write, no tile update: \(rig.index.events)")
        // And a refresh on such a host tells the system nothing.
        rig.model.setAndroidAppsInSearch(false)
        await rig.model.syncAndroidAppsIndex()
        #expect(rig.index.events.count == writes)
    }

    // MARK: The switch is for Search only

    @Test func theSwitchOffLeavesTheEntitiesAndTheTilesAndEmptiesSpotlight() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.model.setAndroidAppsInSearch(false)
        await rig.model.refreshAndroidApps()
        #expect(rig.state.apps.count == ScriptedAndroidApps.sampleApps.count)
        // Spotlight holds none and was never given any.
        #expect(rig.index.offered.isEmpty)
        #expect(rig.index.events.contains("withdraw"))
        // The entities, and the parameters of the App Shortcut that are made of them, are as with the switch on.
        #expect(AndroidAppsHub.shared.entities().count == rig.state.apps.count)
        #expect(try await AndroidAppQuery().suggestedEntities().count == rig.state.apps.count)
        #expect(rig.index.shortcutUpdates >= 1, "the tiles are told of the apps")
        // An icon added while the switch is off reaches the tiles.
        let before = rig.index.shortcutUpdates
        rig.tool.install(AndroidApp(
            component: try #require(AndroidComponent(packageName: "com.example.newcomer", activityClass: "com.example.newcomer.Main")),
            label: "Newcomer", builtIn: false, iconTag: "0000000000000042"))
        await rig.model.refreshAndroidApps()
        #expect(rig.index.shortcutUpdates == before + 1)
        #expect(rig.index.offered.isEmpty)
        #expect(AndroidAppsHub.shared.entities().contains { $0.name == "Newcomer" })
    }

    @Test func theSystemsReindexAsksAreJudgedByTheSwitchAndOfferOnlyListedApps() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let query = AndroidAppQuery()
        let off = CSSearchableIndexDescription()
        // On: the listed app is added; an identifier the cache no longer lists is not.
        let gone = "com.example.gone/com.example.gone.Main"
        try await query.reindexEntities(for: [comet.id, gone], indexDescription: off)
        #expect(rig.index.added.last == [comet.id])
        // Off: nothing is added, whatever the system asks.
        rig.model.setAndroidAppsInSearch(false)
        let adds = rig.index.added.count
        let offers = rig.index.offered.count
        try await query.reindexEntities(for: [comet.id], indexDescription: off)
        try await query.reindexAllEntities(indexDescription: off)
        #expect(rig.index.added.count == adds && rig.index.offered.count == offers)
    }

    @Test func aWriteAskedBeforeTheSwitchWasTurnedOffNeverLandsAfterIt() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.index.holdsNextOffer = true
        // The refresh's offer is under way at the system and held there.
        let refreshing = Task { await rig.model.refreshAndroidApps() }
        #expect(await eventually { rig.index.events.contains("offer-started") })
        rig.model.setAndroidAppsInSearch(false)
        try await Task.sleep(for: .milliseconds(50))
        rig.index.letGo()
        await refreshing.value
        #expect(await eventually { rig.index.events.last == "withdraw" })
        // In order: the offer that was under way first, then the withdrawal; never an offer after it.
        let writes = rig.index.events.filter { ["offer", "withdraw"].contains($0) }
        #expect(writes == ["offer", "withdraw"], "\(rig.index.events)")
    }

    @Test func aWithdrawalThatFailedIsFinishedAtTheNextLaunch() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        rig.index.accepts = false
        rig.model.setAndroidAppsInSearch(false)
        #expect(await eventually { rig.index.events.contains("withdraw-failed") })
        #expect(rig.index.withdrawn == 0)
        // The next launch reconciles Spotlight with the switch's last word.
        rig.index.accepts = true
        await AndroidAppsHub.shared.writer.reconcile()
        #expect(rig.index.withdrawn == 1)
        // And once it took, a launch writes nothing again.
        let events = rig.index.events.count
        await AndroidAppsHub.shared.writer.reconcile()
        #expect(rig.index.events.count == events)
    }

    @Test func artworkThatArrivedAfterTheRowsIsToldToShortcutsAndSpotlight() async throws {
        let rig = try rig(phase: .running(.normal))
        let app = AndroidApp(component: comet.component, label: "Comet Hop", builtIn: false, iconTag: "00000000000000aa")
        try rig.state.store.apply(AndroidAppList(apps: [app], digest: "d"), at: Date())
        rig.state.adoptCache()
        await rig.model.syncAndroidAppsIndex()
        let offers = rig.index.offered.count
        let tiles = rig.index.shortcutUpdates
        // The same rows, and now a picture.
        let png = try #require(ScriptedAppIcons.png(for: app))
        #expect(rig.state.store.setIcon(png, for: app))
        await rig.model.syncAndroidAppsIndex()
        #expect(rig.index.offered.count == offers + 1)
        #expect(rig.index.shortcutUpdates == tiles + 1)
        // Nothing changed since: nothing is written.
        await rig.model.syncAndroidAppsIndex()
        #expect(rig.index.offered.count == offers + 1 && rig.index.shortcutUpdates == tiles + 1)
    }

    @Test func aSwitchTurnedOffBeforeTheOfferWasAcknowledgedIsWithdrawnAtTheNextLaunch() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        // Search was off and the index was told so: the saved state is "withdrawn".
        rig.model.setAndroidAppsInSearch(false)
        #expect(await eventually { rig.index.withdrawn == 1 })
        // The person turns it on; the offer is under way...
        rig.index.holdsNextOffer = true
        rig.model.setAndroidAppsInSearch(true)
        #expect(await eventually { rig.index.events.last == "offer-started" })
        // ...and the person turns it off again before the offer is acknowledged and the process ends.
        rig.model.setAndroidAppsInSearch(false)
        // The next launch: a fresh writer over the same saved preference.
        AndroidAppsHub.shared.searchIndex = rig.index
        await AndroidAppsHub.shared.writer.reconcile()
        #expect(rig.index.withdrawn == 2, "Spotlight may hold what the lost offer wrote: the launch withdraws it")
        // The abandoned offer ends with the test, not after it.
        rig.index.letGo()
        try await Task.sleep(for: .milliseconds(150))
    }

    @Test func aFullReindexThatDeletedAndFailedToInsertIsRepairedAtTheNextLaunch() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let query = AndroidAppQuery()
        // The system asks for every app again; the index takes the delete and not the insert.
        rig.index.accepts = false
        var reported = false
        do {
            try await query.reindexAllEntities(indexDescription: CSSearchableIndexDescription())
        } catch {
            reported = true
        }
        #expect(reported, "the failure reaches the system, which asks again")
        rig.index.accepts = true
        let offers = rig.index.offered.count
        await AndroidAppsHub.shared.writer.reconcile()
        #expect(rig.index.offered.count == offers + 1, "the next launch offers the apps again: Spotlight holds none")
    }

    @Test func aSelectiveAddQueuedBehindAWithdrawalIsWithdrawnWhenTheSwitchEndsOff() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        // Search goes off: the withdrawal is under way at the system and held there.
        rig.index.holdsNextWithdraw = true
        rig.model.setAndroidAppsInSearch(false)
        #expect(await eventually { rig.index.events.last == "withdraw-started" })
        // The system asks for the app again meanwhile (queued behind the withdrawal), and the person turns Search on.
        let query = AndroidAppQuery()
        let asking = Task { try? await query.reindexEntities(for: [comet.id], indexDescription: CSSearchableIndexDescription()) }
        try await Task.sleep(for: .milliseconds(50))
        rig.model.setAndroidAppsInSearch(true)
        rig.index.holdsNextAdd = true
        rig.index.letGoWithdraw()
        #expect(await eventually { rig.index.events.last == "add-started" })
        // The add is under way when the person turns Search off again.
        rig.model.setAndroidAppsInSearch(false)
        rig.index.letGoAdd()
        _ = await asking.value
        // Spotlight ends without the app: what the saved state said before the add is not what it holds now.
        #expect(await eventually { rig.index.events.last == "withdraw" }, "\(rig.index.events)")
    }

    @Test func artworkThatArrivesWhileAFullReindexIsOfferedIsOfferedAgain() async throws {
        let rig = try rig(phase: .running(.normal))
        let app = AndroidApp(component: comet.component, label: "Comet Hop", builtIn: false, iconTag: "00000000000000aa")
        try rig.state.store.apply(AndroidAppList(apps: [app], digest: "d"), at: Date())
        rig.state.adoptCache()
        await rig.model.syncAndroidAppsIndex()
        // The system asks for every app again; the entities are made without a picture...
        rig.index.holdsNextOffer = true
        let query = AndroidAppQuery()
        let reindexing = Task { try? await query.reindexAllEntities(indexDescription: CSSearchableIndexDescription()) }
        #expect(await eventually { rig.index.events.last == "offer-started" })
        // ...and the picture arrives while the offer is on its way.
        let png = try #require(ScriptedAppIcons.png(for: app))
        #expect(rig.state.store.setIcon(png, for: app))
        rig.index.letGo()
        _ = await reindexing.value
        // What Spotlight holds has no picture, so the next pass offers the apps again.
        let offers = rig.index.offered.count
        await rig.model.syncAndroidAppsIndex()
        #expect(rig.index.offered.count == offers + 1)
    }

    // MARK: Erase and restore

    @Test func aTapDuringAnEraseStartsNothingAndWritesNothing() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        rig.model.busy = BusyState(title: "Erasing virtual machine", detail: "Deleting.", progress: 0)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.driver.begun.isEmpty, "no start races the erase")
        #expect(rig.state.open.pending == nil && rig.state.open.banner == nil)
        #expect(rig.model.alert == nil)
        // The erase ends; the tap is not remembered and nothing starts by itself.
        rig.model.busy = nil
        rig.model.refreshPlan()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.driver.begun.isEmpty && rig.state.open.pending == nil)
        // A tap after the erase finds no virtual machine and says so as ever.
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.state.open.pending?.stage == .starting)
    }

    @Test func aRequestHeldForARestoreStartsOnlyOnceTheRestoredGuestIsAdopted() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        let item = SnapshotSummary(
            id: SnapshotID(), name: "Before", created: Date(), releaseID: "20261109-los24-r20", buildNumber: 1, diskGiB: 16,
            restore: .asIs, kept: SnapshotFigure(bytes: 7_000_000_000), freesWhenDeleted: SnapshotFigure(bytes: 4096))
        let fake = FakeSnapshotDriver(items: [item])
        rig.model.snapshotDriver = fake
        fake.holding = .restore
        let restoring = Task { await rig.model.restoreSnapshot(item.id) }
        #expect(await eventually { fake.activity.operation == .restore })
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        guard case .waiting(.snapshot, _)? = rig.state.open.pending?.stage else {
            Issue.record("the request should wait for the restore: \(String(describing: rig.state.open.pending))")
            return
        }
        // The files say what a start is now (the restore left an update to apply).
        fake.onRestore = { rig.driver.plan = .update(from: "r1", to: "r2") }
        fake.release()
        _ = await restoring.value
        #expect(rig.driver.begun.count == 1, "the held request starts Android once")
        #expect(rig.driver.begunGuests.first?.usedBytes == 7_000_000_000, "with the guest the restore left")
        #expect(rig.model.plan == .update(from: "r1", to: "r2"), "and the plan the files now say")
        #expect(rig.model.lifecycle.guest?.usedBytes == 7_000_000_000)
    }

    @Test func aRestoreThatRefusesStillReleasesTheHeldRequest() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        let item = SnapshotSummary(
            id: SnapshotID(), name: "Before", created: Date(), releaseID: "20261109-los24-r20", buildNumber: 1, diskGiB: 16,
            restore: .asIs, kept: SnapshotFigure(bytes: 4096), freesWhenDeleted: SnapshotFigure(bytes: 4096))
        let fake = FakeSnapshotDriver(items: [item])
        rig.model.snapshotDriver = fake
        fake.holding = .restore
        fake.nextRefusal = .missing
        let restoring = Task { await rig.model.restoreSnapshot(item.id) }
        #expect(await eventually { fake.activity.operation == .restore })
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        fake.release()
        _ = await restoring.value
        #expect(rig.driver.begun.count == 1)
        #expect(!rig.state.restoring)
    }

    @Test func aTapBetweenTheUnlockAndTheAdoptionOfARestoredGuestWaitsForTheAdoption() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        let item = SnapshotSummary(
            id: SnapshotID(), name: "Before", created: Date(), releaseID: "20261109-los24-r20", buildNumber: 1, diskGiB: 16,
            restore: .asIs, kept: SnapshotFigure(bytes: 7_000_000_000), freesWhenDeleted: SnapshotFigure(bytes: 4096))
        let fake = FakeSnapshotDriver(items: [item])
        rig.model.snapshotDriver = fake
        // The runtime has unlocked the guest's files and the result is on its way to the model: the tap lands now.
        var atTheTap: AppOpenStage?
        let component = comet.component
        fake.atUnlock = { [weak model = rig.model] in
            model?.requestAndroidApp(component, label: "Comet Hop")
            atTheTap = model?.androidApps.open.pending?.stage
        }
        fake.onRestore = { rig.driver.plan = .update(from: "r1", to: "r2") }
        let result = await rig.model.restoreSnapshot(item.id)
        guard case .done = result else { Issue.record("the restore should be done: \(result)"); return }
        if case .waiting(.snapshot, _)? = atTheTap {} else { Issue.record("the tap should wait for the adoption: \(String(describing: atTheTap))") }
        #expect(rig.driver.begun.count == 1, "the held request starts Android once")
        #expect(rig.driver.begunGuests.first?.usedBytes == 7_000_000_000, "with the guest the restore left, not the one before it")
        #expect(rig.model.plan == .update(from: "r1", to: "r2"), "and under the plan the files now say")
    }

    // MARK: Space and readiness

    @Test func aPauseForSpaceWhileAndroidIsMadeReadyMakesTheRequestWaitForTheAnswer() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readyDelay = .milliseconds(300)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.state.open.pending?.stage == .opening)
        rig.model.spacePause = SpacePause(freeBytes: 0, stage: .pausing)
        guard case .waiting(.space, _)? = rig.state.open.pending?.stage else {
            Issue.record("the request should wait for space: \(String(describing: rig.state.open.pending))")
            return
        }
        try await Task.sleep(for: .milliseconds(450))
        #expect(rig.tool.opened.isEmpty, "nothing is launched into a paused guest")
        // The person makes room and the guest resumes: the request is decided again and opens.
        rig.model.spacePause = nil
        #expect(await eventually { rig.tool.opened == [comet.component] })
    }

    @Test func aRunThatPausedBeforeTheLaunchIsNotLaunchedInto() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.readyDelay = .milliseconds(200)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        // The pause starts without the model's own hook (the readiness wait is what it raced).
        rig.model.spacePause = SpacePause(freeBytes: 0, stage: .paused)
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.tool.opened.isEmpty)
        #expect(rig.state.open.pending != nil)
    }

    @Test func aSecondAppOpensWhileTheFirstIsInFrontWithoutWaitingForHomeAgain() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.scripted.requiresHomeResumed = true
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(await eventually(3) { rig.tool.opened == [comet.component] })
        // The first app is resumed now: Home is not the activity in front.
        rig.scripted.homeInFront = false
        rig.model.requestAndroidApp(inkleaf.component, label: "Inkleaf Notes")
        #expect(await eventually(3) { rig.tool.opened == [comet.component, inkleaf.component] }, "one launch of the second app")
        #expect(rig.state.open.banner == nil, "no timeout")
        // A new run's boot is begun by a request: that request waits for Home, and an app in front keeps it from coming.
        rig.state.startDelay = .seconds(3600)
        rig.model.androidAppsRunEnded()
        rig.model.phase = .home
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        rig.model.phase = .running(.normal)
        rig.model.androidAppsBootFinished(recovery: false)
        #expect(await eventually(3) { rig.state.open.banner?.failure == .tookTooLong })
        #expect(rig.tool.opened == [comet.component, inkleaf.component])
    }

    @Test func theFirstOpenOfARunPastItsBootDoesNotWaitForHome() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.state.startDelay = .seconds(3600)
        rig.scripted.requiresHomeResumed = true
        // An app is in front, and no request of this run has asked anything: the run's boot completed, nobody waited for it.
        rig.scripted.homeInFront = false
        rig.model.androidAppsBootFinished(recovery: false)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(await eventually(3) { rig.tool.opened == [comet.component] }, "the first open launches without waiting for Home")
        #expect(rig.state.open.banner == nil)
        #expect(rig.scripted.homeReachedAsked == [true])
    }

    @Test func aRequestThatStartedTheBootStillWaitsForHomesFirstResume() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        rig.state.startDelay = .seconds(3600)
        rig.scripted.requiresHomeResumed = true
        rig.scripted.homeInFront = false
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.state.open.pending?.stage == .starting)
        // The boot it started completes; the launcher is not up (something else is in front).
        rig.model.phase = .running(.normal)
        rig.model.androidAppsBootFinished(recovery: false)
        #expect(await eventually(3) { rig.state.open.banner?.failure == .tookTooLong }, "the look for Home was kept for it")
        #expect(rig.tool.opened.isEmpty)
        #expect(rig.scripted.homeReachedAsked == [false])
        // The boot is over for the requests that come later (Try Again is one), with Home in front or not.
        rig.scripted.homeInFront = true
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(await eventually(3) { rig.tool.opened == [comet.component] })
        rig.scripted.homeInFront = false
        rig.model.requestAndroidApp(inkleaf.component, label: "Inkleaf Notes")
        #expect(await eventually(3) { rig.tool.opened == [comet.component, inkleaf.component] })
        #expect(rig.scripted.homeReachedAsked == [false, true, true])
    }

    @Test func aRequestAfterTheBootDoesNotWaitForHomeWhenTheRequestThatBeganItStoppedAtSetup() async throws {
        let rig = try rig(phase: .home, plan: .normal)
        rig.state.startDelay = .seconds(3600)
        rig.scripted.requiresHomeResumed = true
        rig.scripted.readiness = .setupUnfinished
        // Icon A starts Android; the boot completes and Android's own setup is still on the screen.
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(rig.state.open.pending?.stage == .starting)
        rig.model.phase = .running(.normal)
        rig.model.androidAppsBootFinished(recovery: false)
        #expect(await eventually(3) { rig.state.open.banner?.failure == .setupUnfinished })
        // The setup is finished, with another app in front. Icon B opens at once: the boot is over.
        rig.scripted.readiness = .ready
        rig.scripted.homeInFront = false
        rig.model.requestAndroidApp(inkleaf.component, label: "Inkleaf Notes")
        #expect(await eventually(3) { rig.tool.opened == [inkleaf.component] }, "icon B launches without waiting for Home")
        #expect(rig.state.open.banner == nil)
        #expect(rig.scripted.homeReachedAsked == [false, true])
    }

    @Test func aLaunchAlreadySentIsNotSentAgainByAPauseAndAResume() async throws {
        let rig = try rig(phase: .running(.normal))
        // The command is out and its reply is slow.
        rig.tool.delay = .milliseconds(300)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(await eventually(3) { rig.tool.opened == [comet.component] }, "the tool received the command")
        rig.model.spacePause = SpacePause(freeBytes: 0, stage: .pausing)
        try await Task.sleep(for: .milliseconds(450))
        rig.model.spacePause = nil
        try await Task.sleep(for: .milliseconds(450))
        #expect(rig.tool.opened == [comet.component], "exactly one launch")
        #expect(rig.state.open.pending == nil, "the reply ended the request")
        #expect(rig.state.open.banner == nil)
    }

    // MARK: Refresh ownership

    @Test func anEraseDuringARefreshLeavesNothingOfIt() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.tool.delay = .milliseconds(40)
        let refreshing = Task { await rig.model.refreshAndroidApps() }
        #expect(await eventually { rig.state.refreshing })
        rig.model.androidAppsErased()
        _ = await refreshing.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.state.apps.isEmpty && rig.state.store.catalog() == nil)
        #expect(!rig.state.refreshing && rig.state.iconsLeft == 0)
        #expect(AndroidAppsHub.shared.entities().isEmpty)
    }

    @Test func aRefreshAfterAnInstallWaitsForTheOneUnderWayAndListsAgain() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.tool.delay = .milliseconds(30)
        let first = Task { await rig.model.refreshAndroidApps() }
        #expect(await eventually { rig.state.inFlight != nil })
        let extra = AndroidApp(
            component: try #require(AndroidComponent(packageName: "com.example.newcomer", activityClass: "com.example.newcomer.Main")),
            label: "Newcomer", builtIn: false, iconTag: "0000000000000042")
        rig.tool.install(extra)
        await rig.model.refreshAndroidApps(afterAChange: true)
        _ = await first.value
        #expect(rig.state.apps.contains { $0.id == extra.id })
    }

    @Test func anInstallThatLandsAfterTheListWasCapturedIsListedByTheRefreshThatFollows() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.tool.delay = .milliseconds(40)
        let first = Task { await rig.model.refreshAndroidApps() }
        // The refresh has captured the list it will keep...
        #expect(await eventually { rig.tool.listingsAsked >= 1 })
        // ...and then an app is installed, and the install asks for a refresh after it.
        let extra = AndroidApp(
            component: try #require(AndroidComponent(packageName: "com.example.latecomer", activityClass: "com.example.latecomer.Main")),
            label: "Latecomer", builtIn: false, iconTag: "0000000000000043")
        rig.tool.install(extra)
        await rig.model.refreshAndroidApps(afterAChange: true)
        _ = await first.value
        #expect(await eventually { rig.state.apps.contains { $0.id == extra.id } && !rig.state.refreshing })
        #expect(AndroidAppsHub.shared.entities().contains { $0.id == extra.id })
    }

    @Test func anInstallThatLandsAfterTheListWasCapturedIsListedOnceAPauseForSpaceEnds() async throws {
        let rig = try rig(phase: .running(.normal))
        rig.tool.delay = .milliseconds(40)
        // The system takes the first refresh's offer slowly.
        rig.index.holdsNextOffer = true
        let first = Task { await rig.model.refreshAndroidApps() }
        #expect(await eventually { rig.tool.listingsAsked >= 1 })
        // An app is installed after the list was captured, and the install asks for a refresh after it.
        let extra = AndroidApp(
            component: try #require(AndroidComponent(packageName: "com.example.latecomer", activityClass: "com.example.latecomer.Main")),
            label: "Latecomer", builtIn: false, iconTag: "0000000000000043")
        rig.tool.install(extra)
        await rig.model.refreshAndroidApps(afterAChange: true)
        // All guest work of the refresh is done; the offer is under way when Android pauses for space.
        #expect(await eventually { rig.index.events.contains("offer-started") })
        rig.model.spacePause = SpacePause(freeBytes: 0, stage: .paused)
        rig.index.letGo()
        _ = await first.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(!rig.state.apps.contains { $0.id == extra.id }, "nothing is asked of a paused guest")
        #expect(rig.tool.listingsAsked == 1)
        // The person makes room and the guest resumes: the refresh that was owed is made.
        rig.model.spacePause = nil
        #expect(await eventually(3) { rig.state.apps.contains { $0.id == extra.id } && !rig.state.refreshing }, "the install is listed")
        #expect(AndroidAppsHub.shared.entities().contains { $0.id == extra.id })
    }

    @Test func anInstallCommittedWhileAndroidIsPausedForSpaceIsListedOnceItResumes() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        // No refresh is under way: Android pauses for space, and an install that was committed asks for a refresh.
        rig.model.spacePause = SpacePause(freeBytes: 0, stage: .paused)
        let extra = AndroidApp(
            component: try #require(AndroidComponent(packageName: "com.example.latecomer", activityClass: "com.example.latecomer.Main")),
            label: "Latecomer", builtIn: false, iconTag: "0000000000000043")
        rig.tool.install(extra)
        let asked = await rig.model.refreshAndroidApps(afterAChange: true)
        #expect(!asked, "nothing is asked of a paused guest")
        let listings = rig.tool.listingsAsked
        // The person makes room and the guest resumes: the refresh that was owed is made.
        rig.model.spacePause = nil
        #expect(await eventually(3) { rig.state.apps.contains { $0.id == extra.id } && !rig.state.refreshing }, "the install is listed")
        #expect(rig.tool.listingsAsked == listings + 1)
        #expect(AndroidAppsHub.shared.entities().contains { $0.id == extra.id })
    }

    // MARK: How an open ends, more

    @Test func anImageWithoutTheToolEndsAnOpenWithItsOwnBannerAndWithdrawsTheApps() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        rig.tool.answer(open: comet.component, .unavailable)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(await eventually { rig.state.open.banner?.failure == .toolMissing })
        #expect(rig.state.open.banner?.component == nil, "no Try Again")
        #expect(await eventually { rig.state.unavailable && rig.state.apps.isEmpty })
        #expect(AndroidAppsHub.shared.entities().isEmpty)
    }

    @Test func aRenamedLauncherOpensOnlyWhereThePackageHadExactlyOne() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        #expect(rig.state.store.record(forID: comet.id)?.launchers == 1)
        // The app renamed its launcher activity: the tool no longer finds the saved one.
        let renamed = AndroidApp(
            component: try #require(AndroidComponent(packageName: comet.component.packageName, activityClass: "com.example.comethop.NewMain")),
            label: "Comet Hop", builtIn: false, iconTag: "0000000000000099")
        rig.tool.remove(comet.id)
        rig.tool.install(renamed)
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        #expect(await eventually { rig.tool.opened.contains(renamed.component) })
        #expect(rig.state.open.banner == nil)
    }

    @Test func aReplacementLaunchNotYetSentWaitsForTheSpaceNoticeToClear() async throws {
        let rig = try rig(phase: .running(.normal))
        await rig.model.refreshAndroidApps()
        let renamed = AndroidApp(
            component: try #require(AndroidComponent(packageName: comet.component.packageName, activityClass: "com.example.comethop.NewMain")),
            label: "Comet Hop", builtIn: false, iconTag: "0000000000000099")
        rig.tool.remove(comet.id)
        rig.tool.install(renamed)
        rig.tool.delay = .milliseconds(300)
        let listings = rig.tool.listingsAsked
        rig.model.requestAndroidApp(comet.component, label: "Comet Hop")
        // The first command was refused and the apps are listed again to learn why...
        #expect(await eventually(3) { rig.tool.listingsAsked == listings + 1 })
        // ...when Android is low on space, the pause does not take, and the space notice stays.
        rig.model.spacePause = SpacePause(freeBytes: 0, stage: .pausing)
        try await Task.sleep(for: .milliseconds(450))
        #expect(rig.tool.opened == [comet.component], "no replacement launch is sent under the notice")
        #expect(rig.state.open.banner == nil)
        // The person makes room and the notice clears: the request is decided again and opens the renamed app.
        rig.tool.delay = .milliseconds(1)
        rig.model.spacePause = nil
        #expect(await eventually(3) { rig.tool.opened.contains(renamed.component) })
        #expect(rig.state.open.banner == nil)
    }
}
