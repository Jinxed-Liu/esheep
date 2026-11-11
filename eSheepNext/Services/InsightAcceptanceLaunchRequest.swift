import Foundation

#if DEBUG
/// A process-scoped hook for repeatable physical-device acceptance runs.
///
/// The prompt is supplied by the developer at launch time and still travels
/// through the normal conversation controller, model, tools, review, and
/// persistence path. Release builds do not contain this hook.
@MainActor
enum InsightAcceptanceLaunchRequest {
    private static let argumentName = "--insight-acceptance-prompt"
    private(set) static var didSubmit = false

    static let prompt: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argumentName),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        let value = arguments[index + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }()

    // Fixed temporary file installed into the Dev container for visual acceptance.
    // Photos, the pasteboard and business records are never accessed by this hook.
    static func fixtureImages() throws -> [PendingInsightImage] {
        guard ProcessInfo.processInfo.arguments.contains("--insight-acceptance-image") else { return [] }
        let url = FileManager.default.temporaryDirectory.appending(path: "assistant-acceptance.png")
        guard let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 4 * 1024 * 1024 else {
            throw MiMoClientError.invalidRequest
        }
        return [try InsightImageOptimizer.optimize(Data(contentsOf: url))]
    }

    static func takePrompt() -> String? {
        guard !didSubmit, let prompt else { return nil }
        didSubmit = true
        return prompt
    }
}
#endif
