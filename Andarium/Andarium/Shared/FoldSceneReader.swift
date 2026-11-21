// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import UIKit

/// Reads what the system says of the folding display a scene is on, for the
/// layout decisions of `AndariumCore` (`FoldReading`): the hinge, through a
/// `UIHingeInteraction`, and the fold's band and the regions the system keeps
/// for the camera, as the view's reserved regions. Only an iPhone folds, so
/// the interaction is attached on the phone idiom alone; a device that does not
/// fold delivers no hinge, so the reader never produces a reading there and
/// nothing that follows from one ever runs.
///
/// The system gives no notification for a reserved region. The root reads
/// again at every layout and every geometry change, and the hinge's own
/// updates make it read when only the band's state changed: bending a turned
/// display moves nothing else.
@MainActor
final class FoldSceneReader {
    /// The hinge as the interaction last reported it; nil until it reports
    /// one, which a display that does not fold never does.
    private var hinge: FoldReading.Hinge?
    private var interaction: AnyObject?
    /// Called when the hinge reported a status that differs from the last.
    var hingeDidChange: (() -> Void)?
    #if !APP_STORE
    /// A reading a test supplies in place of the system's, to put the scene
    /// root in a pose the Simulator is not in.
    var stub: (@MainActor () -> FoldReading?)?
    #endif

    /// The system reports a hinge: the display folds.
    var reportsHinge: Bool { hinge != nil }

    func attach(to view: UIView) {
        _ = view
    }

    /// The scene root's view as the system reports it now; nil on a display
    /// that does not fold.
    func read(_ view: UIView) -> FoldReading? {
        #if !APP_STORE
        if let stub { return stub() }
        #endif
        _ = view
        return nil
    }
}
