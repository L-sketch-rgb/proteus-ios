import SwiftUI
import ProteusKit

/// The time menu of docs/design/v9-commands-drafts-perf.md §3: fixed presets,
/// a Custom section (date, hour, minute in local time) and the resolved wording
/// with a primary "Schedule" button.
struct ScheduleSheet: View {
    @Environment(\.proteusTheme) private var theme
    let title: String
    let initialDate: Date?
    let onSchedule: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var preset: SchedulePreset?
    @State private var customExpanded = false
    @State private var customDay = 0
    @State private var customHour = 12
    @State private var customMinute = 0

    private var calendar: Calendar { Calendar.current }

    private var customDates: [CustomDateOption] {
        SchedulePresets.customDates(now: now, calendar: calendar)
    }

    private var choice: ScheduleChoice? {
        if customExpanded {
            guard customDay < customDates.count else { return nil }
            return SchedulePresets.customChoice(
                day: customDates[customDay].date,
                hour: customHour,
                minute: customMinute,
                now: now,
                calendar: calendar
            )
        }
        guard let preset else { return nil }
        return SchedulePresets.choice(preset, now: now, calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Presets") {
                    ForEach(SchedulePreset.allCases) { option in
                        Button {
                            preset = option
                            customExpanded = false
                        } label: {
                            HStack {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if !customExpanded, preset == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        customExpanded = true
                        if let preset {
                            let resolved = SchedulePresets.choice(preset, now: now, calendar: calendar)
                            let components = calendar.dateComponents([.hour, .minute], from: resolved.date)
                            customHour = components.hour ?? customHour
                            customMinute = (components.minute ?? 0) - (components.minute ?? 0) % 5
                        }
                        // "Custom…" selects the nearest date row (today by default).
                        customDay = 0
                    } label: {
                        HStack {
                            Text("Custom…")
                                .foregroundStyle(.primary)
                            Spacer()
                            if customExpanded {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }

                    if customExpanded {
                        Picker("Day", selection: $customDay) {
                            ForEach(customDates.indices, id: \.self) { index in
                                Text(customDates[index].label).tag(index)
                            }
                        }
                        Picker("Hour", selection: $customHour) {
                            ForEach(SchedulePresets.hourOptions, id: \.self) { hour in
                                Text(String(format: "%02d", hour)).tag(hour)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Minute", selection: $customMinute) {
                            ForEach(SchedulePresets.minuteOptions, id: \.self) { minute in
                                Text(String(format: "%02d", minute)).tag(minute)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Custom")
                } footer: {
                    Text("Times are in your local time zone.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") { confirm() }
                        .disabled(choice == nil)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text(choice?.phrase ?? "Choose a time")
                        .font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(theme.chrome)
            }
            .onKeyPress(.escape) {
                dismiss()
                return .handled
            }
            .onKeyPress(.return) {
                confirm()
                return .handled
            }
        }
        .presentationDetents([.medium, .large])
        // v10 §1: the picker is closeable by the Cancel button, Esc, or the
        // native swipe-down; closing it cancels the schedule.
        .presentationDragIndicator(.visible)
        .onAppear {
            now = Date()
            if let initialDate {
                customExpanded = true
                preset = nil
                let components = calendar.dateComponents([.hour, .minute], from: initialDate)
                customHour = components.hour ?? customHour
                customMinute = (components.minute ?? 0) - (components.minute ?? 0) % 5
                let options = SchedulePresets.customDates(now: now, calendar: calendar)
                customDay = options.firstIndex { calendar.isDate($0.date, inSameDayAs: initialDate) } ?? 0
            }
        }
    }

    private func confirm() {
        guard let choice else { return }
        onSchedule(choice.date)
        dismiss()
    }
}
