#if DEBUG
import CryptoKit
import OSLog
import SwiftData
import SwiftUI
import UIKit

/// Opt-in, UUID-scoped diagnostics for the existing offline fixture. Never
/// enabled in Release or for the real-farm acceptance route.
@MainActor
enum DevelopmentPosterAcceptance {
    nonisolated static var directory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--design-poster") else { return nil }
        precondition(["--design-acceptance", "--design-reproduction", "--design-sheep-detail"].allSatisfy(args.contains)
                     && !args.contains("--design-real-farm"))
        guard let index = args.firstIndex(of: "--design-fixture-id"),
              args.indices.contains(index + 1), let id = UUID(uuidString: args[index + 1]) else {
            preconditionFailure("Poster tests require a valid isolated fixture UUID")
        }
        return URL.applicationSupportDirectory.appending(path: "DesignAcceptance/Poster/\(id.uuidString)", directoryHint: .isDirectory)
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func state(snapshot: SheepSharePosterSnapshot, image: UIImage?, style: SheepSharePosterStyle,
                      template: SheepSharePosterTemplate, customization: SheepSharePosterCustomization,
                      selectedID: String, savedTemplateNames: [String]) -> String {
        guard directory != nil else { return "" }
        struct State: Encodable {
            let style: String
            let template: String
            let selectedID: String
            let customization: SheepSharePosterCustomization
            let elements: [SheepPosterElement]
            let photoDigest: String
            let savedTemplateNames: [String]
            let templateStore: TemplateStoreEvidence
        }
        let source = customization.photoData.flatMap(UIImage.init(data:)) ?? image
        let value = State(style: style.rawValue, template: template.rawValue, selectedID: selectedID,
                          customization: customization,
                          elements: customization.elements(from: SheepSharePosterLayout.elements(snapshot: snapshot, style: style, template: template)),
                          photoDigest: source?.pngData().map(digest) ?? "missing",
                          savedTemplateNames: savedTemplateNames, templateStore: templateStoreEvidence())
        return encoded(value)
    }

    private struct TemplateStoreEvidence: Encodable {
        let fixtureID: String?
        let exists: Bool
        let digest: String?
        let names: [String]
        let error: String?
    }

    private static func templateStoreEvidence() -> TemplateStoreEvidence {
        guard let directory else {
            return .init(fixtureID: nil, exists: false, digest: nil, names: [], error: nil)
        }
        let url = directory.appending(path: "templates-v1.json")
        let exists = FileManager.default.fileExists(atPath: url.path)
        do {
            let data = exists ? try Data(contentsOf: url) : nil
            let names = try data.map { try JSONDecoder().decode([SheepSharePosterSavedTemplate].self, from: $0).map(\.name) } ?? []
            return .init(fixtureID: directory.lastPathComponent, exists: exists,
                         digest: data.map(digest), names: names, error: nil)
        } catch {
            return .init(fixtureID: directory.lastPathComponent, exists: exists,
                         digest: nil, names: [], error: String(describing: error))
        }
    }

    /// Read-only evidence for the opt-in local fixture. No production paths or
    /// names are read or logged, and the existing template file is never edited.
    static func recordTemplateEvent(_ event: String, inputName: String? = nil, error: Error? = nil) {
        guard directory != nil else { return }
        struct Event: Encodable {
            let event: String
            let inputName: String?
            let store: TemplateStoreEvidence
            let error: String?
        }
        let value = Event(event: event, inputName: inputName, store: templateStoreEvidence(),
                          error: error.map { String(describing: $0) })
        Logger(subsystem: "com.sheepfarm.next.poster", category: "fixture-store")
            .notice("\(encoded(value), privacy: .public)")
    }

    nonisolated static func encoded<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return "encoding-failed"
        }
        return string
    }

    static func seed(account: AccountProfile, farm: FarmRecord, context: ModelContext) throws {
        guard let directory else { return }
        guard account.appleSubjectHash == AppleIdentityHash.value(for: "design-acceptance-local"),
              try FarmStorageRouter.route(farmID: farm.id, context: context).mode == .localOnly else {
            throw InsightSecurityError.accountMismatch
        }
        let farmID = farm.id
        let sheep = try context.fetch(FetchDescriptor<SheepRecord>(predicate: #Predicate { $0.farmID == farmID }))
        let photos = try context.fetch(FetchDescriptor<PhotoAssetRecord>(predicate: #Predicate { $0.farmID == farmID }))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, tag) in ["QA-001", "QA-002"].enumerated() {
            guard let animal = sheep.first(where: { $0.earTag == tag }),
                  !photos.contains(where: { $0.sheepID == animal.id }) else { continue }
            // Different asymmetric color blocks reveal stale photos and crop errors.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: format).image { ctx in
                (index == 0 ? UIColor.red : UIColor.blue).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
                (index == 0 ? UIColor.yellow : UIColor.cyan).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 320))
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 300, y: 40, width: 80, height: 80))
            }
            guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            let url = directory.appending(path: "\(tag).png")
            try data.write(to: url, options: .atomic)
            context.insert(PhotoAssetRecord(farmID: farmID, sheepID: animal.id,
                legacySourceKey: "poster-fixture-\(tag)", originalEarTag: tag,
                relativePath: url.path, sha256: digest(data), mimeType: "image/png"))
            animal.damID = sheep.first { $0.earTag == (index == 0 ? "QA-003" : "QA-004") }?.id
            animal.sireID = nil
        }
        try context.save()
    }
}

@MainActor @Observable
final class DevelopmentPosterExportEvidence {
    var exportedPNG: Data?
    var error: String?

    func value(preview: UIImage) -> String {
        guard DevelopmentPosterAcceptance.directory != nil else { return "" }
        struct Evidence: Encodable {
            let previewPNG: Data?
            let exportedPNG: Data?
            let error: String?
        }
        return DevelopmentPosterAcceptance.encoded(Evidence(previewPNG: preview.pngData(), exportedPNG: exportedPNG, error: error))
    }
}

/// A real UIActivity receives the exact shared UIImage, writes it into the
/// fixture namespace, then decodes it again. This proves the app/share boundary;
/// it does not claim acceptance of Photos, AirDrop, or third-party destinations.
@MainActor
final class DevelopmentPosterSaveActivity: UIActivity {
    private let evidence: DevelopmentPosterExportEvidence
    private var image: UIImage?
    init(evidence: DevelopmentPosterExportEvidence) { self.evidence = evidence; super.init() }
    override var activityType: UIActivity.ActivityType? { .init("com.esheep.test.savePoster") }
    override var activityTitle: String? { "Save regression PNG" }
    override var activityImage: UIImage? { UIImage(systemName: "internaldrive") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        DevelopmentPosterAcceptance.directory != nil && activityItems.contains { $0 is UIImage }
    }
    override func prepare(withActivityItems activityItems: [Any]) {
        image = activityItems.compactMap { $0 as? UIImage }.first
    }
    override func perform() {
        do {
            guard let directory = DevelopmentPosterAcceptance.directory, let data = image?.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = directory.appending(path: "shared-poster.png")
            try data.write(to: url, options: .atomic)
            let stored = try Data(contentsOf: url)
            guard UIImage(data: stored) != nil else { throw CocoaError(.fileReadCorruptFile) }
            evidence.exportedPNG = stored
            evidence.error = nil
            activityDidFinish(true)
        } catch {
            evidence.error = error.localizedDescription
            activityDidFinish(false)
        }
    }
}
#endif
