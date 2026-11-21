// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import AndariumCoreTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The session's Settings starts with what a new person came for: Install APK
/// and the file browser, in that order, above the statistics, the developer
/// options and the diagnostics. Each keeps its own condition; what is not
/// offered leaves the view starting with what comes next.
@MainActor
@Suite(.serialized)
struct SettingsOrderTests {
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
    )

    /// The rows that stand for each section, as the view labels them, in the
    /// order Settings draws the sections.
    private enum Row: String, CaseIterable {
        case install = "Install APK"
        case files = "Internal storage"
        case stats = "CPU"
        case developer = "ADB over network"
        case diagnostics = "Create bug report"
    }

    private func model(
        capabilities: Capabilities = .device, browser: Bool = true, mode: StartMode = .normal
    ) -> AppModel {
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: capabilities, createRequirementBytes: 1
        )
        model.driver = StubDriver(plan: .normal)
        model.refreshPlan()
        if browser {
            model.fileBrowser = FileBrowserModel(backend: FileBrowserModelTests.ScriptedBackend(), center: NotificationCenter())
        }
        model.start(mode)
        model.finishBoot(mode == .recovery ? .recovery : .normal)
        return model
    }

    /// The rows Settings draws, top to bottom, in a view tall enough to draw
    /// every section.
    private func rows(of model: AppModel) async throws -> [Row] {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let container = UIViewController()
        lease.window.rootViewController = container
        let settings = UIHostingController(rootView: SessionSettingsSheet(large: true).environment(model))
        container.addChild(settings)
        settings.view.frame = CGRect(x: 0, y: 0, width: 390, height: 2600)
        container.view.addSubview(settings.view)
        settings.didMove(toParent: container)
        defer {
            settings.willMove(toParent: nil)
            settings.view.removeFromSuperview()
            settings.removeFromParent()
        }
        var found: [Row] = []
        var steady = 0
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, steady < 4 {
            try await Task.sleep(for: .milliseconds(250))
            settings.view.setNeedsLayout()
            settings.view.layoutIfNeeded()
            let elements = SideKeysTouchTests.elements(in: settings.view).sorted { $0.frame.minY < $1.frame.minY }
            var now: [Row] = []
            for element in elements {
                guard let row = Row.allCases.first(where: { element.label.contains($0.rawValue) }), !now.contains(row)
                else { continue }
                now.append(row)
            }
            // The view has settled when it draws the same rows four times running.
            steady = !now.isEmpty && now == found ? steady + 1 : 0
            found = now
        }
        return found
    }

    @Test func installApkAndTheFileBrowserComeFirstInThatOrder() async throws {
        let order = try await rows(of: model())
        #expect(order == [.install, .files, .stats, .developer, .diagnostics], "Settings draws \(order)")
    }

    @Test func theViewStartsWithWhatIsOfferedWhenASectionIsNot() async throws {
        var noInstall = Capabilities.device
        noInstall.apkInstall = false
        #expect(try await rows(of: model(capabilities: noInstall)) == [.files, .stats, .developer, .diagnostics])
        var noFiles = Capabilities.device
        noFiles.guestFiles = false
        #expect(try await rows(of: model(capabilities: noFiles)) == [.install, .stats, .developer, .diagnostics])
        // No browser available: the file browser's section is not drawn.
        #expect(try await rows(of: model(browser: false)) == [.install, .stats, .developer, .diagnostics])
        var neither = Capabilities.device
        neither.apkInstall = false
        neither.guestFiles = false
        #expect(try await rows(of: model(capabilities: neither)) == [.stats, .developer, .diagnostics])
    }

    /// Recovery runs no adb: neither section, nor the developer options and
    /// the diagnostics, are offered, as before.
    @Test func recoveryOffersNoneOfThem() async throws {
        let order = try await rows(of: model(mode: .recovery))
        #expect(order == [.stats], "Settings draws \(order)")
    }
}
