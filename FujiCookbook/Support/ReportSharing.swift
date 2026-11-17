import SwiftUI
import UIKit
import MessageUI

/// A report the way it leaves the phone: one fixed body line, one attachment, and a subject that
/// is the attachment's name.
///
/// Shaped by what mail apps' share extensions actually do. Apple Mail keeps the subject an app
/// supplies and the body's line breaks; Gmail names the mail after the first file and flattens the
/// body into one paragraph. So the body is a single line that can't be flattened, the subject is the
/// file stem so both apps show the same thing, and everything worth reading is in the file.
struct ShareableReport {
    /// Which kind of file this is.
    enum Kind {
        case problem, test, feedback, backup
    }

    let kind: Kind
    let address: String
    let body: String
    let fileName: String
    let data: Data
    let mimeType: String
    /// Files that ride alongside `data`.
    ///
    /// The problem report's text is what the tester reads; the compatibility JSON is the same facts
    /// in the form `MockCameraFaults` can be driven from and two testers' reports diff against. One
    /// send rather than two, because a tester who has to perform two will perform one.
    var extraFiles: [(fileName: String, data: Data)] = []

    /// All attachments must be valid before either handoff. A partial bundle can look like a
    /// successful report while withholding the evidence the developer needs.
    func validate() throws {
        var names = Set<String>()
        for file in [(fileName, data)] + extraFiles {
            guard !file.0.isEmpty, file.0 != ".", file.0 != "..",
                  !file.0.contains("/"), !file.0.contains("\\"),
                  !file.1.isEmpty, names.insert(file.0).inserted else {
                throw ReportPreparationError.invalidAttachment
            }
        }
    }

    /// The file name without its extension: the subject Mail shows, and the name Gmail shows.
    var subject: String { (fileName as NSString).deletingPathExtension }

    static func body(for address: String) -> String {
        "To: \(address). Fuji Cookbook report attached; add what went wrong below."
    }

    /// The feedback variant. The trailing "add what went wrong below" is dropped on purpose: for
    /// feedback the note is already written, and it is in the file rather than the body precisely
    /// because Gmail flattens a multi-line body and would run the paragraphs together.
    static func feedbackBody(for address: String) -> String {
        "To: \(address). Fuji Cookbook feedback attached."
    }
}

/// The three reports the app knows how to send.
enum SupportMail {
    private static var stamp: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// "Report a Problem": the whole diagnostics text as a `.txt` — versions, settings, the camera
    /// compatibility report rendered in full when there is one, and this launch's log.
    static func problemReport(text: String, cameraReport: CameraCompatibilityReport?) -> ShareableReport {
        let subject = cameraReport.map { $0.camera.identifiedModelID ?? $0.camera.productName }?
            .replacingOccurrences(of: "FUJIFILM", with: "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-") ?? "app"
        let extras = cameraReport.map { [($0.suggestedFilename, $0.json)] } ?? []
        return ShareableReport(kind: .problem, address: SupportContact.address,
                               body: ShareableReport.body(for: SupportContact.address),
                               fileName: "fuji-cookbook-problem-report-\(subject.isEmpty ? "app" : subject)-\(stamp).txt",
                               data: Data(text.utf8), mimeType: "text/plain",
                               extraFiles: extras)
    }

    /// The Camera Test's results: the problem report's files under a `test-results` name, with a
    /// body that doesn't call them a problem, because a test is worth sending when everything worked.
    static func testResults(text: String, cameraReport: CameraCompatibilityReport?) -> ShareableReport {
        let source = problemReport(text: text, cameraReport: cameraReport)
        return ShareableReport(kind: .test, address: source.address,
                               body: "To: \(source.address). Fuji Cookbook camera test results attached.",
                               fileName: source.fileName.replacingOccurrences(of: "problem-report", with: "test-results"),
                               data: source.data, mimeType: source.mimeType, extraFiles: source.extraFiles)
    }

    /// "Send Feedback": only what the person wrote, over the four lines that say which build they
    /// wrote it on. **`extraFiles` stays empty** — no log, no camera report, no settings. That is
    /// what `SendFeedbackView`'s disclosure promises, and `FeedbackShareTests` pins it.
    static func feedback(text: String) -> ShareableReport {
        ShareableReport(kind: .feedback, address: SupportContact.address,
                        body: ShareableReport.feedbackBody(for: SupportContact.address),
                        fileName: "fuji-cookbook-feedback-\(stamp).txt",
                        data: Data(text.utf8), mimeType: "text/plain")
    }
}

/// Handoff is separate from testing progress. Even Mail's sent result is not a delivery receipt.
enum ReportShareOutcome: String, Codable, Equatable {
    case ready, canceled, saved, shared, mailSent, failed

    var message: String {
        switch self {
        case .ready: return "Report ready. Nothing has been sent."
        case .canceled: return "Sharing canceled. Your results are still available."
        case .saved: return "Draft saved in Mail. It has not been sent."
        case .shared: return "Saved or shared. Delivery to the developer is not confirmed."
        case .mailSent: return "Mail reports the message was sent. This is not a delivery receipt."
        case .failed: return "The report could not be shared. Your results are still available to retry."
        }
    }
}

enum ReportPreparationError: LocalizedError {
    case invalidAttachment, stagingFailed

    var errorDescription: String? {
        switch self {
        case .invalidAttachment:
            return "The report contains a missing or invalid attachment. Return to the test and open its report again. Nothing was shared."
        case .stagingFailed:
            return "The report attachments couldn't be prepared. Your results are still saved. Free some device storage if needed, then try again."
        }
    }
}

/// `UIActivityViewController` for SwiftUI. Completing an activity may mean saving to Files; it
/// must not be recorded as a message reaching the developer.
struct ReportShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onCompletion: ((ReportShareOutcome) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            let outcome: ReportShareOutcome = error != nil ? .failed : (completed ? .shared : .canceled)
            DispatchQueue.main.async { onCompletion?(outcome) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The user still presses Send. Recipient, subject and all attachment bytes are supplied together.
struct ReportMailComposer: UIViewControllerRepresentable {
    let report: ShareableReport
    let onCompletion: (ReportShareOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([report.address])
        controller.setSubject(report.subject)
        controller.setMessageBody(report.body, isHTML: false)
        controller.addAttachmentData(report.data, mimeType: report.mimeType, fileName: report.fileName)
        for file in report.extraFiles {
            let mimeType = file.fileName.lowercased().hasSuffix(".json") ? "application/json" : "application/octet-stream"
            controller.addAttachmentData(file.data, mimeType: mimeType, fileName: file.fileName)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onCompletion: (ReportShareOutcome) -> Void
        init(onCompletion: @escaping (ReportShareOutcome) -> Void) { self.onCompletion = onCompletion }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            let outcome: ReportShareOutcome
            if error != nil {
                outcome = .failed
            } else {
                switch result {
                case .cancelled: outcome = .canceled
                case .saved: outcome = .saved
                case .sent: outcome = .mailSent
                case .failed: outcome = .failed
                @unknown default: outcome = .failed
                }
            }
            onCompletion(outcome)
        }
    }
}

/// The body line of a shared report, carrying a subject for the mail apps that ask for one.
final class MailTextItem: NSObject, UIActivityItemSource {
    private let text: String
    private let subject: String
    init(text: String, subject: String) { self.text = text; self.subject = subject }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { text }
    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String { subject }
}

/// What the Share sheet is handed: the body line, then the file.
enum ShareBundle {
    /// A subdirectory of `tmp`, emptied before each share.
    ///
    /// Files written straight into `tmp` would leave a copy of the tester's slot recipes on disk
    /// with nothing to clean them up — iOS purges `tmp` on its own schedule, which is not a
    /// schedule. Its own folder makes "the last share's files, and only those" a guarantee.
    private static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SharedReports", isDirectory: true)
    }

    /// Remove any files staged by a previous share. Safe to call when the folder doesn't exist.
    static func clearStaging() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// Stage a camera backup for the share sheet.
    ///
    /// Through the same staging folder as a report, and for the same reason: the file holds the
    /// tester's slot recipes, and a copy of those left loose in `tmp` with nothing to clean it up is
    /// what the folder exists to prevent. Written `forSharing`, so a recovery copy from an earlier
    /// build leaves its unkeyed serial hash behind.
    static func items(forBackup backup: CameraBackup) throws -> [Any] {
        clearStaging()
        let dir = stagingDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(backup.suggestedFilename)
        try backup.forSharing.json.write(to: url, options: .atomic)
        return [url]
    }

    /// The share sheet for a backup, or the reason there isn't one: staging can fail on a full
    /// device, and an empty share sheet would say nothing about why.
    @ViewBuilder
    static func backupShareSheet(_ backup: CameraBackup) -> some View {
        switch Result(catching: { try items(forBackup: backup) }) {
        case .success(let items):
            ShareSheet(items: items)
        case .failure:
            Text("The backup file couldn't be prepared. Free some device storage, then try again.")
                .padding()
        }
    }

    /// Stage every file or fail the entire handoff. `write` is injectable to exercise a failure
    /// after the first attachment, which must not produce a silently incomplete report.
    static func items(for report: ShareableReport,
                      write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> [Any] {
        try report.validate()
        clearStaging()
        let dir = stagingDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var files: [URL] = []
            for file in [(report.fileName, report.data)] + report.extraFiles {
                let url = dir.appendingPathComponent(file.0)
                try write(file.1, url)
                files.append(url)
            }
            return [MailTextItem(text: report.body, subject: report.subject)] + files.map { $0 as Any }
        } catch {
            clearStaging()
            throw ReportPreparationError.stagingFailed
        }
    }

    struct Presented: Identifiable {
        let id = UUID()
        let kind: ShareableReport.Kind
        let items: [Any]
    }
}

/// Copies the support address, then hands a report over: to Mail, already addressed, when
/// `preferAddressedMail` is set and Mail can send; otherwise, or on request, to the share sheet.
struct ShareReportButton: View {
    let title: String
    let report: () -> ShareableReport
    var preferAddressedMail = false
    var onOutcome: ((ReportShareOutcome) -> Void)? = nil

    @State private var sharing: ShareBundle.Presented?
    @State private var mailing: Identified<ShareableReport>?
    @State private var addressCopied = false
    @State private var preparationError: String?
    @State private var outcome: ReportShareOutcome?

    private var offersMail: Bool { preferAddressedMail && MFMailComposeViewController.canSendMail() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                UIPasteboard.general.string = SupportContact.address
                addressCopied = true
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send it to").font(.caption).foregroundStyle(Theme.ink3)
                        Text(SupportContact.address).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    }
                    Spacer()
                    Label(addressCopied ? "Copied" : "Copy", systemImage: addressCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy the support address")

            Button { present(useMail: offersMail) } label: {
                Label(preferAddressedMail && !offersMail ? "Share or Save Report" : title,
                      systemImage: offersMail ? "envelope" : "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)

            if offersMail {
                Button("Share or Save Instead") { present(useMail: false) }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            if let outcome {
                Text(outcome.message).font(.caption).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let preparationError {
                Text(preparationError).font(.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $sharing) { bundle in
            ReportShareSheet(items: bundle.items) { finish($0) }
                .ignoresSafeArea()
        }
        .sheet(item: $mailing) { presentation in
            ReportMailComposer(report: presentation.value) { finish($0) }
                .ignoresSafeArea()
                .interactiveDismissDisabled()
        }
    }

    private func present(useMail: Bool) {
        preparationError = nil
        let built = report()
        do {
            try built.validate()
            if useMail {
                mailing = Identified(value: built)
            } else {
                sharing = ShareBundle.Presented(kind: built.kind, items: try ShareBundle.items(for: built))
            }
        } catch {
            preparationError = error.localizedDescription
            finish(.failed)
        }
    }

    private func finish(_ value: ReportShareOutcome) {
        sharing = nil
        mailing = nil
        outcome = value
        onOutcome?(value)
    }
}

// MARK: - Copy and Share

/// Copies `text` and says so: the label reads "Copied" until the text it copied changes. Unstyled,
/// so the container decides whether it is an outline button or an inline link.
struct CopyButton: View {
    let title: String
    let text: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .onChange(of: text) { copied = false }
    }
}

/// Copy beside Share for a text result.
///
/// Both, because these run on a phone, where the gesture that gets a result to someone else is the
/// share sheet; a finding left pasteboard-only usually stays on the device.
struct CopyShareButtons: View {
    enum Layout {
        /// Two outline buttons sharing the row, under a report.
        case fullWidth
        /// Two accent links, under a result inside a card or a list row. `.plain` keeps them
        /// separate tap targets in a row.
        case inline
    }

    var copyTitle = "Copy"
    let text: String
    var layout: Layout = .fullWidth

    var body: some View {
        switch layout {
        case .fullWidth:
            HStack(spacing: 10) { buttons }
                .buttonStyle(.outline)
        case .inline:
            HStack(spacing: 16) { buttons }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        CopyButton(title: copyTitle, text: text)
        ShareLink(item: text) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Report a Problem

/// A one-line route into **Report a Problem**: what went wrong, in the reader's words, then the way
/// out. Not gated on Diagnostic Mode anywhere it appears; a tester will not find that toggle.
///
/// With no `action` it pushes `DiagnosticsReportView` in the enclosing `NavigationStack`. Pass an
/// `action` where a push can't be used: a stack that declares `.navigationDestination(item:)` shares
/// one presentation slot with a destination-form `NavigationLink`, which then pushes the wrong
/// screen (see `KitchenView`'s `path` note), and a guided flow sends its own report.
///
/// In a `List` a push gets the system chevron; outside one, pass `chevron: true`.
struct ReportProblemRow: View {
    let prompt: String
    var actionTitle = "Report a Problem"
    var chevron = false
    var action: (() -> Void)? = nil

    /// The Kitchen's prompt. `RawConversionService` writes a failed develop's cause to `AppLog`'s
    /// `.kitchen` category, so the evidence is in the report; the row is the route to it.
    static let kitchenPrompt = "A develop failed, or the photo doesn't match the recipe?"

    var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            NavigationLink { DiagnosticsReportView() } label: { label }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text(prompt)
                .font(.caption)
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
            Text(actionTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Diagnostics

/// The raw D185 profile behind a develop, folded away: thirty-odd monospaced lines a tester can
/// open, select and copy. Callers decide when it shows; the dump stays behind Diagnostic Mode.
struct DiagnosticsDisclosure: View {
    let text: String

    var body: some View {
        DisclosureGroup("Diagnostics (D185 profile)") {
            Text(text)
                .diagnosticText()
            CopyButton(title: "Copy Diagnostics", text: text)
                .font(.footnote)
        }
        .font(.footnote)
    }
}

/// A long monospaced report as a column of pieces, each small enough to draw.
///
/// One `Text` holding a whole report goes blank once its laid-out height passes what the renderer
/// can back with a single texture: the camera-report JSON runs to several thousand lines, and a
/// text report with a long trace gets there too. A lazy column of chunks keeps every view short
/// and lays out only what is on screen. Selection works within a chunk; Copy covers the whole.
struct ReportTextColumn: View {
    let text: String

    /// Lines per `Text`. At the caption size a hundred lines is a few screens, wrapped or not —
    /// far short of the limit, and few enough views that a report scrolls smoothly.
    static let linesPerChunk = 100

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.chunks(text).enumerated()), id: \.offset) { _, chunk in
                Text(chunk)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// `text` cut every `linesPerChunk` lines; joined back with newlines it is `text` again.
    static func chunks(_ text: String, linesPerChunk: Int = linesPerChunk) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > linesPerChunk else { return [text] }
        return stride(from: 0, to: lines.count, by: linesPerChunk).map { start in
            lines[start..<min(start + linesPerChunk, lines.count)].joined(separator: "\n")
        }
    }
}

extension View {
    /// How a raw protocol dump reads on screen: monospaced, selectable, from the leading edge.
    func diagnosticText() -> some View {
        font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
