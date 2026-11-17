import Foundation

/// A cook that filed at least one photo to Recent Results: the run to open, and the develops in it
/// that failed. Failures are never filed, so the results screen is the one place left to say so.
struct DevelopRun: Hashable, Identifiable {
    let batchID: UUID
    let failures: [FailedDevelop]

    var id: UUID { batchID }

    /// The run for a Develop batch: one recipe, so a failure is named by its file alone.
    init(batchID: UUID, results: [ConversionResult]) {
        self.batchID = batchID
        failures = results.filter { !$0.success }.map { FailedDevelop($0, recipeName: nil) }
    }

    /// The run for a Test Kitchen grid, where a failure is one recipe's version of one file.
    init(batchID: UUID, comparisons: [TestKitchenComparison]) {
        self.batchID = batchID
        failures = comparisons.flatMap(\.versions)
            .filter { !$0.result.success }
            .map { FailedDevelop($0.result, recipeName: $0.recipeName) }
    }
}

/// One develop that produced no photo, as the results screen lists it.
struct FailedDevelop: Hashable, Identifiable {
    let id: UUID
    /// "Portra 400 · DSCF4072.RAF", or the file name alone when the run had one recipe.
    let title: String
    let message: String
    /// The conversion-profile report, shown behind Diagnostic Mode.
    let diagnostics: String?

    init(_ result: ConversionResult, recipeName: String?) {
        id = result.id
        title = recipeName.map { "\($0) · \(result.sourceFilename)" } ?? result.sourceFilename
        message = result.errorMessage ?? "Unknown error"
        diagnostics = result.diagnostics
    }
}
