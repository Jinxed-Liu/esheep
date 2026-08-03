#if DEBUG
import Foundation
import SwiftData

@MainActor
enum DevelopmentSupabaseAcceptanceURLHandler {
    private static let expectedScheme = "esheep"
    private static let expectedHost = "development"
    private static let expectedPath = "/supabase-acceptance"
    private static let conflictPenName = "DEV-CONFLICT-PEN"

    static func handle(
        _ url: URL,
        account: AccountProfile?,
        farm: FarmRecord?,
        context: ModelContext,
        collaboration: CloudCollaborationStore
    ) -> Bool {
        guard Bundle.main.bundleIdentifier == "com.sheepfarm.next.dev",
              url.scheme?.lowercased() == expectedScheme,
              url.host?.lowercased() == expectedHost,
              url.path == expectedPath else {
            return false
        }
        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        let command = components?.queryItems?
            .first(where: { $0.name == "command" })?
            .value?
            .lowercased()
        if command == "revoked-access-probe" {
            guard let account else {
                recordResult("revoked-probe:rejected=no-account")
                return true
            }
            recordResult("revoked-probe:started")
            Task { @MainActor in
                await runRevokedAccessProbe(
                    account: account,
                    context: context
                )
            }
            return true
        }
        guard let account, let farm else {
            recordResult("rejected:no-active-account-or-farm")
            return true
        }
        do {
            switch command {
            case "online":
                let count = requestedCount(from: components)
                let created = try createNotes(
                    prefix: prefix(for: farm.role, suffix: "ONLINE"),
                    count: count,
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("online:created=\(created)")
            case "cursor":
                let created = try createNotes(
                    prefix: prefix(for: farm.role, suffix: "CURSOR"),
                    count: 1,
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("cursor:created=\(created)")
            case "offline-on":
                UserDefaults.standard.set(
                    true,
                    forKey: DevelopmentSupabaseNetworkGate.forcedOfflineKey
                )
                collaboration.refreshSupabaseRealtimeAcceptanceMode()
                recordResult("offline:on")
            case "offline-create":
                guard DevelopmentSupabaseNetworkGate.isForcedOffline else {
                    throw CocoaError(
                        .validationMissingMandatoryProperty,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "必须先启用 Development 强制离线。"
                        ]
                    )
                }
                let count = requestedCount(from: components)
                let created = try createNotes(
                    prefix: prefix(for: farm.role, suffix: "OFFLINE"),
                    count: count,
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("offline:created=\(created)")
            case "offline-off":
                UserDefaults.standard.set(
                    false,
                    forKey: DevelopmentSupabaseNetworkGate.forcedOfflineKey
                )
                collaboration.refreshSupabaseRealtimeAcceptanceMode()
                CloudRuntimeNotification.postSyncWake(farmID: farm.id)
                recordResult("offline:off")
            case "realtime-off":
                UserDefaults.standard.set(
                    true,
                    forKey: DevelopmentSupabaseRealtimeGate.disabledKey
                )
                collaboration.refreshSupabaseRealtimeAcceptanceMode()
                recordResult("realtime:off")
            case "realtime-on":
                UserDefaults.standard.set(
                    false,
                    forKey: DevelopmentSupabaseRealtimeGate.disabledKey
                )
                collaboration.refreshSupabaseRealtimeAcceptanceMode()
                CloudRuntimeNotification.postSyncWake(farmID: farm.id)
                recordResult("realtime:on")
            case "probe":
                recordResult(
                    try acceptanceProbe(
                        farm: farm,
                        context: context,
                        collaboration: collaboration
                    )
                )
            case "conflict-setup":
                let created = try prepareConflictPen(
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("conflict:setup=\(created ? "created" : "existing")")
            case "conflict-write":
                let revision = try writeConflictPen(
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("conflict:write=\(farm.role.rawValue);revision=\(revision)")
            case "conflict-resolve":
                let operationID = try resolveFirstConflict(
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("conflict:resolved=\(operationID.uuidString.lowercased())")
            case "conflict-reconcile":
                let repaired = try RemoteDomainApplyService
                    .reconcileResolvedConflictProjections(
                        farmID: farm.id,
                        context: context
                    )
                recordResult("conflict:reconciled=\(repaired)")
            case "member-revoke":
                guard farm.role == .owner,
                      let client = AccountIdentityClients.supabaseClient else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                recordResult("member-revoke:started")
                Task { @MainActor in
                    do {
                        let members = try await SupabaseFarmTransport(client: client)
                            .members(farmID: farm.id)
                        guard let userID = members.first(where: {
                            $0.role != .owner &&
                                $0.status == .active &&
                                $0.providerUserID != nil
                        })?.providerUserID else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        try await SupabaseFarmInviteClient(client: client)
                            .revoke(farmID: farm.id, memberUserID: userID)
                        recordResult(
                            "member-revoke:completed=\(userID.uuidString.lowercased())"
                        )
                    } catch {
                        let value = error as NSError
                        recordResult(
                            "member-revoke:failed=\(value.domain):\(value.code)"
                        )
                    }
                }
            case "revoke":
                let revoked = try revokeNotes(
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult("revoke:count=\(revoked)")
            case "cleanup":
                let result = try cleanupAcceptanceArtifacts(
                    account: account,
                    farm: farm,
                    context: context
                )
                recordResult(
                    "cleanup:notes=\(result.notes);pens=\(result.pens)"
                )
            default:
                recordResult("rejected:unknown-command")
            }
        } catch {
            let value = error as NSError
            recordResult("failed:\(value.domain):\(value.code)")
        }
        return true
    }

    private static func runRevokedAccessProbe(
        account: AccountProfile,
        context: ModelContext
    ) async {
        guard let client = AccountIdentityClients.supabaseClient,
              let farm = try? context.fetch(FetchDescriptor<FarmRecord>())
                .first(where: {
                    $0.role != .owner &&
                        $0.membershipStatusRawValue ==
                            FarmMembershipStatus.revoked.rawValue
                }) else {
            recordResult("revoked-probe:rejected=no-revoked-farm")
            return
        }
        do {
            let access: [SupabaseFarmAccessDescriptor] = try await client
                .rpc("list_my_active_farm_access")
                .execute()
                .value

            var membersDenied = false
            var memberCount = -1
            do {
                let members = try await SupabaseFarmTransport(client: client)
                    .members(farmID: farm.id)
                memberCount = members.count
                membersDenied = members.isEmpty
            } catch {
                membersDenied = true
            }

            var rpcDenied = false
            do {
                _ = try await SupabaseFarmStorageMetricsClient(client: client)
                    .metrics(farmID: farm.id)
            } catch {
                rpcDenied = true
            }

            var storageDenied = false
            var storageTested = false
            if let asset = try context.fetch(FetchDescriptor<PhotoAssetRecord>())
                .first(where: {
                    $0.farmID == farm.id &&
                        $0.deletedAt == nil &&
                        !$0.sha256.isEmpty
                }) {
                storageTested = true
                do {
                    _ = try await client.storage
                        .from("farm-assets")
                        .download(
                            path: "\(farm.id.uuidString.lowercased())/\(asset.sha256)"
                        )
                } catch {
                    storageDenied = true
                }
            }

            var realtimeDenied = false
            let session = try await client.auth.session
            await client.realtimeV2.setAuth(session.accessToken)
            let channel = client.channel(
                "farm:\(farm.id.uuidString.lowercased())"
            ) { configuration in
                configuration.isPrivate = true
            }
            do {
                try await channel.subscribeWithError()
            } catch {
                realtimeDenied = true
            }
            await client.removeChannel(channel)

            recordResult([
                "revoked-probe",
                "account=\(account.effectiveAccountID.uuidString.lowercased())",
                "access=\(access.count)",
                "members=\(memberCount)",
                "membersDenied=\(membersDenied)",
                "rpcDenied=\(rpcDenied)",
                "storageTested=\(storageTested)",
                "storageDenied=\(storageDenied)",
                "realtimeDenied=\(realtimeDenied)"
            ].joined(separator: ";"))
        } catch {
            let value = error as NSError
            recordResult("revoked-probe:failed=\(value.domain):\(value.code)")
        }
    }

    private static func acceptanceProbe(
        farm: FarmRecord,
        context: ModelContext,
        collaboration: CloudCollaborationStore
    ) throws -> String {
        let binding = try context.fetch(FetchDescriptor<FarmRemoteBinding>())
            .first {
                $0.farmID == farm.id &&
                    $0.provider == .supabase &&
                    $0.state == .active
            }
        let outboxCount = try context.fetch(FetchDescriptor<OutboxItem>())
            .filter {
                $0.farmID == farm.id &&
                    $0.deliveryProvider == .supabase &&
                    !$0.status.isTerminalDelivery
            }
            .count
        let activeDevelopmentNotes = try context
            .fetch(FetchDescriptor<NoteRecord>())
            .filter {
                $0.farmID == farm.id &&
                    $0.deletedAt == nil &&
                    $0.text.hasPrefix("DEV-")
            }
        let unresolvedConflicts = try context
            .fetch(FetchDescriptor<SyncConflictRecord>())
            .filter {
                $0.farmID == farm.id &&
                    ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                        $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
            }
        let conflictPen = try context.fetch(FetchDescriptor<PenRecord>())
            .first {
                $0.farmID == farm.id &&
                    $0.deletedAt == nil &&
                    $0.name == conflictPenName
            }
        let conflictPenConflictCount = conflictPen.map { pen in
            unresolvedConflicts.filter { $0.entityID == pen.id }.count
        } ?? 0
        let latestNote = activeDevelopmentNotes
            .map(\.text)
            .max() ?? "none"
        let realtime = collaboration.supabaseRealtimeHealth(farmID: farm.id)
        return [
            "probe",
            "cursor=\(binding?.lastPulledRevision ?? -1)",
            "outbox=\(outboxCount)",
            "notes=\(activeDevelopmentNotes.count)",
            "latest=\(latestNote)",
            "conflicts=\(unresolvedConflicts.count)",
            "conflictPenConflicts=\(conflictPenConflictCount)",
            "conflictPenRevision=\(conflictPen?.revision ?? -1)",
            "conflictPenNote=\(conflictPen?.note ?? "none")",
            "realtime=\(realtime.displayTitle)",
            "error=\(realtime.errorCode ?? "none")"
        ].joined(separator: ";")
    }

    private static func prepareConflictPen(
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> Bool {
        let exists = try context.fetch(FetchDescriptor<PenRecord>()).contains {
            $0.farmID == farm.id &&
                $0.deletedAt == nil &&
                $0.name == conflictPenName
        }
        guard !exists else { return false }
        try FarmCommandService().execute(
            .createPen(name: conflictPenName, note: "Development 冲突验收专用"),
            in: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: farm.role
            ),
            context: context
        )
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return true
    }

    private static func writeConflictPen(
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> Int {
        guard let pen = try context.fetch(FetchDescriptor<PenRecord>()).first(where: {
            $0.farmID == farm.id &&
                $0.deletedAt == nil &&
                $0.name == conflictPenName
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FarmCommandService().execute(
            .updatePen(
                penID: pen.id,
                name: pen.name,
                note: "DEV-CONFLICT-\(farm.role == .owner ? "A" : "B")"
            ),
            in: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: farm.role
            ),
            context: context
        )
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return pen.revision
    }

    private static func resolveFirstConflict(
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> UUID {
        guard let pen = try context.fetch(FetchDescriptor<PenRecord>()).first(where: {
            $0.farmID == farm.id &&
                $0.deletedAt == nil &&
                $0.name == conflictPenName
        }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let conflict = try context.fetch(FetchDescriptor<SyncConflictRecord>())
            .filter({
                $0.farmID == farm.id &&
                    $0.entityID == pen.id &&
                    $0.entityType == CloudEntityType.pen.rawValue &&
                    ($0.statusRawValue == SyncConflictStatus.unresolved.rawValue ||
                        $0.statusRawValue == SyncConflictStatus.quarantined.rawValue)
            })
            .sorted(by: { $0.detectedAt < $1.detectedAt })
            .first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let operationID = try FarmCommandService().resolveConflict(
            conflictID: conflict.id,
            decision: .acceptRemote,
            note: "Development 并发冲突验收：采用远端权威",
            in: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: farm.role
            ),
            context: context
        )
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return operationID
    }

    private static func requestedCount(
        from components: URLComponents?
    ) -> Int {
        let raw = components?.queryItems?
            .first(where: { $0.name == "count" })?
            .value
        return min(max(Int(raw ?? "20") ?? 20, 1), 20)
    }

    private static func prefix(for role: FarmRole, suffix: String) -> String {
        let actor = role == .owner ? "A" : "B"
        return "DEV-\(actor)-\(suffix)"
    }

    private static func createNotes(
        prefix: String,
        count: Int,
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> Int {
        guard let profile = try context
            .fetch(FetchDescriptor<FarmStorageProfile>())
            .first(where: { $0.farmID == farm.id }),
              profile.mode == .supabase,
              profile.transitionState == .idle else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let existingTexts = Set(
            try context.fetch(FetchDescriptor<NoteRecord>())
                .filter {
                    $0.farmID == farm.id &&
                        $0.text.hasPrefix(prefix + "-")
                }
                .map(\.text)
        )
        let targetSheepID = try context.fetch(FetchDescriptor<SheepRecord>())
            .filter {
                $0.farmID == farm.id &&
                    $0.deletedAt == nil &&
                    $0.status == .active
            }
            .min {
                $0.id.uuidString.lowercased() <
                    $1.id.uuidString.lowercased()
            }?
            .id
        let targetPenID = targetSheepID == nil
            ? try context.fetch(FetchDescriptor<PenRecord>())
                .filter {
                    $0.farmID == farm.id &&
                        $0.deletedAt == nil &&
                        $0.isActive
                }
                .min {
                    $0.id.uuidString.lowercased() <
                        $1.id.uuidString.lowercased()
                }?
                .id
            : nil
        guard targetSheepID != nil || targetPenID != nil else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let nextIndex = existingTexts.compactMap { value in
            Int(value.dropFirst(prefix.count + 1))
        }.max().map { $0 + 1 } ?? 1
        var created = 0
        for offset in 0..<count {
            let text = "\(prefix)-\(String(format: "%03d", nextIndex + offset))"
            guard !existingTexts.contains(text) else { continue }
            try FarmCommandService().execute(
                .addNote(
                    sheepID: targetSheepID,
                    penID: targetPenID,
                    text: text,
                    occurredAt: .now
                ),
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: context
            )
            created += 1
        }
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return created
    }

    private static func revokeNotes(
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> Int {
        let notes = try context.fetch(FetchDescriptor<NoteRecord>())
            .filter {
                $0.farmID == farm.id &&
                    $0.deletedAt == nil &&
                    $0.text.hasPrefix("DEV-")
            }
        for note in notes {
            try FarmCommandService().execute(
                .tombstoneEntity(
                    entityType: .note,
                    entityID: note.id,
                    reason: "Development 双机同步验收完成"
                ),
                in: FarmContext(
                    accountID: account.effectiveAccountID,
                    farmID: farm.id,
                    role: farm.role
                ),
                context: context
            )
        }
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return notes.count
    }

    private static func cleanupAcceptanceArtifacts(
        account: AccountProfile,
        farm: FarmRecord,
        context: ModelContext
    ) throws -> (notes: Int, pens: Int) {
        let noteCount = try revokeNotes(
            account: account,
            farm: farm,
            context: context
        )
        let pen = try context.fetch(FetchDescriptor<PenRecord>())
            .first {
                $0.farmID == farm.id &&
                    $0.deletedAt == nil &&
                    $0.name == conflictPenName
            }
        guard let pen else {
            return (noteCount, 0)
        }
        try FarmCommandService().execute(
            .tombstoneEntity(
                entityType: .pen,
                entityID: pen.id,
                reason: "Development 冲突验收完成"
            ),
            in: FarmContext(
                accountID: account.effectiveAccountID,
                farmID: farm.id,
                role: farm.role
            ),
            context: context
        )
        CloudRuntimeNotification.postSyncWake(farmID: farm.id)
        return (noteCount, 1)
    }

    private static func recordResult(_ result: String) {
        UserDefaults.standard.set(
            result,
            forKey: "development.supabase.acceptance.lastResult"
        )
        UserDefaults.standard.set(
            Date().timeIntervalSince1970,
            forKey: "development.supabase.acceptance.lastResultAt"
        )
        print("[DevelopmentSupabaseAcceptance] \(result)")
    }
}
#endif
