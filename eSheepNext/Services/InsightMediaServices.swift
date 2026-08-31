import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct PendingInsightImage: Identifiable, Sendable, Equatable {
    let id: UUID
    let data: Data
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let digest: String

    init(
        id: UUID = UUID(),
        data: Data,
        mimeType: String,
        pixelWidth: Int,
        pixelHeight: Int,
        digest: String
    ) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.digest = digest
    }
}

struct PendingInsightAudio: Sendable, Equatable {
    let data: Data
    let mimeType: String
    let duration: TimeInterval
    let waveformSamples: [Float]
}

struct StoredInsightAudio: Sendable, Equatable {
    let messageID: UUID
    let data: Data
    let mimeType: String
    let duration: TimeInterval
    let waveformSamples: [Float]

    var pendingAudio: PendingInsightAudio {
        PendingInsightAudio(
            data: data,
            mimeType: mimeType,
            duration: duration,
            waveformSamples: waveformSamples
        )
    }
}

enum InsightVoicePrivacyPreference {
    // Audio is sent only for the user's current request. Keeping a replayable
    // local copy is optional and therefore disabled by default.
    static let defaultRetainsSentAudio = false

    static func retainsSentAudio(
        for accountID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        AppPreferenceStorage.bool(
            forKey: storageKey(for: accountID),
            default: defaultRetainsSentAudio,
            defaults: defaults
        )
    }

    static func setRetainsSentAudio(
        _ retainsSentAudio: Bool,
        for accountID: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(retainsSentAudio, forKey: storageKey(for: accountID))
    }

    static func storageKey(for accountID: UUID) -> String {
        "insight.privacy.retain-sent-audio.\(accountID.uuidString.lowercased())"
    }
}

actor InsightLocalAudioStore {
    static let shared = InsightLocalAudioStore()

    private struct Metadata: Codable {
        let messageID: UUID
        let conversationID: UUID
        let accountID: UUID
        let mimeType: String
        let duration: TimeInterval
        let waveformSamples: [Float]
        let digest: String
        let createdAt: Date
    }

    private let rootDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "InsightAudio", directoryHint: .isDirectory)
    }

    func save(
        _ audio: PendingInsightAudio,
        messageID: UUID,
        conversationID: UUID,
        accountID: UUID
    ) throws {
        let directory = conversationDirectory(
            accountID: accountID,
            conversationID: conversationID
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        excludeFromBackup(directory)

        let digest = SHA256.hash(data: audio.data)
            .map { String(format: "%02x", $0) }
            .joined()
        let metadata = Metadata(
            messageID: messageID,
            conversationID: conversationID,
            accountID: accountID,
            mimeType: audio.mimeType,
            duration: audio.duration,
            waveformSamples: audio.waveformSamples,
            digest: digest,
            createdAt: .now
        )
        try audio.data.write(to: audioURL(messageID: messageID, directory: directory), options: .atomic)
        try encoder.encode(metadata).write(
            to: metadataURL(messageID: messageID, directory: directory),
            options: .atomic
        )
        protectFile(audioURL(messageID: messageID, directory: directory))
        protectFile(metadataURL(messageID: messageID, directory: directory))
    }

    func load(
        messageID: UUID,
        conversationID: UUID,
        accountID: UUID
    ) throws -> StoredInsightAudio? {
        let directory = conversationDirectory(
            accountID: accountID,
            conversationID: conversationID
        )
        let audioURL = audioURL(messageID: messageID, directory: directory)
        let metadataURL = metadataURL(messageID: messageID, directory: directory)
        guard FileManager.default.fileExists(atPath: audioURL.path),
              FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        let metadata = try decoder.decode(Metadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.messageID == messageID,
              metadata.conversationID == conversationID,
              metadata.accountID == accountID else {
            return nil
        }
        let data = try Data(contentsOf: audioURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == metadata.digest else {
            return nil
        }
        return StoredInsightAudio(
            messageID: messageID,
            data: data,
            mimeType: metadata.mimeType,
            duration: metadata.duration,
            waveformSamples: metadata.waveformSamples
        )
    }

    func removeConversation(conversationID: UUID, accountID: UUID) throws {
        let directory = conversationDirectory(
            accountID: accountID,
            conversationID: conversationID
        )
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func conversationDirectory(accountID: UUID, conversationID: UUID) -> URL {
        rootDirectory
            .appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: conversationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func audioURL(messageID: UUID, directory: URL) -> URL {
        directory
            .appending(path: messageID.uuidString.lowercased())
            .appendingPathExtension("m4a")
    }

    private func metadataURL(messageID: UUID, directory: URL) -> URL {
        directory
            .appending(path: messageID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private func excludeFromBackup(_ directory: URL) {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private func protectFile(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}

enum InsightMediaError: LocalizedError {
    case invalidImage
    case imageEncodingFailed
    case microphonePermissionDenied
    case audioRecordingFailed
    case audioTooLarge
    case audioStorageFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "无法读取所选图片。"
        case .imageEncodingFailed:
            "图片优化失败，请重新选择。"
        case .microphonePermissionDenied:
            "未获得麦克风权限。"
        case .audioRecordingFailed:
            "录音没有完成；本条语音未发送。"
        case .audioTooLarge:
            "录音文件过大；请缩短录音后再发送。"
        case .audioStorageFailed:
            "无法保存本机语音消息；本条语音未发送。"
        }
    }
}

enum InsightImageOptimizer {
    static let maximumDimension = 1_600

    static func optimize(_ sourceData: Data) throws -> PendingInsightImage {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw InsightMediaError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw InsightMediaError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw InsightMediaError.imageEncodingFailed
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw InsightMediaError.imageEncodingFailed
        }
        let data = output as Data
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PendingInsightImage(
            data: data,
            mimeType: "image/jpeg",
            pixelWidth: image.width,
            pixelHeight: image.height,
            digest: digest
        )
    }
}

@MainActor
@Observable
final class InsightAudioRecorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var duration: TimeInterval = 0
    private(set) var waveformSamples: [Float] = []
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var temporaryURL: URL?
    private var meterTask: Task<Void, Never>?

    func start() async {
        guard !isRecording else { return }
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw InsightMediaError.microphonePermissionDenied
            }
            errorMessage = nil
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            let url = FileManager.default.temporaryDirectory
                .appending(path: "esheep-insight-\(UUID().uuidString.lowercased())")
                .appendingPathExtension("m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else { throw InsightMediaError.audioRecordingFailed }
            self.recorder = recorder
            temporaryURL = url
            startedAt = .now
            duration = 0
            waveformSamples = []
            isRecording = true
            startMetering()
        } catch {
            discard()
            errorMessage = error.localizedDescription
        }
    }

    func finish() throws -> PendingInsightAudio? {
        guard let recorder, let temporaryURL else { return nil }
        meterTask?.cancel()
        meterTask = nil
        recorder.updateMeters()
        appendCurrentLevel(from: recorder)
        let recordedDuration = recorder.currentTime
        let recordedSamples = waveformSamples
        recorder.stop()
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            self.recorder = nil
            self.temporaryURL = nil
            self.startedAt = nil
            self.isRecording = false
            self.duration = 0
            self.waveformSamples = []
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        guard !data.isEmpty else { throw InsightMediaError.audioRecordingFailed }
        guard data.base64EncodedData().count <= 50 * 1_024 * 1_024 else {
            throw InsightMediaError.audioTooLarge
        }
        return PendingInsightAudio(
            data: data,
            mimeType: "audio/mp4",
            duration: recordedDuration,
            waveformSamples: recordedSamples
        )
    }

    func discard() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        recorder = nil
        temporaryURL = nil
        startedAt = nil
        isRecording = false
        duration = 0
        waveformSamples = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isRecording, let recorder = self.recorder else { return }
                recorder.updateMeters()
                self.duration = recorder.currentTime
                self.appendCurrentLevel(from: recorder)
            }
        }
    }

    private func appendCurrentLevel(from recorder: AVAudioRecorder) {
        let decibels = recorder.averagePower(forChannel: 0)
        let normalized = min(1, max(0.08, pow(10, decibels / 32)))
        waveformSamples.append(normalized)
        if waveformSamples.count > 52 {
            waveformSamples.removeFirst(waveformSamples.count - 52)
        }
    }
}

@MainActor
@Observable
final class InsightAudioPreviewPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var currentAudioData: Data?
    private var progressTask: Task<Void, Never>?

    func toggle(_ audio: PendingInsightAudio) {
        if currentAudioData != audio.data {
            stop()
        }
        if isPlaying {
            player?.pause()
            isPlaying = false
            progressTask?.cancel()
            progressTask = nil
            return
        }

        do {
            if player == nil {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
                try audioSession.setActive(true)
                player = try AVAudioPlayer(data: audio.data)
                currentAudioData = audio.data
                player?.prepareToPlay()
            }
            guard player?.play() == true else {
                throw InsightMediaError.audioRecordingFailed
            }
            isPlaying = true
            monitorProgress()
        } catch {
            stop()
        }
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        currentAudioData = nil
        currentTime = 0
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func monitorProgress() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.stop()
                    return
                }
            }
        }
    }
}
