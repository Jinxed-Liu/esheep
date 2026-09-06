import Foundation
import Supabase

extension ESheepCloudSyncFailure {
    static func classify(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if case let FunctionsError.httpError(code, data) = error {
            struct Detail: Decodable { let category: Kind; let trace_id: UUID }
            if let detail = try? JSONDecoder().decode(Detail.self, from: data) {
                return Self(kind: detail.category, statusCode: code, traceID: detail.trace_id.uuidString.lowercased())
            }
            let kind: Kind = switch code {
            case 401: .authentication
            case 403: .permission
            case 404: .serviceUnavailable
            case 409: .conflict
            case 408, 429, 500...599: .server
            default: .unknown
            }
            return Self(kind: kind, statusCode: code)
        }
        if let transfer = error as? ESheepCloudInfrastructureError {
            switch transfer {
            case .transferFailed(let code):
                return classify(FunctionsError.httpError(code: code, data: Data()))
            default: return Self(kind: .integrity)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return Self(kind: .network)
        }
        if let error = error as? ESheepCloudCoreError {
            switch error {
            case .reauthenticationRequired: return Self(kind: .authentication)
            case .deviceIdentityChanged: return Self(kind: .permission)
            case .cloudWriteFrozen: return Self(kind: .integrity)
            default: break
            }
        }
        if error is ESheepCloudProjectionError || error is ESheepCloudContractError || error is ESheepCloudCheckpointError {
            return Self(kind: .integrity)
        }
        if let error = error as? PostgrestError {
            if error.code == "42501" { return Self(kind: .permission) }
            if error.code?.hasPrefix("PGRST3") == true { return Self(kind: .authentication) }
            if error.code?.hasPrefix("08") == true { return Self(kind: .server) }
        }
        return Self(kind: .unknown)
    }
}
