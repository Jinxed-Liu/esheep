import CryptoKit
import Foundation
import NearbyInteraction
import Network
import Observation

struct ProximityFarmInvitationPayload: Codable, Sendable, Equatable {
    let farmName: String
    let role: FarmRole
    let url: URL
    let inviteCode: String
    let expiresAt: Date
}

enum ProximityInvitationStatus: Sendable, Equatable {
    case idle
    case advertising
    case searching
    case connecting
    case moveCloser(distance: Float?)
    case transferred
    case received(ProximityFarmInvitationPayload)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "准备靠近邀请"
        case .advertising: "等待另一台手机"
        case .searching: "正在寻找邀请"
        case .connecting: "正在建立安全连接"
        case .moveCloser: "已找到对方，正在安全传送"
        case .transferred: "邀请已送达"
        case .received: "已收到邀请"
        case .failed: "靠近邀请未完成"
        }
    }
}

@MainActor
@Observable
final class ProximityInvitationController {
    private(set) var status: ProximityInvitationStatus = .idle

    private var transport: ProximityInvitationTransport?

    var receivedPayload: ProximityFarmInvitationPayload? {
        guard case .received(let payload) = status else { return nil }
        return payload
    }

    func startSending(_ payload: ProximityFarmInvitationPayload) {
        stop()
        let transport = ProximityInvitationTransport(
            mode: .sender(payload)
        ) { [weak self] event in
            Task { @MainActor in
                self?.status = event
            }
        }
        self.transport = transport
        status = .advertising
        transport.start()
    }

    func startReceiving() {
        stop()
        let transport = ProximityInvitationTransport(
            mode: .receiver
        ) { [weak self] event in
            Task { @MainActor in
                self?.status = event
            }
        }
        self.transport = transport
        status = .searching
        transport.start()
    }

    func stop() {
        transport?.stop()
        transport = nil
        if case .failed = status {
            return
        }
        status = .idle
    }
}

private final class NearbyInvitationDelegate: NSObject, NISessionDelegate, @unchecked Sendable {
    var onDistance: (@Sendable (Float) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let distance = nearbyObjects.first?.distance else { return }
        onDistance?(distance)
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        onFailure?(error.localizedDescription)
    }
}

private final class ProximityInvitationTransport: @unchecked Sendable {
    enum Mode: Sendable {
        case sender(ProximityFarmInvitationPayload)
        case receiver
    }

    private struct WireMessage: Codable {
        enum Kind: String, Codable {
            case hello
            case invitation
        }

        let kind: Kind
        let sessionID: String?
        let publicKey: String?
        let discoveryToken: String?
        let ciphertext: String?
    }

    private static let serviceType = "_esheep-invite._tcp"
    private static let maximumFrameBytes = 64 * 1024
    private let mode: Mode
    private let eventHandler: @Sendable (ProximityInvitationStatus) -> Void
    private let queue = DispatchQueue(label: "com.sheepfarm.esheep.invitation")
    private let agreementKey = P256.KeyAgreement.PrivateKey()
    private let nearbySession = NISession()
    private let nearbyDelegate = NearbyInvitationDelegate()

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var sessionID: String?
    private var symmetricKey: SymmetricKey?
    private var hasSentInvitation = false
    private var hasCompletedTransfer = false
    private var isStopped = false

    init(
        mode: Mode,
        eventHandler: @escaping @Sendable (ProximityInvitationStatus) -> Void
    ) {
        self.mode = mode
        self.eventHandler = eventHandler
        nearbySession.delegate = nearbyDelegate
        nearbySession.delegateQueue = queue
        nearbyDelegate.onDistance = { [weak self] distance in
            self?.handleDistance(distance)
        }
        nearbyDelegate.onFailure = { [weak self] message in
            self?.fail(message)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
                self.fail("当前设备不支持精确的附近交互，请改用二维码。")
                return
            }
            switch self.mode {
            case .sender:
                self.startAdvertising()
            case .receiver:
                self.startBrowsing()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.listener?.cancel()
            self.browser?.cancel()
            self.connection?.cancel()
            self.nearbySession.invalidate()
            self.listener = nil
            self.browser = nil
            self.connection = nil
        }
    }

    private func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func startAdvertising() {
        do {
            let listener = try NWListener(using: parameters())
            let sessionID = UUID().uuidString.lowercased()
            self.sessionID = sessionID
            listener.service = NWListener.Service(
                name: "eSheep-\(sessionID.prefix(6))",
                type: Self.serviceType
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.fail(error.localizedDescription)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.connection == nil else {
                    connection.cancel()
                    return
                }
                self.listener?.cancel()
                self.listener = nil
                self.configure(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
            eventHandler(.advertising)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters()
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.fail(error.localizedDescription)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self,
                  self.connection == nil,
                  let endpoint = results.first?.endpoint else {
                return
            }
            self.browser?.cancel()
            self.browser = nil
            self.configure(NWConnection(to: endpoint, using: self.parameters()))
        }
        self.browser = browser
        browser.start(queue: queue)
        eventHandler(.searching)
    }

    private func configure(_ connection: NWConnection) {
        self.connection = connection
        eventHandler(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveFrame()
                if case .sender = self.mode {
                    self.sendHello()
                }
            case .failed(let error):
                self.fail(error.localizedDescription)
            case .cancelled:
                if !self.hasSentInvitation && !self.isStopped {
                    self.fail("附近连接已断开，请重试。")
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHello() {
        guard let token = nearbySession.discoveryToken,
              let tokenData = try? NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
              ) else {
            fail("无法创建附近交互凭证。")
            return
        }
        let message = WireMessage(
            kind: .hello,
            sessionID: sessionID,
            publicKey: agreementKey.publicKey.x963Representation.base64EncodedString(),
            discoveryToken: tokenData.base64EncodedString(),
            ciphertext: nil
        )
        send(message)
    }

    private func receiveFrame() {
        connection?.receive(
            minimumIncompleteLength: 4,
            maximumLength: 4
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            guard let data, data.count == 4 else {
                if isComplete { self.fail("附近连接提前结束。") }
                return
            }
            let length = Int(data.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).bigEndian
            })
            guard length > 0, length <= Self.maximumFrameBytes else {
                self.fail("收到的附近邀请数据无效。")
                return
            }
            self.receivePayload(length: length)
        }
    }

    private func receivePayload(length: Int) {
        connection?.receive(
            minimumIncompleteLength: length,
            maximumLength: length
        ) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            guard let data, data.count == length,
                  let message = try? JSONDecoder().decode(WireMessage.self, from: data) else {
                self.fail("无法解析附近邀请。")
                return
            }
            self.handle(message)
            if !self.isStopped {
                self.receiveFrame()
            }
        }
    }

    private func handle(_ message: WireMessage) {
        switch message.kind {
        case .hello:
            handleHello(message)
        case .invitation:
            handleInvitation(message)
        }
    }

    private func handleHello(_ message: WireMessage) {
        guard let publicKey = message.publicKey,
              let publicKeyData = Data(base64Encoded: publicKey),
              let peerKey = try? P256.KeyAgreement.PublicKey(
                x963Representation: publicKeyData
              ),
              let tokenString = message.discoveryToken,
              let tokenData = Data(base64Encoded: tokenString),
              let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self,
                from: tokenData
              ) else {
            fail("附近设备凭证无效。")
            return
        }

        if sessionID == nil {
            sessionID = message.sessionID
        }
        guard let sessionID, !sessionID.isEmpty else {
            fail("附近邀请会话无效。")
            return
        }

        do {
            let secret = try agreementKey.sharedSecretFromKeyAgreement(with: peerKey)
            symmetricKey = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: Data(sessionID.utf8),
                sharedInfo: Data("eSheepNext.proximity.invite.v1".utf8),
                outputByteCount: 32
            )
        } catch {
            fail("无法建立邀请加密通道。")
            return
        }

        nearbySession.run(NINearbyPeerConfiguration(peerToken: peerToken))
        eventHandler(.moveCloser(distance: nil))

        if case .receiver = mode {
            sendHello()
        } else {
            sendInvitationIfReady()
        }
    }

    private func handleDistance(_ distance: Float) {
        guard !isStopped, !hasCompletedTransfer else { return }
        eventHandler(.moveCloser(distance: distance))
    }

    private func sendInvitationIfReady() {
        guard case .sender(let payload) = mode,
              !hasSentInvitation,
              let symmetricKey else { return }
        do {
            let plaintext = try JSONEncoder().encode(payload)
            let sealed = try ChaChaPoly.seal(
                plaintext,
                using: symmetricKey,
                authenticating: Data((sessionID ?? "").utf8)
            )
            hasSentInvitation = true
            send(WireMessage(
                kind: .invitation,
                sessionID: nil,
                publicKey: nil,
                discoveryToken: nil,
                ciphertext: sealed.combined.base64EncodedString()
            )) { [weak self] in
                guard let self, !self.isStopped else { return }
                self.hasCompletedTransfer = true
                self.eventHandler(.transferred)
            }
        } catch {
            fail("邀请加密失败。")
        }
    }

    private func handleInvitation(_ message: WireMessage) {
        guard case .receiver = mode,
              let symmetricKey,
              let ciphertext = message.ciphertext,
              let combined = Data(base64Encoded: ciphertext) else {
            fail("收到的邀请缺少加密内容。")
            return
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            let plaintext = try ChaChaPoly.open(
                box,
                using: symmetricKey,
                authenticating: Data((sessionID ?? "").utf8)
            )
            let payload = try JSONDecoder().decode(
                ProximityFarmInvitationPayload.self,
                from: plaintext
            )
            hasCompletedTransfer = true
            eventHandler(.received(payload))
        } catch {
            fail("附近邀请校验失败。")
        }
    }

    private func send(
        _ message: WireMessage,
        onSent: (@Sendable () -> Void)? = nil
    ) {
        guard let connection,
              let payload = try? JSONEncoder().encode(message),
              payload.count <= Self.maximumFrameBytes else {
            fail("无法编码附近邀请。")
            return
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        connection.send(
            content: frame,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.fail(error.localizedDescription)
                } else {
                    onSent?()
                }
            }
        )
    }

    private func fail(_ message: String) {
        guard !isStopped, !hasCompletedTransfer else { return }
        eventHandler(.failed(message))
        listener?.cancel()
        browser?.cancel()
        connection?.cancel()
        nearbySession.invalidate()
        listener = nil
        browser = nil
        connection = nil
        isStopped = true
    }
}
