import AVFoundation
import Foundation
import LiveKit
import SpatialRealSDK
import UIKit
import os

/// 进哪个房间。`avatarIdentity` 不给时,认 identity 为 `spatialreal-avatar` 或带 `lk.publish_on_behalf` 属性的参与者。
public struct LiveKitConnection: Sendable {
    public let url: String
    public let token: String
    public let avatarIdentity: String?

    public init(url: String, token: String, avatarIdentity: String? = nil) {
        self.url = url
        self.token = token
        self.avatarIdentity = avatarIdentity
    }
}

/// LiveKit 路由:你的 agent 在 LiveKit 房间里,形象由 egress 发布进同一个房间,
/// 本端只订阅它的音频轨和动画数据通道,交给宿主模式播放。
///
/// - `mic`:`.required`(默认)start() 时开麦,失败抛 `mic-denied`;`.optional` 失败只记日志;`.manual` 不碰麦,自己用 `LiveKitAvatarSession.room`。
public struct LiveKitAvatarSessionOptions {
    public let avatarId: String
    public let credential: String
    public let container: UIView
    public let livekit: LiveKitConnection
    public let mic: MicPolicy

    public init(avatarId: String, credential: String, container: UIView, livekit: LiveKitConnection, mic: MicPolicy = .required) {
        self.avatarId = avatarId
        self.credential = credential
        self.container = container
        self.livekit = livekit
        self.mic = mic
    }
}

public extension SpatialReal {
    /// 创建 LiveKit 路由会话。形象资源在这里下载(和 HostAvatarSession 一样),房间在 `start()` 时才连。
    func createSession(_ options: LiveKitAvatarSessionOptions) async throws -> LiveKitAvatarSession {
        guard !options.livekit.url.isEmpty else { throw SpatialRealError(.invalidParams, "`livekit.url` is required.") }
        guard !options.livekit.token.isEmpty else { throw SpatialRealError(.invalidParams, "`livekit.token` is required.") }
        let format = try SessionAudioFormat(codec: .pcm16, sampleRate: LiveKitAvatarSession.sampleRate)
        let host = try await createSession(HostAvatarSessionOptions(avatarId: options.avatarId, credential: options.credential, container: options.container, audioFormat: format))
        return LiveKitAvatarSession(host: host, options: options)
    }
}

@MainActor public final class LiveKitAvatarSession {
    /// 宿主模式播放器的采样率;WebRTC 解码出的 Opus 就是 48 kHz,不用重采样。
    public static let sampleRate = 48000
    public static let defaultAvatarIdentity = "spatialreal-avatar"
    static let animationTopic = "spatialreal-animation"
    static let animationTrack = "egress-animation"
    static let audioTrack = "egress-audio"
    static let publishOnBehalf = "lk.publish_on_behalf"
    /// 门开着却 3 s 没有任何动画包:当作这一轮丢了,关门。
    static let stallSeconds: TimeInterval = 3

    /// 底下的 LiveKit `Room`:给你自己的数据、麦克风和 UI 用,别用它播形象的音频(SDK 已接管)。
    public let room: Room

    private let host: HostAvatarSession
    private let options: LiveKitAvatarSessionOptions
    private let bridge: RoomBridge
    private let stream: AsyncStream<RoomEvent>
    private let decoder = AnimationPacketDecoder()
    private var gate: TurnGate!
    private let logger = Logger(subsystem: "ai.spatialreal", category: "LiveKitAvatarSession")

    private var loopTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var boundIdentity: String?
    private var audioTrack: RemoteAudioTrack?
    private var lastPacketAt: TimeInterval = 0
    private var errorListeners: [UUID: (SpatialRealError) -> Void] = [:]

    init(host: HostAvatarSession, options: LiveKitAvatarSessionOptions) {
        self.host = host
        self.options = options
        var cont: AsyncStream<RoomEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        bridge = RoomBridge(continuation: cont, sampleRate: Self.sampleRate)
        room = Room(delegate: bridge)
        gate = TurnGate(sink: HostSink(self))
        _ = host.onError { [weak self] e in self?.emit(e) }
    }

    public var state: SessionState { host.state }
    public var view: SessionView? { host.view }
    public var volume: Float {
        get { host.volume }
        set { host.volume = newValue }
    }

    public func onState(_ listener: @escaping (SessionStateChange) -> Void) -> @MainActor () -> Void { host.onState(listener) }

    public func onError(_ listener: @escaping (SpatialRealError) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        errorListeners[id] = listener
        return { [weak self] in self?.errorListeners[id] = nil }
    }

    private func emit(_ e: SpatialRealError) {
        for l in errorListeners.values { l(e) }
    }

    /// 先起宿主播放器,再连房间、按 `mic` 开麦。任一步失败都退回 idle 并抛错。
    public func start() async throws {
        try await host.start()
        do {
            decoder.reset()
            startLoops()
            try await room.connect(url: options.livekit.url, token: options.livekit.token)
            await unsubscribeAnimationVideo()
            try await applyMicPolicy()
        } catch {
            await teardownRoom()
            try? await host.end()
            if let e = error as? SpatialRealError { throw e }
            if error is CancellationError { throw SpatialRealError(.cancelled, "The in-flight operation was cancelled by end() or dispose().") }
            throw SpatialRealError(.connectionFailed, "Could not connect to the LiveKit room: \(error.localizedDescription)", cause: error)
        }
    }

    /// 离开房间,结束播放。
    public func end() async throws {
        await teardownRoom()
        try await host.end()
    }

    /// 离开房间、释放视图。之后这个对象不能再用。
    public func dispose() async {
        await teardownRoom()
        await host.dispose()
        bridge.finish()
    }

    /// 打断:丢掉未播的音频和帧,回到待机;被切断那句的尾巴不会再把回合打开。
    public func interrupt() throws {
        try host.interrupt()
        gate.interrupt()
    }

    /// 开/关发到房间里的麦克风(需要麦克风权限)。
    public func setMicrophone(enabled: Bool) async throws {
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    // MARK: - 房间事件(统一在主线程按到达顺序处理)

    private func startLoops() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            for await ev in self?.stream ?? AsyncStream { $0.finish() } {
                guard let self else { return }
                self.handle(ev)
            }
        }
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.gate.isOpen, Date().timeIntervalSince1970 - self.lastPacketAt > Self.stallSeconds { self.gate.reset() }
            }
        }
    }

    private func identity(_ p: Participant?) -> String? { p?.identity?.stringValue }

    private func isAvatar(_ p: Participant?) -> Bool {
        guard let p, let id = identity(p) else { return false }
        if let wanted = options.livekit.avatarIdentity { return id == wanted }
        return id == Self.defaultAvatarIdentity || p.attributes[Self.publishOnBehalf] != nil
    }

    private func isBoundOrFree(_ p: Participant?) -> Bool {
        guard let bound = boundIdentity else { return true }
        return identity(p) == bound
    }

    private func handle(_ ev: RoomEvent) {
        switch ev {
        case let .audio(pcm):
            gate.audio(pcm)
        case let .data(participant, topic, data):
            guard topic == Self.animationTopic, isAvatar(participant), isBoundOrFree(participant) else { return }
            if boundIdentity == nil { boundIdentity = identity(participant) }
            lastPacketAt = Date().timeIntervalSince1970
            if let d = decoder.decode(data) {
                if d.resync { gate.reset() }
                gate.frame(d.flags, d.messages)
            }
        case let .subscribed(participant, publication):
            guard isAvatar(participant), isBoundOrFree(participant) else { return }
            if let t = publication.track as? RemoteAudioTrack, publication.name == Self.audioTrack || publication.kind == .audio {
                guard audioTrack == nil else { return }
                boundIdentity = identity(participant)
                t.volume = 0 // 这条轨的播放由宿主模式播放器负责,WebRTC 自己的播放静掉
                t.add(audioRenderer: bridge)
                audioTrack = t
                logger.info("bound avatar '\(self.boundIdentity ?? "", privacy: .public)' audio track '\(publication.name, privacy: .public)'")
            } else if publication.kind == .video, publication.name == Self.animationTrack {
                Task { try? await publication.set(subscribed: false) } // 动画走数据通道;伪 VP8 视频轨退订,省带宽
            }
        case let .published(participant, publication):
            if isAvatar(participant), publication.name == Self.animationTrack {
                Task { try? await publication.set(subscribed: false) }
            }
        case let .unsubscribed(publication):
            if let t = publication.track as? RemoteAudioTrack, t === audioTrack {
                detachAudio()
                gate.reset()
                decoder.reset()
            }
        case let .participantLeft(participant):
            if identity(participant) == boundIdentity {
                detachAudio()
                boundIdentity = nil
                gate.reset()
                decoder.reset()
            }
        case let .disconnected(error):
            if host.state == .live {
                let detail = error.map { ": \($0.localizedDescription)" } ?? ""
                emit(SpatialRealError(.connectionFailed, "LiveKit room disconnected\(detail).", cause: error))
                Task { try? await self.end() }
            }
        }
    }

    private func unsubscribeAnimationVideo() async {
        for p in room.remoteParticipants.values where isAvatar(p) {
            for pub in p.trackPublications.values where pub.name == Self.animationTrack {
                if let r = pub as? RemoteTrackPublication { try? await r.set(subscribed: false) }
            }
        }
    }

    private func applyMicPolicy() async throws {
        if options.mic == .manual { return }
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if options.mic == .required { throw SpatialRealError(.micDenied, "Could not publish the microphone: \(error.localizedDescription)", cause: error) }
            logger.warning("microphone not published (mic=optional): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func detachAudio() {
        if let t = audioTrack { t.remove(audioRenderer: bridge) }
        audioTrack = nil
        bridge.flushAudio()
    }

    private func teardownRoom() async {
        detachAudio()
        boundIdentity = nil
        stallTask?.cancel(); stallTask = nil
        loopTask?.cancel(); loopTask = nil
        gate.reset()
        await room.disconnect()
    }

    /// 门限下面的宿主管线。iOS 的宿主会话不接受"空块开回合",所以回合在第一块音频到达时才在
    /// 播放器里开;之前到的帧先攒着,音频一到就跟在后面喂进去。
    @MainActor private final class HostSink: TurnSink {
        private unowned let session: LiveKitAvatarSession
        private var audioStarted = false
        private var pending: [Data] = []

        init(_ session: LiveKitAvatarSession) { self.session = session }

        func open() {
            audioStarted = false
            pending.removeAll()
        }

        func audio(_ pcm: Data, end: Bool) {
            if pcm.isEmpty, !end || !audioStarted { return }
            guard session.host.state == .live else { return }
            do {
                try session.host.yieldAudioData(pcm, end: end)
            } catch {
                session.logger.warning("yieldAudioData: \(error.localizedDescription, privacy: .public)")
                return
            }
            if !audioStarted {
                audioStarted = true
                if !pending.isEmpty {
                    let copy = pending
                    pending.removeAll()
                    frames(copy)
                }
            }
        }

        func frames(_ messages: [Data]) {
            if !audioStarted {
                pending.append(contentsOf: messages)
                if pending.count > 200 { pending.removeFirst(pending.count - 200) }
                return
            }
            guard session.host.state == .live else { return }
            do { try session.host.yieldFramesData(messages) } catch { session.logger.warning("yieldFramesData: \(error.localizedDescription, privacy: .public)") }
        }

        func close() {
            audioStarted = false
            pending.removeAll()
        }
    }
}

/// 从 LiveKit 的回调线程把事件送到主线程的流;同时是远端音频轨的渲染器(抽 PCM)。
enum RoomEvent: @unchecked Sendable {
    case audio(Data)
    case data(RemoteParticipant?, String, Data)
    case subscribed(RemoteParticipant, RemoteTrackPublication)
    case published(RemoteParticipant, RemoteTrackPublication)
    case unsubscribed(RemoteTrackPublication)
    case participantLeft(RemoteParticipant)
    case disconnected(LiveKitError?)
}

final class RoomBridge: NSObject, RoomDelegate, AudioRenderer, @unchecked Sendable {
    private let continuation: AsyncStream<RoomEvent>.Continuation
    private let converter: PcmConverter

    init(continuation: AsyncStream<RoomEvent>.Continuation, sampleRate: Int) {
        self.continuation = continuation
        converter = PcmConverter(targetRate: sampleRate) { chunk in continuation.yield(.audio(chunk)) }
        super.init()
    }

    func flushAudio() { converter.flush() }
    func finish() { continuation.finish() }

    // AudioRenderer
    func render(pcmBuffer: AVAudioPCMBuffer) { converter.push(pcmBuffer) }

    // RoomDelegate
    func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        continuation.yield(.subscribed(participant, publication))
    }

    func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        continuation.yield(.unsubscribed(publication))
    }

    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        continuation.yield(.published(participant, publication))
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        continuation.yield(.data(participant, topic, data))
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        continuation.yield(.participantLeft(participant))
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        continuation.yield(.disconnected(error))
    }
}
