import Foundation
import SwiftUI

/// Opt-in probes and one-variable experiments for reproducing a scrolling hang.
/// The normal app uses the validated eager layout; explicit variants retain the diagnostic comparisons.
@MainActor
enum ScrollDiagnostics {
    enum Variant: String {
        case baseline
        case noSelection = "no-selection"
        case eagerStack = "eager-stack"
        case noAutoscroll = "no-autoscroll"
    }

    static let variant = Variant(rawValue: HangDiagnostics.configurationValue(for: "AGENT_KANBAN_SCROLL_VARIANT") ?? "") ?? .eagerStack
    static var allowsTextSelection: Bool { variant != .noSelection }
    static var allowsAutoscroll: Bool { variant != .noAutoscroll }

    struct Context {
        let conversationID: String
        let messageCount: Int
        let runCount: Int

        @MainActor var fields: [String: String] {
            ["conversation_id": conversationID,
             "message_count": String(messageCount),
             "run_count": String(runCount),
             "variant": variant.rawValue]
        }
    }

    struct Geometry: Equatable {
        let contentHeight: Double
        let viewportHeight: Double
        let visibleHeight: Double
        let scrollY: Double

        init(_ geometry: ScrollGeometry) {
            contentHeight = Double(geometry.contentSize.height)
            viewportHeight = Double(geometry.containerSize.height)
            visibleHeight = Double(geometry.visibleRect.height)
            scrollY = Double(geometry.contentOffset.y)
        }
    }

    // This storage is outside Observation/SwiftUI State, so logging cannot feed layout.
    private static var lastRecorded: [String: TimeInterval] = [:]

    static func record(event: String, context: Context, geometry: Geometry? = nil, reason: String? = nil, throttled: Bool = false) {
        guard HangDiagnostics.shared.isEnabled else { return }
        if throttled {
            let key = event + ":" + context.conversationID
            let now = ProcessInfo.processInfo.systemUptime
            guard now - (lastRecorded[key] ?? -.infinity) >= 1 else { return }
            // Bound metadata retained when navigating through many conversations.
            if lastRecorded.count > 64 { lastRecorded.removeAll(keepingCapacity: true) }
            lastRecorded[key] = now
        }
        var fields = context.fields
        if let geometry {
            fields["content_height"] = String(geometry.contentHeight)
            fields["viewport_height"] = String(geometry.viewportHeight)
            fields["visible_height"] = String(geometry.visibleHeight)
            fields["scroll_y"] = String(geometry.scrollY)
        }
        if let reason { fields["reason"] = reason }
        HangDiagnostics.shared.record(event: event, fields: fields)
    }
}
