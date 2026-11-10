import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// The companion's widget extension. Its only job is to draw the Claude bridge
// Live Activity: on the Lock Screen and in the Dynamic Island.

@main
struct ClaudeBridgeWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeBridgeLiveActivity()
    }
}

struct ClaudeBridgeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeBridgeActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Claude", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(Self.title(context)).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(Self.detail(context))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        StopButton()
                    }
                }
            } compactLeading: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Self.tint(context))
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(Self.tint(context))
            }
        }
    }

    static func title(_ context: ActivityViewContext<ClaudeBridgeActivityAttributes>) -> String {
        if context.isStale { return "Claude Bridge · check status" }
        switch context.state.phase {
        case "live": return "Claude Bridge is live"
        case "starting": return "Claude Bridge starting…"
        default: return "Claude Bridge ended"
        }
    }

    static func detail(_ context: ActivityViewContext<ClaudeBridgeActivityAttributes>) -> String {
        if context.isStale { return "Open iCTRL to refresh" }
        if let ends = context.state.endsAt, context.state.phase == "live" {
            return "Auto-off if idle by \(ends.formatted(date: .omitted, time: .shortened))"
        }
        return context.attributes.host
    }

    static func tint(_ context: ActivityViewContext<ClaudeBridgeActivityAttributes>) -> Color {
        if context.isStale { return .yellow }
        return context.state.phase == "live" ? .green : .secondary
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<ClaudeBridgeActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(ClaudeBridgeLiveActivity.tint(context))
            VStack(alignment: .leading, spacing: 2) {
                Text(ClaudeBridgeLiveActivity.title(context))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(ClaudeBridgeLiveActivity.detail(context))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 4) {
                    Text("Running")
                    Text(context.attributes.startedAt, style: .timer).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            StopButton()
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopClaudeSessionIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.caption.weight(.semibold))
        }
        .tint(.red)
    }
}
