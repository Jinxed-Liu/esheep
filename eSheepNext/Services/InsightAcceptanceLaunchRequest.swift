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

    static func takePrompt() -> String? {
        guard !didSubmit, let prompt else { return nil }
        didSubmit = true
        return prompt
    }
}
#endif
