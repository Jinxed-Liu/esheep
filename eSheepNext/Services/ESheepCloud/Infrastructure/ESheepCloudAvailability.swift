import Foundation

/// Product-facing availability facade. Existing provider configuration keys
/// remain a deployment compatibility detail and never escape this boundary.
enum ESheepCloudAvailability {
    static var isEnabled: Bool {
        SupabaseAccountConfiguration.isEnabled
    }

    static var isConfigured: Bool {
        SupabaseAccountConfiguration.isConfigured
    }
}
