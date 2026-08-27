import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Haptic feedback, in one place so the platform check is written once.
///
/// The build plan asks for haptics on the scrub bar's jump ticks. The whole
/// value is being able to feel where the events are without watching the bar,
/// which means firing on a CROSSING and not on every touch move: a continuous
/// buzz through a drag is noise, and noise is not information.
enum Haptics {

    /// A light tap, for crossing an event tick.
    static func event() {
        #if canImport(UIKit)
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred(intensity: 0.7)
        #endif
    }

    /// A heavier one, for a run finishing.
    static func completed() {
        #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
