// SPDX-License-Identifier: GPL-2.0-or-later

import Testing

@testable import AndariumCore

struct CapabilitiesTests {
    @Test func theDeviceOffersWhatTheRuntimeDoes() {
        let device = Capabilities.device
        #expect(device.bugReport && device.apkInstall && device.adbOverNetwork && device.guestFiles)
        // The statistics are the runtime's own readings.
        #expect(device.statistics)
    }

    @Test func installApkIsOfferedInANormalSessionOfARuntimeThatInstalls() {
        let installs = Capabilities.device
        #expect(installs.offersApkInstall(in: .normal))
        // Recovery runs no adb.
        #expect(!installs.offersApkInstall(in: .recovery))
        var without = installs
        without.apkInstall = false
        #expect(!without.offersApkInstall(in: .normal) && !without.offersApkInstall(in: .recovery))
    }

    @Test func thePreviewPretendsToDoEverything() {
        let preview = Capabilities.preview
        #expect(preview.bugReport && preview.apkInstall && preview.adbOverNetwork && preview.guestFiles)
        #expect(preview.statistics)
    }
}
