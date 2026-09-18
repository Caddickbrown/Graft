import SwiftUI

// MARK: - Schedule editor
//
// The two writing surfaces for an issue's dates and its recurrence, built from
// FormKit so they match the rest of the app rather than looking like a page out
// of Calendar.app.
//
// Both live here rather than in the two forms that use them, because "new
// issue" and "edit issue" disagreeing about what a repeat rule looks like is
// exactly the drift `GraftIssueRow` was created to end.

// MARK: - Date row

/// A date with an explicit "no date" state.
///
/// `DatePicker` has no empty. Bound to a plain `Date` it always holds one, so a
/// form built the obvious way silently gives every issue a due date of today —
/// which is worse than useless, because the server treats `""` as "not due" and
/// an issue that is not due should not appear in tomorrow's overdue list.
///
/// So the stored value is the server's `""`-or-`yyyy-MM-dd` string, and the
/// picker is only shown once the user has asked for one. Opening it writes
/// nothing; only moving it does.
struct GraftDateRow: View {
    let label: String
    /// `""` for no date.
    @Binding var value: String
    /// Shown under the row when set — "in 3 days", "2d overdue".
    var showsRelative: Bool = true

    @State private var isPicking = false

    private var hasDate: Bool { !value.isEmpty }

    /// What the picker starts on when there is no date yet. Today, in the
    /// device's own calendar — `GraftDate.day(from:)` and `dayString(from:)`
    /// are a matched pair, so a date read out and written straight back is
    /// unchanged rather than walking a day west of Greenwich.
    private var pickerBinding: Binding<Date> {
        Binding(
            get: { GraftDate.day(from: value) ?? Calendar.current.startOfDay(for: Date()) },
            set: { value = GraftDate.dayString(from: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack(spacing: GraftMetrics.spaceXS) {
                Text(label.uppercased())
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .foregroundStyle(Color.gInk3)
                    .tracking(GraftType.microTracking)
                Spacer(minLength: 0)
                if hasDate {
                    Button {
                        value = ""
                        isPicking = false
                    } label: {
                        Text("Clear")
                            .font(GraftFont.text(GraftType.micro, .semibold))
                            .foregroundStyle(Color.gInk3)
                            .frame(minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(label.lowercased())")
                }
            }

            Button {
                isPicking.toggle()
            } label: {
                HStack(spacing: GraftMetrics.spaceXS) {
                    Image(systemName: hasDate ? "calendar" : "calendar.badge.plus")
                        .font(.system(size: 13))
                        .foregroundStyle(hasDate ? Color.gAccentText : Color.gInk3)
                    Text(hasDate ? (GraftDate.mediumDate(value) ?? value) : "No date")
                        .font(GraftFont.text(GraftType.body, hasDate ? .medium : .regular))
                        .foregroundStyle(hasDate ? Color.gInk : Color.gInk3)
                    if showsRelative, hasDate, let relative = GraftDate.dueLabel(value) {
                        Text("· \(relative)")
                            .font(GraftFont.text(GraftType.caption))
                            .foregroundStyle((GraftDate.daysUntil(value) ?? 0) < 0
                                             ? Color.gRed : Color.gInk2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isPicking ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.gInk3)
                }
                .frame(minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isPicking {
                // The shortcuts first: on a phone, "tomorrow" is most of what
                // anyone means, and reaching it through a month grid is three
                // taps for a one-tap idea.
                FlowRow(spacing: GraftMetrics.spaceXS) {
                    shortcut("Today", 0)
                    shortcut("Tomorrow", 1)
                    shortcut("In a week", 7)
                }

                DatePicker("", selection: pickerBinding, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .tint(Color.gAccent)
                    .labelsHidden()
                    .accessibilityLabel(label)
            }
        }
        .animation(.snappy(duration: 0.18), value: isPicking)
    }

    private func shortcut(_ title: String, _ offset: Int) -> some View {
        let target = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let day = GraftDate.dayString(from: target)
        let isOn = value == day
        return Button {
            value = day
        } label: {
            Text(title)
                .font(GraftFont.text(GraftType.secondary, isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.gOnAccent : Color.gInk2)
                .padding(.horizontal, GraftMetrics.spaceS)
                .frame(height: GraftMetrics.controlSmall)
                .background(isOn ? Color.gAccent : Color.gSurface2, in: Capsule())
                .overlay(
                    Capsule().stroke(isOn ? .clear : Color.gHairline,
                                     lineWidth: GraftMetrics.border)
                )
                .contentShape(Rectangle())
                .frame(minHeight: GraftMetrics.tap)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Recurrence editor

/// Frequency, interval, weekdays and the anchor.
///
/// It only ever emits rules the server accepts. That is not politeness: an
/// unsupported part comes back as a 400 rather than being ignored — on purpose,
/// so "every weekday" never quietly becomes "every day" — and a 400 from inside
/// the offline queue is an edit the user is told was discarded. See the note at
/// the top of `Recurrence`.
///
/// The draft is held here rather than derived from the binding on every redraw,
/// mirroring the web client's `_recurState`. Weekday choices have to survive a
/// trip through a frequency that cannot carry them: pick Mon/Wed, glance at
/// Monthly, come back to Weekly, and the days must still be there — but the
/// rule string in between cannot legally hold them.
struct RecurrenceEditor: View {
    /// The RRULE. `""` for "does not repeat".
    @Binding var rule: String
    /// `schedule` or `completion`.
    @Binding var anchor: String

    @State private var draft = Recurrence()
    /// True once the user has actually changed something here.
    ///
    /// The draft used to be seeded once, in this view's own `onAppear`, behind a
    /// `loaded` guard — and a child's `onAppear` runs before its parent's, while
    /// the issue screen only fills `recurrence` in *its* `onAppear`. So the
    /// editor seeded itself from `""`, an issue that repeats every Monday showed
    /// "Never", and one tap on a frequency wrote a rule with the BYDAY, COUNT
    /// and UNTIL thrown away. Until the user touches it, the draft simply
    /// follows the bound rule wherever it goes; after that it is the truth and
    /// the rule follows it.
    @State private var touched = false

    private var anchorChoice: RecurrenceAnchor {
        RecurrenceAnchor(rawValue: anchor) ?? .schedule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceM) {
            frequencyRow

            if draft.repeats {
                intervalRow
                if draft.freq == .weekly { weekdayRow }
                anchorRow
                summary
            }
        }
        .onAppear { followRule() }
        .onChange(of: rule) { _, _ in followRule() }
        .onChange(of: draft) { _, new in
            // One direction of travel: the draft is the truth, and the rule
            // string is what it looks like on the wire.
            //
            // Compared against the *parsed* stored rule, not against the string.
            // Seeding the draft is a change too, and so is canonicalisation —
            // `FREQ=WEEKLY;BYDAY=WE,MO` comes back as `BYDAY=MO,WE`, which is
            // the same rule spelled tidily. Writing on either would mark the
            // issue dirty and fire a save the moment the screen opened, for an
            // edit nobody made. It is also what tells a seeding apart from a
            // tap, which is why `touched` is set here and nowhere else.
            guard new != Recurrence(rule: rule) else { return }
            touched = true
            rule = new.rule
        }
    }

    /// Re-seed the draft from the bound rule, while the user has not yet edited
    /// it. Called on appear *and* on every change to the rule, because the issue
    /// screen fills its `recurrence` state after this view has already appeared,
    /// and a rule that arrives a moment late is still this issue's rule.
    private func followRule() {
        guard !touched else { return }
        let parsed = Recurrence(rule: rule)
        // Guarded rather than assigned blindly: an equal assignment would be
        // harmless, but writing @State on every change to the bound rule is a
        // view invalidation for nothing.
        guard parsed != draft else { return }
        draft = parsed
    }

    // MARK: Frequency

    private var frequencyRow: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            Text("REPEATS")
                .font(GraftFont.text(GraftType.micro, .semibold))
                .foregroundStyle(Color.gInk3)
                .tracking(GraftType.microTracking)

            FlowRow(spacing: GraftMetrics.spaceXS) {
                chip("Never", isOn: !draft.repeats) { draft.freq = nil }
                ForEach(RecurrenceFreq.allCases, id: \.self) { freq in
                    chip(freq.label, isOn: draft.freq == freq) { draft.freq = freq }
                }
            }
            .animation(.snappy(duration: 0.18), value: draft.freq)
        }
    }

    // MARK: Interval

    private var intervalRow: some View {
        HStack(spacing: GraftMetrics.spaceXS) {
            Text("EVERY")
                .font(GraftFont.text(GraftType.micro, .semibold))
                .foregroundStyle(Color.gInk3)
                .tracking(GraftType.microTracking)
            Spacer(minLength: 0)
            stepButton("minus", enabled: draft.interval > 1) {
                draft.interval = max(1, draft.interval - 1)
            }
            Text(unitText)
                .font(GraftFont.text(GraftType.body, .medium))
                .foregroundStyle(Color.gInk)
                .monospacedDigit()
                .frame(minWidth: 96)
                .multilineTextAlignment(.center)
            // No hard cap beyond the obvious: the server takes any interval
            // ≥ 1, and someone's "every 18 months" is not ours to refuse.
            stepButton("plus", enabled: draft.interval < 99) {
                draft.interval = min(99, draft.interval + 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Every \(unitText)")
    }

    private var unitText: String {
        guard let freq = draft.freq else { return "" }
        let unit = draft.interval == 1 ? freq.unit.one : freq.unit.many
        return draft.interval == 1 ? unit : "\(draft.interval) \(unit)"
    }

    // MARK: Weekdays

    private var weekdayRow: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack(spacing: GraftMetrics.spaceXS) {
                Text("ON")
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .foregroundStyle(Color.gInk3)
                    .tracking(GraftType.microTracking)
                Spacer(minLength: 0)
                if !draft.byday.isEmpty {
                    Button("Clear") { draft.byday = [] }
                        .font(GraftFont.text(GraftType.micro, .semibold))
                        .foregroundStyle(Color.gAccentText)
                        .buttonStyle(.plain)
                }
            }

            // Monday first, and not configurable: the server fixes WKST=MO and
            // documents it, so a week starting anywhere else would be a picker
            // lying about what it is going to do.
            FlowRow(spacing: GraftMetrics.spaceXS) {
                ForEach(RecurrenceDay.allCases, id: \.self) { day in
                    chip(day.short, isOn: draft.byday.contains(day)) {
                        if let idx = draft.byday.firstIndex(of: day) {
                            draft.byday.remove(at: idx)
                        } else {
                            draft.byday.append(day)
                        }
                        // Calendar order regardless of the order they were
                        // tapped in — the same tidy-up the web client does.
                        // It also keeps the draft in the one canonical form the
                        // rule string round-trips to, which is what lets the
                        // `onChange` guard above compare the two at all.
                        draft.byday = RecurrenceDay.allCases.filter { draft.byday.contains($0) }
                    }
                }
            }
            .animation(.snappy(duration: 0.18), value: draft.byday)

            if draft.byday.isEmpty {
                Text("No days chosen — it repeats on whatever day it is already on.")
                    .font(GraftFont.text(GraftType.caption))
                    .foregroundStyle(Color.gInk3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Anchor

    /// Two rows rather than chips, because each option is a sentence. The
    /// wording is the web client's, word for word — this is the one choice in
    /// the feature that a person cannot make from the storage words
    /// ("schedule", "completion"), and the two clients must not teach it
    /// differently.
    private var anchorRow: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            Text("COUNTED FROM")
                .font(GraftFont.text(GraftType.micro, .semibold))
                .foregroundStyle(Color.gInk3)
                .tracking(GraftType.microTracking)

            VStack(spacing: 0) {
                ForEach(Array(RecurrenceAnchor.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0 { GraftRowDivider() }
                    anchorOption(option)
                }
            }
        }
    }

    private func anchorOption(_ option: RecurrenceAnchor) -> some View {
        let isOn = anchorChoice == option
        return Button {
            anchor = option.rawValue
        } label: {
            HStack(alignment: .top, spacing: GraftMetrics.spaceS) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isOn ? Color.gAccent : Color.gLine2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(GraftFont.text(GraftType.body, isOn ? .semibold : .regular))
                        .foregroundStyle(Color.gInk)
                    Text(option.detail)
                        .font(GraftFont.text(GraftType.caption))
                        .foregroundStyle(Color.gInk2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: GraftMetrics.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.optionText)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: Summary

    /// The rule said back, anchor included, so the two options are told apart
    /// by what they do rather than by the words on their labels.
    private var summary: some View {
        Text(draft.summary(anchor: anchorChoice))
            .font(GraftFont.text(GraftType.caption))
            .foregroundStyle(Color.gInk2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(GraftMetrics.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gSurface2, in: RoundedRectangle(cornerRadius: GraftMetrics.radiusSmall))
    }

    // MARK: Bits

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(GraftFont.text(GraftType.secondary, isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.gOnAccent : Color.gInk2)
                .padding(.horizontal, GraftMetrics.spaceS)
                .frame(height: GraftMetrics.controlSmall)
                .background(isOn ? Color.gAccent : Color.gSurface2, in: Capsule())
                .overlay(
                    Capsule().stroke(isOn ? .clear : Color.gHairline,
                                     lineWidth: GraftMetrics.border)
                )
                .contentShape(Rectangle())
                .frame(minHeight: GraftMetrics.tap)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.gInk : Color.gInk3)
                .frame(width: GraftMetrics.controlSmall, height: GraftMetrics.controlSmall)
                .background(Color.gSurface2, in: Circle())
                .overlay(Circle().stroke(Color.gHairline, lineWidth: GraftMetrics.border))
                .frame(minWidth: GraftMetrics.tap, minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }
}

// MARK: - Quick due date

/// A one-line due date for the moment of capture.
///
/// `GraftDateRow` is the full control and stays where the whole schedule is
/// edited. The problem it could not solve is that every way into a new issue —
/// the + button, and "Add issue" at the foot of a board column — lands on a
/// form where the date is the fifth section down: by the time you have scrolled
/// to it you have stopped capturing and started filing. These are the three
/// answers that cover nearly every case, one tap each, at the top of the sheet.
///
/// Anything else opens the same inline picker `GraftDateRow` uses, and whatever
/// it sets shows up in the Schedule section below, because both are bound to
/// the same string.
struct GraftQuickDateRow: View {
    /// `""` for no date.
    @Binding var value: String

    @State private var isPicking = false

    private var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }

    private func day(offsetBy days: Int) -> String {
        guard let date = calendar.date(byAdding: .day, value: days, to: today) else { return "" }
        return GraftDate.dayString(from: date)
    }

    private var pickerBinding: Binding<Date> {
        Binding(
            get: { GraftDate.day(from: value) ?? today },
            set: { value = GraftDate.dayString(from: $0) }
        )
    }

    /// The date is "other" when it is set but is none of the three presets —
    /// that is what lights the calendar chip instead.
    private var isCustom: Bool {
        !value.isEmpty && ![0, 1, 7].contains { day(offsetBy: $0) == value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: GraftMetrics.spaceXS) {
            HStack(spacing: GraftMetrics.spaceXS) {
                Text("DUE")
                    .font(GraftFont.text(GraftType.micro, .semibold))
                    .foregroundStyle(Color.gInk3)
                    .tracking(GraftType.microTracking)

                if !value.isEmpty {
                    Text(GraftDate.mediumDate(value) ?? value)
                        .font(GraftFont.text(GraftType.caption, .medium))
                        .foregroundStyle(Color.gInk2)
                }

                Spacer(minLength: 0)

                if !value.isEmpty {
                    Button {
                        value = ""
                        isPicking = false
                    } label: {
                        Text("Clear")
                            .font(GraftFont.text(GraftType.micro, .semibold))
                            .foregroundStyle(Color.gInk3)
                            .frame(minHeight: GraftMetrics.tap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear due date")
                }
            }

            FlowRow(spacing: GraftMetrics.spaceXS) {
                chip("Today", days: 0)
                chip("Tomorrow", days: 1)
                chip("Next week", days: 7)

                Button {
                    isPicking.toggle()
                } label: {
                    HStack(spacing: GraftMetrics.spaceXXS) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .medium))
                        Text(isCustom ? (GraftDate.shortDate(value) ?? "Date") : "Pick a date")
                            .font(GraftFont.text(GraftType.caption, .medium))
                    }
                    .foregroundStyle(isCustom ? Color.gOnAccent : Color.gInk2)
                    .padding(.horizontal, GraftMetrics.spaceS)
                    .frame(minHeight: GraftMetrics.controlSmall)
                    .background(isCustom ? Color.gAccent : Color.gSurface2, in: Capsule())
                    .frame(minHeight: GraftMetrics.tap)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pick a due date")
            }

            if isPicking {
                DatePicker("Due", selection: pickerBinding, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Color.gAccent)
                    .labelsHidden()
            }
        }
    }

    private func chip(_ title: String, days: Int) -> some View {
        let target = day(offsetBy: days)
        let selected = value == target
        return Button {
            // Tapping the chip that is already on clears the date, so the whole
            // control is reversible without hunting for Clear.
            value = selected ? "" : target
            isPicking = false
        } label: {
            Text(title)
                .font(GraftFont.text(GraftType.caption, .medium))
                .foregroundStyle(selected ? Color.gOnAccent : Color.gInk2)
                .padding(.horizontal, GraftMetrics.spaceS)
                .frame(minHeight: GraftMetrics.controlSmall)
                .background(selected ? Color.gAccent : Color.gSurface2, in: Capsule())
                .frame(minHeight: GraftMetrics.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Due \(title.lowercased())")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
