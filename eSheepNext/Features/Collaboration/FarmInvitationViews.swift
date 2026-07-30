import CoreImage
import CoreImage.CIFilterBuiltins
import MessageUI
import SwiftUI
import UIKit
import VisionKit

struct FarmInvitationPackage: Identifiable, Sendable, Equatable {
    let inviteID: String
    let farmID: UUID
    let farmName: String
    let role: FarmRole
    let url: URL
    let inviteCode: String
    let shareParticipantID: String?
    let expiresAt: Date

    var id: String { inviteID }
    var usesOneTimeURL: Bool { shareParticipantID != nil }

    var joinURL: URL {
        var components = URLComponents()
        components.scheme = AppEnvironment.current == .staging
            ? "esheep-staging"
            : "esheep"
        components.host = "invite"
        components.queryItems = [
            URLQueryItem(name: "code", value: inviteCode),
            URLQueryItem(name: "share", value: url.absoluteString),
        ]
        return components.url ?? url
    }

    var subject: String {
        "邀请你加入\(farmName)"
    }

    var message: String {
        if usesOneTimeURL {
            return """
            \(subject)
            成员角色：\(role.displayName)

            1. 点击链接接受 iCloud 共享：
            \(url.absoluteString)

            2. 如 App 提示，请输入邀请码：\(inviteCode)

            邀请将在\(expiresAt.formatted(date: .abbreviated, time: .shortened))前有效。
            """
        }
        return """
        \(subject)
        成员角色：\(role.displayName)

        1. 点击 eSheepNext 邀请提交加入申请：
        \(joinURL.absoluteString)
        也可在“加入牧场”中输入邀请码：\(inviteCode)

        2. 场主批准加入后，点击链接接受私有共享：
        \(url.absoluteString)

        邀请将在\(expiresAt.formatted(date: .abbreviated, time: .shortened))前有效。
        """
    }
}

private enum FarmInvitationDestination: Identifiable {
    case message(FarmInvitationPackage)
    case activity(FarmInvitationPackage)
    case qrCode(FarmInvitationPackage)
    case proximity(FarmInvitationPackage)

    var id: String {
        switch self {
        case .message: "message"
        case .activity: "activity"
        case .qrCode: "qr-code"
        case .proximity: "proximity"
        }
    }
}

struct FarmInvitationPanel: View {
    @Environment(\.dismiss) private var dismiss

    let package: FarmInvitationPackage

    @State private var destination: FarmInvitationDestination?
    @State private var copied = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(package.farmName)
                            .font(.title3.weight(.semibold))
                        LabeledContent("成员角色", value: package.role.displayName)
                        LabeledContent(
                            "有效期至",
                            value: package.expiresAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("本次邀请")
                } footer: {
                    Text(
                        package.usesOneTimeURL
                            ? "五种方式发送的是同一个私有邀请。对方接受后会自动匹配成员关系。"
                            : "五种方式发送的是同一份私有邀请。对方提交 iCloud 身份、场主批准后，再打开共享链接加入。"
                    )
                }

                Section("面对面邀请") {
                    invitationButton(
                        title: "靠近邀请",
                        subtitle: "两台手机并排靠近后安全传送",
                        systemImage: "wave.3.right.circle.fill",
                        tint: .indigo
                    ) {
                        destination = .proximity(package)
                    }

                    invitationButton(
                        title: "二维码",
                        subtitle: "让对方在 eSheepNext 内扫描",
                        systemImage: "qrcode",
                        tint: .black
                    ) {
                        destination = .qrCode(package)
                    }
                }

                Section("发送给成员") {
                    invitationButton(
                        title: "iMessage",
                        subtitle: "打开信息并选择接收人",
                        systemImage: "message.fill",
                        tint: .green
                    ) {
                        guard MFMessageComposeViewController.canSendText() else {
                            errorMessage = "当前设备不能发送信息，请改用复制链接或其他方式。"
                            return
                        }
                        destination = .message(package)
                    }

                    invitationButton(
                        title: "微信",
                        subtitle: "在系统分享面板中选择微信",
                        systemImage: "bubble.left.and.bubble.right.fill",
                        tint: Color(red: 0.10, green: 0.68, blue: 0.25)
                    ) {
                        destination = .activity(package)
                    }

                    invitationButton(
                        title: copied ? "邀请内容已复制" : "链接邀请",
                        subtitle: "复制共享链接与邀请码",
                        systemImage: copied ? "checkmark.circle.fill" : "link",
                        tint: copied ? .green : .blue
                    ) {
                        UIPasteboard.general.string = package.message
                        copied = true
                    }
                }
            }
            .navigationTitle("邀请加入牧场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $destination) { destination in
                switch destination {
                case .message(let package):
                    MessageInvitationComposer(package: package)
                case .activity(let package):
                    SystemInvitationActivityView(package: package)
                case .qrCode(let package):
                    FarmInvitationQRCodeView(package: package)
                case .proximity(let package):
                    ProximityInvitationSenderView(package: package)
                }
            }
            .alert("无法发送邀请", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func invitationButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: .rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct MessageInvitationComposer: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let package: FarmInvitationPackage

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.subject = package.subject
        controller.body = package.message
        return controller
    }

    func updateUIViewController(
        _ uiViewController: MFMessageComposeViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            dismiss()
        }
    }
}

private struct SystemInvitationActivityView: UIViewControllerRepresentable {
    let package: FarmInvitationPackage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [package.message, package.url],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct FarmInvitationQRCodeView: View {
    @Environment(\.dismiss) private var dismiss

    let package: FarmInvitationPackage

    private var image: UIImage? {
        FarmInvitationQRCodeGenerator.image(
            for: package.joinURL.absoluteString,
            dimension: 900
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 16)
                Text(package.farmName)
                    .font(.title2.weight(.semibold))
                Text("请让对方打开 eSheepNext → 加入牧场 → 扫描邀请二维码")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .padding(18)
                        .background(.white, in: .rect(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
                        .accessibilityLabel("加入\(package.farmName)的邀请二维码")
                } else {
                    ContentUnavailableView(
                        "二维码生成失败",
                        systemImage: "qrcode",
                        description: Text("请返回并使用复制链接。")
                    )
                }

                Label(
                    "\(package.role.displayName) · 邀请码 \(package.inviteCode)",
                    systemImage: "lock.shield.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                Text("这是 App 私有邀请数据，系统相机不会把它当作网页链接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("二维码邀请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

enum FarmInvitationQRCodeGenerator {
    private static let context = CIContext()

    static func image(for value: String, dimension: CGFloat) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        let scale = max(1, floor(dimension / max(extent.width, extent.height)))
        let transformed = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

struct FarmInvitationQRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss

    let onScanned: (PendingFarmInvitation) -> Void

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                FarmInvitationDataScanner { value in
                    guard let url = URL(string: value),
                          let invitation = PendingFarmInvitation(url: url) else {
                        errorMessage = "这不是有效的 eSheepNext 牧场邀请二维码。"
                        return
                    }
                    onScanned(invitation)
                    dismiss()
                }
                .ignoresSafeArea()

                Label("将邀请二维码放入取景框", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.bottom, 28)
            }
            .navigationTitle("扫描邀请二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("无法识别邀请", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("继续扫描", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}

private struct FarmInvitationDataScanner: UIViewControllerRepresentable {
    let onValue: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onValue: onValue)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.qr]),
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: DataScannerViewController,
        context: Context
    ) {
        guard !uiViewController.isScanning else { return }
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onValue: (String) -> Void
        private var lastValue: String?

        init(onValue: @escaping (String) -> Void) {
            self.onValue = onValue
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue,
                      value != lastValue else {
                    continue
                }
                lastValue = value
                onValue(value)
                return
            }
        }
    }
}

struct ProximityInvitationSenderView: View {
    @Environment(\.dismiss) private var dismiss

    let package: FarmInvitationPackage

    @State private var controller = ProximityInvitationController()
    @State private var showsQRCode = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                proximitySymbol

                VStack(spacing: 8) {
                    Text(controller.status.title)
                        .font(.title2.weight(.semibold))
                    Text(statusDetail)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if case .transferred = controller.status {
                    Label("邀请已安全传送", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                } else if case .failed(let message) = controller.status {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("改用二维码") {
                        showsQRCode = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
                Text("对方需要在“加入牧场”中打开“靠近接收”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .navigationTitle("靠近邀请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task(id: package.id) {
                controller.startSending(ProximityFarmInvitationPayload(
                    farmName: package.farmName,
                    role: package.role,
                    url: package.url,
                    inviteCode: package.inviteCode,
                    expiresAt: package.expiresAt
                ))
            }
            .onDisappear {
                controller.stop()
            }
            .sheet(isPresented: $showsQRCode) {
                FarmInvitationQRCodeView(package: package)
            }
        }
    }

    @ViewBuilder
    private var proximitySymbol: some View {
        switch controller.status {
        case .transferred:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 78))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.orange)
        default:
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 82))
                .foregroundStyle(.indigo)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
    }

    private var statusDetail: String {
        switch controller.status {
        case .idle, .advertising:
            "让对方打开接收页面，将两台手机并排放置并逐渐靠近；不要让顶部相碰，以免触发系统 NameDrop。"
        case .searching:
            "正在查找附近的 eSheepNext。"
        case .connecting:
            "正在建立仅供本次邀请使用的加密连接。"
        case .moveCloser(let distance):
            if let distance {
                "已确认设备距离约 \(Int(distance * 100)) 厘米，正在发送加密邀请。"
            } else {
                "加密连接已建立，邀请正在自动发送，无需继续移动手机。"
            }
        case .transferred:
            "对方确认后会验证邀请码并打开 iCloud 共享。"
        case .received:
            ""
        case .failed:
            "你可以重试，或使用同一邀请的二维码。"
        }
    }
}

struct ProximityInvitationReceiverView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CloudCollaborationStore.self) private var collaboration

    let accountID: UUID

    @State private var controller = ProximityInvitationController()
    @State private var isJoining = false
    @State private var errorMessage: String?
    @State private var hasRedeemedCode = false
    @State private var redeemedFarmID: UUID?
    @State private var accessStatusMessage: String?
    @State private var didAcceptShare = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                receiverSymbol

                if didAcceptShare {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(.green)
                        Text("已加入共享牧场")
                            .font(.title2.weight(.semibold))
                        Text("场主签名和完整牧场资料均已验证。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else if let payload = controller.receivedPayload {
                    VStack(spacing: 12) {
                        Text("邀请加入\(payload.farmName)")
                            .font(.title2.weight(.semibold))
                        LabeledContent("成员角色", value: payload.role.displayName)
                            .frame(maxWidth: 320)
                        Text("确认后会验证邀请码，并把本机 iCloud 身份提交给场主批准。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if let accessStatusMessage {
                        Text(accessStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Button(isJoining ? "正在检查…" : (hasRedeemedCode ? "检查批准状态并加入" : "申请加入")) {
                        accept(payload)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isJoining)
                } else {
                    VStack(spacing: 8) {
                        Text(controller.status.title)
                            .font(.title2.weight(.semibold))
                        Text(statusDetail)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                if case .failed(let message) = controller.status {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    Button("重新查找") {
                        controller.startReceiving()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(28)
            .navigationTitle("靠近接收")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                controller.startReceiving()
            }
            .onDisappear {
                controller.stop()
            }
            .alert("无法加入牧场", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func accept(_ payload: ProximityFarmInvitationPayload) {
        guard !isJoining else { return }
        isJoining = true
        Task {
            defer { isJoining = false }
            do {
                let farmID: UUID
                if let redeemedFarmID {
                    farmID = redeemedFarmID
                } else {
                    let service = InviteServiceActor(
                        persistence: collaboration.persistence
                    )
                    let userRecordName = try await collaboration.sync
                        .currentCloudUserRecordName()
                    let redemption = try await service.redeem(
                        code: payload.inviteCode,
                        cloudKitUserRecordName: userRecordName
                    )
                    farmID = redemption.farmID
                    redeemedFarmID = farmID
                    hasRedeemedCode = true
                }

                let existingBinding = try await collaboration.persistence
                    .bindingSnapshot(farmID: farmID)
                if existingBinding?.databaseScope != .sharedDatabase {
                    try await collaboration.sync.acceptInvitedShare(
                        url: payload.url,
                        accountID: accountID
                    )
                }

                if await collaboration.completeAcceptedSharedFarmAdmission(
                    farmID: farmID,
                    accountID: accountID
                ) {
                    controller.stop()
                    didAcceptShare = true
                    accessStatusMessage = nil
                } else {
                    accessStatusMessage = "共享已接受。正在等待场主确认并下载完整牧场资料，稍后再点一次检查。"
                }
            } catch {
                if hasRedeemedCode {
                    accessStatusMessage = "加入申请已提交。请让场主批准；批准后再点“检查批准状态并加入”。"
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private var receiverSymbol: some View {
        switch controller.status {
        case .received:
            Image(systemName: "person.badge.plus")
                .font(.system(size: 74))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 70))
                .foregroundStyle(.orange)
        default:
            Image(systemName: "wave.3.left.circle.fill")
                .font(.system(size: 82))
                .foregroundStyle(.indigo)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
    }

    private var statusDetail: String {
        switch controller.status {
        case .idle, .searching:
            "请让场主打开靠近邀请，将两台手机并排放置并逐渐靠近；不要让顶部相碰。"
        case .advertising:
            "正在等待牧场主。"
        case .connecting:
            "正在建立仅供本次邀请使用的加密连接。"
        case .moveCloser(let distance):
            if let distance {
                "已确认设备距离约 \(Int(distance * 100)) 厘米，正在接收加密邀请。"
            } else {
                "已找到场主并建立加密连接，正在接收邀请。"
            }
        case .transferred:
            "邀请正在送达。"
        case .received:
            ""
        case .failed:
            "请确认两台手机都已允许“本地网络”和“附近交互”。"
        }
    }
}
