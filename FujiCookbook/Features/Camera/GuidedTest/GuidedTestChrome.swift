import SwiftUI

/// The pieces every step of the guided Camera Test is built from.
///
/// One layout, so a tester learns the shape once: what this step is, why it matters, and one obvious
/// thing to tap. The flow asks people to do fiddly things with hardware in the right order, and a
/// screen that looks different each time is a screen that gets skimmed.
struct GuidedStepLayout<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(Theme.serif(26))
                            .foregroundStyle(Theme.ink)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    content
                }
                .padding(18)
            }
            VStack(spacing: 10) { actions }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(Theme.paper)
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A titled card with an explanation under it — the flow's way of saying one thing at a time.
struct GuidedNoticeCard: View {
    let title: String
    var systemImage: String?
    var tint: Color = Theme.accent
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let systemImage {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .labelStyle(TintedLabelStyle(tint: tint))
            } else {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }
}

/// Keeps a notice's icon tinted while its title stays ink — colour carries the severity, and the
/// text never has to.
private struct TintedLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// The step's one obvious thing to tap.
struct GuidedPrimaryButton: View {
    let title: String
    var systemImage: String?
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(Theme.onAccent) }
                if let systemImage, !busy { Image(systemName: systemImage) }
                Text(title).font(.headline)
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .opacity(enabled && !busy ? 1 : 0.45)
    }
}

/// Everything that isn't the main action: skipping, going back, saying no.
struct GuidedSecondaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// yes / no / didn't check.
///
/// "Didn't check" is a first-class answer and sits beside the other two rather than being the
/// absence of an answer. A tester who guesses is worse than one who says they didn't look, and a
/// question with only two buttons makes guessing the way out.
struct GuidedAnswerPicker: View {
    let question: String
    var yesLabel = "Yes"
    var noLabel = "No"
    @Binding var answer: GuidedTestSession.Answer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            GuidedChoiceRow(choices: [.init(value: .yes, label: yesLabel),
                                      .init(value: .no, label: noLabel),
                                      .init(value: .notChecked, label: "Didn't check")],
                            selection: $answer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }
}

/// A row of mutually exclusive chips; the selected one is the answer.
///
/// Nothing is pre-selected, so an unanswered question stays visibly unanswered rather than
/// defaulting to whichever chip came first.
struct GuidedChoiceRow<Value: Hashable>: View {
    struct Choice: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    let choices: [Choice]
    @Binding var selection: Value?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(choices) { choice in
                chip(choice.value, choice.label)
            }
        }
    }

    private func chip(_ value: Value, _ label: String) -> some View {
        Button { selection = value } label: {
            Text(label)
                .font(.footnote.weight(selection == value ? .semibold : .medium))
                .foregroundStyle(selection == value ? Theme.onAccent : Theme.ink2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selection == value ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.paper2),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

/// A short free-text answer, for the things only a person can describe.
struct GuidedTextField: View {
    let label: String
    var placeholder = ""
    var axis: Axis = .horizontal
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink2)
            TextField(placeholder, text: $text, axis: axis)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.paper2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// What to do when the camera isn't ready for the step in front of it.
///
/// Sits above the step's own content rather than replacing it, so a tester can still read what they
/// were about to do. The write pass makes this routine rather than exceptional: its power-cycle step
/// asks them to break the connection on purpose.
struct CameraGateCard: View {
    let gate: GuidedTestRunner.CameraGate
    let isDemo: Bool
    /// Set on the steps that ask the tester to *use* the camera — read its IQ menu, take a photo.
    /// A camera in `USB RAW Conv./Backup Restore` has given its display to the host, so those steps
    /// can only be done with the cable out, and reporting that as a fault tells the tester they
    /// broke something by following the instructions.
    var unplugExpected = false
    var onReconnect: () -> Void
    var onHelp: () -> Void

    var body: some View {
        switch gate {
        case .ready:
            EmptyView()
        case .busy(let message):
            waiting(message)
        case .reconnecting:
            // An expected removal is being waited out, not recovered from, and the connector waits
            // far longer for it — so the generic spinner would sit there for a minute implying
            // something had gone wrong.
            waiting(unplugExpected ? "Follow the steps below, then reconnect the camera."
                                   : "Reconnecting to the camera…")
        case .lost(let message):
            if unplugExpected {
                unpluggedCard
            } else {
                reconnectCard(title: "The camera disconnected", message: message)
            }
        case .disconnected:
            if unplugExpected {
                unpluggedCard
            } else {
                reconnectCard(title: "No camera connected",
                              message: "Reconnect with a USB data cable. Set the camera to USB RAW Conv./Backup Restore.")
            }
        }
    }

    /// Deliberately quiet: no warning tint, no Reconnect button competing with the step's own
    /// action. Being unplugged here is the tester doing it right.
    private var unpluggedCard: some View {
        Label("The camera is unplugged for this check. Your answers are saved.",
              systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .themedCard(cornerRadius: 16)
    }

    private func waiting(_ message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    private func reconnectCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "cable.connector.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your answers are saved as you go.")
                .font(.caption)
                .foregroundStyle(Theme.ink3)
            HStack(spacing: 12) {
                Button(action: onReconnect) {
                    Text(isDemo ? "Reconnect Demo Camera" : "Reconnect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                Button(action: onHelp) {
                    Text("Help")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 11)
                        .padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }
}

/// "1 setting differs" / "3 settings differ" — the verb has to agree as well as the noun.
func guidedSettingsDiffer(_ count: Int) -> String {
    count == 1 ? "1 setting differs" : "\(count) settings differ"
}

/// Camera menu wording is setup guidance, never an input to USB identification.
enum CameraTestSetup {
    /// The same for every body; Connection Help gives the reason for each setting.
    static let usbInstructions = "On the camera, select Network/USB Setting > Connection Mode > USB RAW CONV./BACKUP RESTORE. On older models, this setting is at Connection Settings > USB Mode. Then select Network/USB Setting > USB Power Supply/Comm Setting > POWER SUPPLY OFF/COMM ON."
}

extension GuidedTestSession.OptionalCheck {
    var title: String {
        switch self {
        case .secondSlotComparison: return "Compare a second existing slot"
        case .colour: return "Write CT Colour"
        case .mono: return "Write CT Mono"
        case .kelvin: return "Write CT Kelvin"
        case .extraRestarts: return "Restart after additional recipes"
        case .testKitchen: return "Compare two recipes in Test Kitchen"
        case .expandedKitchen: return "Test Kitchen with more RAW files"
        case .cameraReference: return "Compare with the camera's JPEG"
        case .dynamicRange: return "Develop at DR100, DR200, DR400 and Auto"
        }
    }
    var purpose: String {
        switch self {
        case .secondSlotComparison: return "Check another stored recipe against the camera menu."
        case .colour: return "Check Dynamic Range and highlight/shadow tones, which CT Priority leaves to the camera, plus colour, white balance and grain."
        case .mono: return "Check monochrome toning and grain."
        case .kelvin: return "Check Kelvin white balance, DR Auto and grain Off."
        case .extraRestarts: return "Restart after each extra recipe to check that its settings stay saved."
        case .testKitchen: return "Develop the same RAW file with two test recipes and compare the images."
        case .expandedKitchen: return "Try the test recipes on more RAW files."
        case .cameraReference: return "Use the same RAW file and settings to make a JPEG on the camera, then compare the two images."
        case .dynamicRange: return "Make four JPEGs with different Dynamic Range settings. The RAW file may limit which settings the camera can use."
        }
    }
}

struct GuidedPlanChoices: View {
    @Binding var session: GuidedTestSession
    var body: some View {
        DisclosureGroup("Additional checks") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(GuidedTestSession.OptionalCheck.allCases) { check in
                    Toggle(isOn: Binding(get: { session.plan?.optionalChecks.contains(check) == true },
                                         set: { included in
                        var plan = session.plan ?? .init()
                        if included { plan.optionalChecks.insert(check) }
                        else { plan.optionalChecks.remove(check) }
                        session.plan = plan
                        session.touch()
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).font(.subheadline)
                            Text(check.purpose).font(.caption).foregroundStyle(Theme.ink2)
                        }
                    }
                }
            }.padding(.top, 10)
        }
        .padding(14).themedCard(cornerRadius: 16)
    }
}

/// Completion and evidence are distinct: recording an observation completes the activity without
/// turning it into an automatic verification. Optional checks outside this run remain neutral.
enum CameraTestSummary {
    enum Status: String {
        case passed = "Passed"
        case recorded = "Recorded"
        case observed = "Observed"
        case issueFound = "Issue found"
        case commandWarning = "Restore warning"
        case needsAttention = "Needs attention"
        case couldNotVerify = "Could not verify"
        case notChecked = "Not checked"
        case incomplete = "Incomplete"
        case notTested = "Not tested"
        case unavailable = "Unavailable"
        case skipped = "Skipped"
        case keptByChoice = "Kept by choice"
        case notIncluded = "Not included"

        var isCompleted: Bool {
            [.passed, .recorded, .observed, .keptByChoice].contains(self)
        }
        var icon: String {
            switch self {
            case .passed: return "checkmark.circle.fill"
            case .recorded, .observed, .keptByChoice: return "checkmark.circle"
            case .issueFound, .commandWarning, .needsAttention: return "exclamationmark.circle"
            case .couldNotVerify: return "questionmark.circle"
            case .notIncluded: return "minus"
            case .skipped, .unavailable: return "minus.circle"
            case .notChecked, .incomplete, .notTested: return "circle"
            }
        }
        var tint: Color {
            switch self {
            case .passed: return Theme.accent
            case .issueFound, .commandWarning, .needsAttention, .couldNotVerify: return Theme.warning
            case .recorded, .observed, .keptByChoice: return Theme.ink2
            default: return Theme.ink3
            }
        }
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let status: Status
        let detail: String
        var state: String { status.rawValue }
        var line: String { "\(title): \(state)\(detail.isEmpty ? "" : " — \(detail)")" }
        var icon: String { status.icon }
        var isIncluded: Bool { status != .notIncluded }
    }

    static func rows(_ session: GuidedTestSession) -> [Row] {
        var rows: [Row] = []
        func add(_ id: String, _ title: String, _ status: Status, _ detail: String = "") {
            rows.append(.init(id: id, title: title, status: status, detail: detail))
        }
        let selected = session.plan?.optionalChecks ?? []
        add("identity", "Camera model", session.identity?.confirmed == true ? .passed : session.identity?.confirmed == false ? .issueFound : .notChecked,
            session.identifiedModelID ?? session.cameraProductName ?? "No camera identified")
        let probe = session.propertyReport
        add("read", "Read camera settings", probeStatus(probe),
            probe?.state == .ran ? probe?.count.map { "\($0) camera values read." } ?? "Camera information saved."
                : probe?.detail ?? "")
        let checked = session.slotComparisons.filter { $0.checkedAt != nil }
        let requested = selected.contains(.secondSlotComparison) ? 2 : 1
        let differences = checked.filter { $0.verdict == "differs" }
        let matchingCount = checked.filter { $0.verdict == "matches" }.count
        let noOccupiedSlots = session.plan != nil && session.propertyReport?.state == .ran
            && session.slotComparisons.isEmpty && session.completedSteps.contains(.readSlots)
        let comparisonStatus: Status = !differences.isEmpty ? .issueFound
            : checked.contains(where: { $0.verdict == "unverified" }) ? .couldNotVerify
            : noOccupiedSlots ? .unavailable
            : matchingCount >= requested ? .passed
            : checked.isEmpty ? .notChecked : .incomplete
        add("compare", "Compare saved recipes", comparisonStatus,
            "\(checked.count) checked; \(requested) planned\(noOccupiedSlots ? "; no saved recipes to compare" : "")")
        let grain = session.grainProbe
        add("grain", "Grain check", probeStatus(grain),
            grain?.state == .ran ? grain?.count.map { "\($0) grain checks recorded." } ?? "Grain check results saved."
                : grain?.detail ?? "")
        let trials = session.writePass?.trials ?? []
        if trials.isEmpty { add("writes", "Write a recipe to a camera slot", .notChecked) }
        for (index, trial) in trials.enumerated() {
            let prefix = "trial-\(index)"
            let includesFollowUp = index == session.writePass?.restartCheckTrial || selected.contains(.extraRestarts)
            add(prefix, "Write \(trial.recipeName) to C\(trial.slot)", trial.outcome == .applied ? .passed : trial.outcome == nil ? .notChecked : .issueFound,
                writeDetail(trial))
            let p = trial.persistence
            let status: Status
            switch p?.evidenceState {
            case .passed?: status = .passed
            case .issueFound?: status = .issueFound
            case .couldNotVerify?: status = .couldNotVerify
            default: status = .notChecked
            }
            add(prefix + "-restart", "\(trial.recipeName) after restart",
                includesFollowUp || p != nil ? status : .notIncluded,
                includesFollowUp || p != nil ? persistenceDetail(p) : "")
            let menuObserved = trial.menuComparison?.checkedAt != nil
                || trial.menuComparison?.rows.contains(where: \.differs) == true
            add(prefix + "-menu", "\(trial.recipeName) camera menu",
                !includesFollowUp && !menuObserved ? .notIncluded
                    : trial.menuComparison?.verdict == "matches" ? .passed : trial.menuComparison?.verdict == "differs" ? .issueFound : trial.menuComparison?.verdict == "unverified" ? .couldNotVerify : .notChecked)
            let photoObserved = trial.photoMatchesRecipe != nil || trial.photoNote != nil
            add(prefix + "-photo", "\(trial.recipeName) photo",
                includesFollowUp || photoObserved ? observationStatus(trial.photoMatchesRecipe) : .notIncluded,
                includesFollowUp || photoObserved ? trial.photoNote ?? observationDetail(trial.photoMatchesRecipe) : "")
        }
        for option in [GuidedTestSession.OptionalCheck.colour, .mono, .kelvin]
            where selected.contains(option) && !trials.contains(where: { $0.recipe == option.rawValue }) {
            add("extra-" + option.rawValue, optionalTitle(option), .notTested, "You selected this check, but no write result was saved.")
        }
        if selected.contains(.extraRestarts),
           !(session.writePass?.extraTrials ?? []).contains(where: { $0.persistence != nil }) {
            add("extra-restarts", optionalTitle(.extraRestarts), .notTested, "The extra recipes have no saved restart check.")
        }
        let runs = session.kitchenRuns ?? []
        let completions = session.kitchenCompletions ?? []
        if !runs.contains(where: { $0.caseID == "develop" }) { add("develop", "Develop a RAW file", .notTested, session.develop?.detail ?? "") }
        for run in runs {
            let completion = completions.first { $0.run.id == run.id }
            let kitchenStatus: Status
            if let completion {
                if completion.hasFailures || completion.saveFailed
                    || completion.cells.contains(where: { $0.profileVerified == false || !$0.warnings.isEmpty }) {
                    kitchenStatus = .issueFound
                } else if !completion.hasSuccessfulOutput
                    || completion.cells.contains(where: { $0.succeeded && $0.profileVerified == nil }) {
                    kitchenStatus = .couldNotVerify
                } else {
                    kitchenStatus = .passed
                }
            } else { kitchenStatus = .couldNotVerify }
            add(run.id.uuidString, kitchenTitle(run), kitchenStatus,
                completion.map(kitchenDetail) ?? "No result was saved for this attempt. It may have been interrupted.")
            if completion?.hasSuccessfulOutput == true {
                let observation = session.kitchenObservations?[run.id.uuidString]
                add(run.id.uuidString + "-look", "Developed image", observationStatus(observation), observationDetail(observation))
            }
        }
        for option in [GuidedTestSession.OptionalCheck.testKitchen, .expandedKitchen]
            where selected.contains(option) && !runs.contains(where: { $0.caseID == option.rawValue }) {
            add(option.rawValue, optionalTitle(option), .notTested, "You selected this check, but no Develop result was saved.")
        }
        if selected.contains(.dynamicRange) {
            for (id, title) in dynamicRangeCases where !runs.contains(where: { $0.caseID == id }) {
                add(id, title, .notTested, "You selected this check, but no Develop result was saved.")
            }
        }
        let reference = session.kitchenObservations?.filter { $0.key.hasPrefix("reference:") }.map(\.value) ?? []
        if selected.contains(.cameraReference) || !reference.isEmpty {
            let answer: GuidedTestSession.Answer? = reference.contains(.no) ? .no : reference.contains(.yes) ? .yes : nil
            add("reference", "Comparison with the camera’s JPEG", observationStatus(answer), observationDetail(answer))
        }
        let recovery = GuidedRecoveryStore.load(sessionID: session.id)
        let restores = session.writePass?.restores ?? []
        let restorationSlots = Set(recovery?.touchedSlots ?? []).union(restores.map(\.slot)).sorted()
        if !restorationSlots.isEmpty {
            for slot in restorationSlots {
                let restore = restores.last { $0.slot == slot }
                let disposition = recovery?.dispositions[String(slot)] ?? restore?.outcome ?? .pending
                let latestWrite = trials.filter { $0.slot == slot }.compactMap(\.pushedAt).max()
                let verification: RestoreVerification? = restore?.verification.flatMap { evidence in
                    latestWrite.map { $0 > evidence.at } == true || disposition == .pending ? nil : evidence
                }
                rows.append(contentsOf: restoreRows(slot: slot, disposition: disposition, verification: verification))
            }
        } else if !trials.isEmpty {
            add("restore", "Original settings recovery", .couldNotVerify, "The original settings backup is unavailable.")
        }
        // Attempted optional work is always visible above, even if its toggle was later cleared.
        for option in GuidedTestSession.OptionalCheck.allCases
            where !selected.contains(option) && !attempted(option, in: session) {
            add("optional-" + option.rawValue, optionalTitle(option), .notIncluded)
        }
        return rows
    }

    static let dynamicRangeCases = [("dr-100", "Develop at DR100"), ("dr-200", "Develop at DR200"),
                                   ("dr-400", "Develop at DR400"), ("dr-auto", "Develop at DR Auto")]

    private static func kitchenTitle(_ run: GuidedKitchenRun) -> String {
        let names = run.recipes.map(\.name).joined(separator: " and ")
        switch run.caseID {
        case "develop": return names.isEmpty ? "Develop a RAW file" : "Develop with " + names
        case "testKitchen": return "Test Kitchen comparison" + (names.isEmpty ? "" : " · " + names)
        case "expandedKitchen": return "Test Kitchen RAW batch" + (names.isEmpty ? "" : " · " + names)
        default: return dynamicRangeCases.first { $0.0 == run.caseID }?.1 ?? "RAW conversion"
        }
    }

    private static func optionalTitle(_ option: GuidedTestSession.OptionalCheck) -> String {
        switch option {
        case .colour: return "Write CT Colour to a camera slot"
        case .mono: return "Write CT Mono to a camera slot"
        case .kelvin: return "Write CT Kelvin to a camera slot"
        default: return option.title
        }
    }

    private static func attempted(_ option: GuidedTestSession.OptionalCheck, in session: GuidedTestSession) -> Bool {
        let trials = session.writePass?.trials ?? []
        let runs = session.kitchenRuns ?? []
        switch option {
        case .secondSlotComparison: return session.slotComparisons.filter { $0.checkedAt != nil }.count > 1
        case .colour, .mono, .kelvin: return trials.contains { $0.recipe == option.rawValue }
        case .extraRestarts: return (session.writePass?.extraTrials ?? []).contains { $0.persistence != nil }
        case .testKitchen, .expandedKitchen: return runs.contains { $0.caseID == option.rawValue }
        case .dynamicRange: return runs.contains { $0.caseID.hasPrefix("dr-") }
        case .cameraReference: return session.kitchenObservations?.keys.contains { $0.hasPrefix("reference:") } == true
        }
    }

    private static func probeStatus(_ probe: GuidedTestSession.ProbeOutcome?) -> Status {
        switch probe?.state {
        case .ran?: return .recorded
        case .failed?: return .issueFound
        case .refused?: return .couldNotVerify
        case .skipped?: return .skipped
        case .notWritable?: return .unavailable
        default: return .notChecked
        }
    }

    private static func observationStatus(_ answer: GuidedTestSession.Answer?) -> Status {
        answer == .yes ? .observed : answer == .no ? .issueFound : .notChecked
    }

    private static func observationDetail(_ answer: GuidedTestSession.Answer?) -> String {
        answer == .yes ? "You reported that the image looked right."
            : answer == .no ? "You reported that the image did not look right."
            : "No image check was saved."
    }

    private static func writeDetail(_ trial: GuidedTestSession.PushTrial) -> String {
        if let reason = trial.refusalReason { return reason }
        switch trial.outcome {
        case .applied: return "The requested recipe settings were written and read back."
        case .partiallyApplied: return "Some settings were not accepted. The report includes each setting's result."
        case .notWritten, .unknown: return "Check the write result in the report."
        case nil: return "No write result was recorded."
        }
    }

    private static func persistenceDetail(_ persistence: GuidedTestSession.Persistence?) -> String {
        guard let persistence else { return "No restart check was recorded for this recipe." }
        if persistence.evidenceState == .passed {
            var details: [String] = []
            if persistence.restartConfirmed == true { details.append("Restart confirmed.") }
            if persistence.settingsState == .passed { details.append("The written settings were still saved.") }
            if persistence.nameState == .passed { details.append("The recipe name was still saved.") }
            return details.isEmpty ? "The restart check was recorded." : details.joined(separator: " ")
        }
        if persistence.evidenceState == .issueFound { return "The camera's settings or saved name did not match after restarting." }
        return "The app could not confirm the restart or read the settings afterward."
    }

    private static func kitchenDetail(_ completion: GuidedKitchenCompletion) -> String {
        var parts = ["\(completion.cells.filter(\.succeeded).count) of \(completion.cells.count) images produced."]
        if completion.saveFailed { parts.append("The images could not be saved on this device.") }
        if completion.cells.contains(where: { $0.profileVerified == false }) {
            parts.append("The camera did not confirm the recipe settings; the result may differ from the recipe.")
        } else if completion.cells.contains(where: { $0.succeeded && $0.profileVerified == nil }) {
            parts.append("The image was produced, but the app could not confirm its recipe settings.")
        }
        for cell in completion.cells {
            if !cell.succeeded { parts.append(conversionFailure(cell.failureReason)) }
            parts.append(contentsOf: cell.warnings)
            parts.append(contentsOf: cell.notes)
            if !cell.clampedFields.isEmpty { parts.append("Adjusted settings: " + cell.clampedFields.joined(separator: ", ") + ".") }
        }
        var seen = Set<String>()
        return parts.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " ")
    }

    private static func conversionFailure(_ reason: String?) -> String {
        switch reason {
        case "file_unreadable": return "The selected RAW file could not be opened."
        case "not_a_raf": return "The selected file isn't a Fujifilm RAW file. Use a .RAF file captured by this camera."
        case "raf_from_different_body": return "The camera rejected the RAW file. Use a file captured by this same camera."
        case "conversion_profile_mismatch", "profile_empty": return "The app couldn't read the camera's RAW conversion settings."
        case "raw_conversion_unsupported": return "RAW conversion was unavailable for the connected camera."
        case "no_output_produced": return "The camera returned no JPEG."
        case "conversion_timed_out", "timeout": return "The camera took too long to return a JPEG."
        case "no_device", "disconnected_during_operation": return "The camera disconnected before conversion finished."
        default: return "Develop did not finish. Details are in the report."
        }
    }

    private static func restoreDetail(_ disposition: RestoreDisposition) -> String {
        if disposition == .restored { return "The original slot settings were restored." }
        if disposition.isKeptByChoice { return "You chose to keep the test recipe in this slot." }
        return "The slot's final state still needs to be checked."
    }

    static func restoreRows(slot: Int, disposition: RestoreDisposition, verification: RestoreVerification?) -> [Row] {
        let status: Status
        let detail: String
        if disposition.isKeptByChoice {
            status = .keptByChoice
            detail = restoreDetail(disposition)
        } else if let verification {
            switch verification.outcome {
            case .applied:
                status = .passed
                detail = verification.originalNameRestorable
                    ? "The original settings and recipe name are back."
                    : "The original settings are back. The original name could not be checked."
            case .couldNotVerify:
                status = .couldNotVerify
                detail = "The app could not check the restored settings. Reconnect and check the slot."
            case .partiallyApplied, .notWritten:
                status = .needsAttention
                detail = verification.reasons.joined(separator: " ")
            }
        } else {
            status = disposition == .restored ? .passed : .needsAttention
            detail = restoreDetail(disposition)
        }
        var rows = [Row(id: "restore-\(slot)", title: "C\(slot) final state", status: status, detail: detail)]
        if let verification, verification.commandOutcome != .applied {
            let detail = verification.reasons.isEmpty
                ? "The camera refused part of the restore. See the final slot check above."
                : verification.reasons.joined(separator: " ")
            rows.append(.init(id: "restore-\(slot)-command", title: "C\(slot) restore attempt",
                              status: .commandWarning, detail: detail))
        }
        return rows
    }

    static func lines(_ session: GuidedTestSession) -> [String] { rows(session).map(\.line) }
}

struct CameraTestSummaryView: View {
    let session: GuidedTestSession
    var body: some View {
        let rows = CameraTestSummary.rows(session)
        let omitted = rows.filter { !$0.isIncluded }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows.filter(\.isIncluded)) { row in
                summaryRow(row)
            }
            if !omitted.isEmpty {
                DisclosureGroup("Extra checks not selected (\(omitted.count))") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(omitted) { row in summaryRow(row) }
                    }.padding(.top, 10)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink3)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).themedCard(cornerRadius: 16)
    }

    private func summaryRow(_ row: CameraTestSummary.Row) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.icon).foregroundStyle(row.status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(row.title) · \(row.state)").font(.subheadline.weight(.medium))
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(Theme.ink2) }
            }
        }
    }
}
