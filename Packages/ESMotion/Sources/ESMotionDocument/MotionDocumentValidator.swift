import Foundation

public enum MotionValidationSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct MotionValidationIssue: Codable, Equatable, Sendable {
    public let severity: MotionValidationSeverity
    public let path: String
    public let message: String

    public init(
        severity: MotionValidationSeverity,
        path: String,
        message: String
    ) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

public enum MotionDocumentValidator {
    public static func validate(
        _ document: MotionDocument,
        rootURL: URL? = nil
    ) -> [MotionValidationIssue] {
        var issues: [MotionValidationIssue] = []
        let assetIDs = document.assets.map(\.id)
        let duplicateAssetIDs = duplicates(in: assetIDs)

        for duplicate in duplicateAssetIDs.sorted() {
            issues.append(
                MotionValidationIssue(
                    severity: .error,
                    path: "assets.\(duplicate)",
                    message: "Asset identifiers must be unique."
                )
            )
        }

        let knownAssetIDs = Set(assetIDs)
        walk(layers: document.layers) { layer, path in
            if let assetID = layer.assetID, !knownAssetIDs.contains(assetID) {
                issues.append(
                    MotionValidationIssue(
                        severity: .error,
                        path: "\(path).assetID",
                        message: "Unknown asset identifier '\(assetID)'."
                    )
                )
            }
        }

        let sequenceIDs = document.sequences.map(\.id)
        let knownSequenceIDs = Set(sequenceIDs)
        for state in document.states {
            for sequenceID in state.sequenceIDs where !knownSequenceIDs.contains(sequenceID) {
                issues.append(
                    MotionValidationIssue(
                        severity: .error,
                        path: "states.\(state.id).sequenceIDs",
                        message: "Unknown sequence identifier '\(sequenceID)'."
                    )
                )
            }
        }

        for asset in document.assets {
            guard let relativePath = asset.relativePath else { continue }
            if relativePath.hasPrefix("/") || relativePath.contains("..") {
                issues.append(
                    MotionValidationIssue(
                        severity: .error,
                        path: "assets.\(asset.id).relativePath",
                        message: "Asset paths must remain inside the package."
                    )
                )
                continue
            }

            if let rootURL {
                let fileURL = rootURL.appending(path: relativePath)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    issues.append(
                        MotionValidationIssue(
                            severity: .error,
                            path: "assets.\(asset.id).relativePath",
                            message: "Asset file does not exist."
                        )
                    )
                }
            }
        }

        if document.reducedMotion.staticStateID == nil,
           document.reducedMotion.sequenceID == nil {
            issues.append(
                MotionValidationIssue(
                    severity: .warning,
                    path: "reducedMotion",
                    message: "Provide a static state or reduced-motion sequence."
                )
            )
        }

        return issues
    }

    private static func duplicates<T: Hashable>(
        in values: [T]
    ) -> Set<T> {
        var seen: Set<T> = []
        var duplicates: Set<T> = []
        for value in values where !seen.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates
    }

    private static func walk(
        layers: [MotionLayer],
        path: String = "layers",
        visit: (MotionLayer, String) -> Void
    ) {
        for layer in layers {
            let layerPath = "\(path).\(layer.id.uuidString)"
            visit(layer, layerPath)
            walk(
                layers: layer.children,
                path: "\(layerPath).children",
                visit: visit
            )
        }
    }
}
