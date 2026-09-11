// The Activity window: what happened to the microphone, as pictures rather than sentences.
//
// It used to be a section of the main window, with an "Earlier" disclosure that was the one
// thing there able to change the window's height — and the main window is sized to its
// content, so opening it resized the whole window. It is a window of its own now, sized by the
// user, opened from Window ▸ Activity and from the banner that reports a failed restore.
//
// A row reads left to right: who acted (the badge), then which microphone moved where. The
// badge's colour is never the only signal — its symbol differs too — and the sentence the
// first version printed survives as the row's accessibility label, so VoiceOver reads words
// and everyone else reads the picture.
//
// Time is shown to the minute and no finer: "Just now", "12 min ago", then the clock time
// under a day header. The first version printed `Text(date, style: .relative)` — "6 min,
// 44 sec" — which changed every row every second in a list the user reads once.

import CoreAudio
import SwiftUI

// `@MainActor` on each view in this file, for the reason MainWindow gives.
@MainActor
public struct ActivityWindow: View {
    public static let sceneID = "activity"

    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Group {
            if let newest = model.activity.first {
                // One timeline for the whole window, anchored on the newest entry: that row turns
                // from "Just now" to "1 min ago" at exactly sixty seconds, and every other label
                // is at most a minute from due. `.everyMinute` ticks on the clock's minute
                // instead, which left "Just now" up for as long as two minutes.
                TimelineView(.periodic(from: newest.at, by: 60)) { context in
                    list(now: context.date)
                }
            } else {
                ContentUnavailableView(Copy.activityEmpty, systemImage: "clock",
                                       description: Text(Copy.activityEmptyDetail))
            }
        }
        .frame(minWidth: 380, minHeight: 240)
    }

    private func list(now: Date) -> some View {
        Form {
            ForEach(ActivityTime.days(model.activity, now: now)) { day in
                Section(day.title) {
                    ForEach(day.entries) { ActivityRow(entry: $0, now: now, model: model) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The time labels, as plain functions so `MicpegApp activity` prints exactly what the window
/// shows.
public enum ActivityTime {
    public static func label(for date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return Copy.justNow }
        if elapsed < 3600 { return Copy.minutesAgo(Int(elapsed / 60)) }
        return date.formatted(.dateTime.hour().minute())
    }

    public static func dayTitle(for date: Date, now: Date, calendar: Calendar = .current)
        -> String {
        if calendar.isDate(date, inSameDayAs: now) { return Copy.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return Copy.yesterday
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    public struct Day: Identifiable {
        public let title: String
        public var entries: [Activity]
        /// The oldest entry's id: unique, and steady while new entries arrive at the top. The
        /// title is neither. The log stamps local time with no zone, so after a time-zone change
        /// — or across a daylight-saving fall-back — its lines are no longer in time order, the
        /// same title can come round twice, and a `ForEach` keyed on it had two sections with
        /// one identity.
        public var id: String { entries.last?.id ?? title }
    }

    /// Newest first in, newest day first out. Computed per tick rather than stored, because
    /// "Today" becomes "Yesterday" at midnight without any entry changing.
    public static func days(_ newestFirst: [Activity], now: Date) -> [Day] {
        var days: [Day] = []
        for entry in newestFirst {
            let title = dayTitle(for: entry.at, now: now)
            if days.last?.title == title {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Day(title: title, entries: [entry]))
            }
        }
        return days
    }
}

@MainActor
struct ActivityRow: View {
    let entry: Activity
    let now: Date
    let model: AppModel

    var body: some View {
        let time = ActivityTime.label(for: entry.at, now: now)
        LabeledContent {
            Text(time)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: badge)
                    .font(.title3)
                    .foregroundStyle(badgeStyle)
                content
                if entry.count > 1 {
                    Text(Copy.repeatCount(entry.count))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        // `.ignore`, not `.combine`: combining reads every symbol's own label as well —
        // "Right arrow", "Headphones" — between the words that actually carry the meaning.
        //
        // The time is in the label rather than in `.accessibilityValue`. Measured: an element
        // built this way inside a grouped Form is published as AXUnknown, and AXUnknown carries
        // no AXValue at all, so the value was silently dropped and VoiceOver never heard when
        // anything happened. The static-text trait is there to give it a role that reads.
        //
        // Verbatim, because the sentence is already translated. Written as a literal this was a
        // LocalizedStringKey, "%@ %@", looked up in the table and never found — right only by
        // accident, and the first thing scripts/l10n-check.sh reported.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(verbatim: "\(Copy.accessibilitySentence(for: entry, target: kept.name)) \(time)"))
        .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .restored(let to, let from):
            flow(from: from, to: to)
        case .chose(let to, let from):
            flow(from: from, to: to ?? kept)
        case .switchedAway(let to):
            flow(from: nil, to: to)
        case .switchedBack:
            flow(from: nil, to: kept)
        case .paused:
            label(Copy.pausedLabel)
        case .resumed(let to, let from):
            label(Copy.resumedLabel)
            flow(from: from, to: to ?? kept)
        case .started:
            label(Copy.startedLabel)
            DeviceChip(device: kept, model: model)
        case .reconnected:
            label(Copy.reconnectedLabel)
            DeviceChip(device: kept, model: model)
        case .backInUse:
            label(Copy.backInUseLabel)
            DeviceChip(device: kept, model: model)
        case .disconnected:
            label(Copy.disconnectedLabel)
            DeviceChip(device: kept, model: model)
        case .backedOff:
            label(Copy.backedOffLabel)
        case .problem(let problem):
            label(Copy.problemLabel(problem))
        }
    }

    /// The kept microphone, for rows whose log line names no device. Named from the config as
    /// it is now, the same as the main window's summary does.
    private var kept: Activity.Device {
        Activity.Device(name: model.targetName ?? Copy.noDevice)
    }

    private func label(_ text: String) -> some View {
        Text(text).lineLimit(1)
    }

    @ViewBuilder
    private func flow(from: Activity.Device?, to: Activity.Device) -> some View {
        if let from {
            DeviceChip(device: from, model: model)
        }
        Image(systemName: "arrow.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        DeviceChip(device: to, model: model)
    }

    private var badge: String {
        switch entry.kind {
        case .restored:                            return "arrow.uturn.backward.circle.fill"
        case .chose, .switchedAway, .switchedBack: return "person.crop.circle.fill"
        case .paused:                              return "pause.circle.fill"
        case .resumed:                             return "play.circle.fill"
        case .started:                             return "power.circle.fill"
        case .reconnected, .backInUse:             return "mic.circle.fill"
        case .disconnected:                        return "mic.slash.circle.fill"
        case .backedOff, .problem:                 return "exclamationmark.triangle.fill"
        }
    }

    /// app-ui.md: semantic colours only. The tint is kept for Micpeg acting — the thing the
    /// app exists to do — so it is the colour the eye finds first in the list.
    private var badgeStyle: AnyShapeStyle {
        switch entry.actor {
        case .micpeg:        return AnyShapeStyle(.tint)
        case .you, .system:  return AnyShapeStyle(.secondary)
        case .problem:       return AnyShapeStyle(.orange)
        }
    }
}

/// A microphone: what kind of device it is, then its name.
@MainActor
struct DeviceChip: View {
    let device: Activity.Device
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(for: transport))
                .foregroundStyle(.secondary)
            Text(device.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// The log's tag when it wrote one, otherwise whatever the device connected under that name
    /// reports now. A device that is neither tagged nor connected gets the plain microphone.
    private var transport: UInt32? {
        device.transport ?? model.inputs.first { $0.name == device.name }?.transportCode
    }

    /// From the SDK's constants rather than codes typed out by hand — AudioDevices.swift keeps
    /// the record of what a hand-typed `"bltn"` cost the first time.
    static func symbol(for transport: UInt32?) -> String {
        guard let transport else { return "mic.fill" }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        default:
            return "mic.fill"
        }
    }
}

// MARK: - Previews

#Preview("Activity") {
    ActivityWindow(model: .preview(activity: AppModel.previewActivity))
        .frame(width: 460, height: 560)
}

#Preview("Empty") {
    ActivityWindow(model: .preview())
        .frame(width: 460, height: 300)
}
