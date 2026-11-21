// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import SwiftUI

/// The words that the frame rate is lowered while the device is hot, over the
/// top of the session, in the shape of the graphics notice: it takes touches
/// only where it is drawn, and it goes when the person dismisses it or after
/// `ThermalNotice.visibleFor`.
struct ThermalNoticeBanner: View {
    let dismiss: () -> Void

    var body: some View {
        // The capsule is as wide as its words when they fit on one line, so a
        // short text in any language is not lost in a wide one; a longer text
        // wraps inside the cap.
        ViewThatFits(in: .horizontal) {
            banner(oneLine: true)
            banner(oneLine: false)
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thermal-notice")
    }

    private func banner(oneLine: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "thermometer.high")
                .font(.title3)
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            Text(ThermalNotice.text)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: oneLine, vertical: true)
            Button(ThermalNotice.dismissLabel, action: dismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("thermal-notice-dismiss")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
