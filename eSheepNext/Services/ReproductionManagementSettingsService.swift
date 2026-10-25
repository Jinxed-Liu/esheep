import Foundation
import SwiftData

enum ReproductionSettingsError: LocalizedError {
    case changed
    case unreadable
    var errorDescription: String? {
        switch self {
        case .changed: "繁殖设置已被更新。请返回重新打开设置，核对后再保存。"
        case .unreadable: "繁殖设置无法读取，请核对同步资料或更新 App。"
        }
    }
}

@MainActor
enum ReproductionManagementSettingsService {
    static func save(_ settings: ReproductionManagementSettings, expected: ReproductionManagementSettings?,
                     accountID: UUID, farm: FarmRecord, context: ModelContext) throws {
        let farmID = farm.id
        let record = try context.fetch(FetchDescriptor<FarmCareRuleRecord>(predicate: #Predicate { $0.farmID == farmID })).first
        // Updating unrelated legacy rules is safe. A concurrent edit to the
        // reproduction document itself must never be silently overwritten.
        guard try ReproductionManagementSettings.decode(record?.reproductionSettingsJSON) == expected else {
            throw ReproductionSettingsError.changed
        }
        let draft = FarmOperationalAlertRuleDraft(id: record?.id ?? UUID(),
            pregnancyCheckDays: record?.pregnancyCheckDays ?? 45, gestationDays: record?.gestationDays ?? 150,
            weaningAgeDays: record?.weaningAgeDays ?? 60, warningLeadDays: record?.warningLeadDays ?? 0,
            digestEnabled: record?.alertDigestEnabled ?? false, digestMinuteOfDay: record?.alertDigestMinuteOfDay ?? 480,
            reproductionSettings: try settings.validated(), updatesReproductionOnly: true)
        try FarmCommandService().execute(.care(.updateOperationalAlertRules(draft)),
            in: FarmContext(accountID: accountID, farmID: farmID, role: farm.role), context: context)
    }
}
