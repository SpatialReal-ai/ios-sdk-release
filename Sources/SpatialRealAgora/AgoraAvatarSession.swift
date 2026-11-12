import AgoraRtcKit
import AVFoundation
import Foundation
@_spi(RTC) import SpatialRealSDK
import SpatialRealAgoraSEI
import UIKit
import os

/// How the session gets into the Agora channel.
///
/// - `join`: the SDK creates its own engine (live-broadcasting profile, broadcaster role) and joins the channel.
///   Use this when your app only uses Agora to show the avatar.
/// - `shared`: your app already has an `AgoraRtcEngineKit` in the channel (one engine per app; for example an agent
///   app that joins itself to publish the microphone). The SDK takes over only the engine's encoded video frame
///   callback (`setEncodedVideoFrameDelegate`), mutes the avatar user's audio, and subscribes to its encoded frames
///   only. Joining and leaving, the microphone, and the engine delegate stay with your app. The channel must use the
///   live-broadcasting profile with the broadcaster role (the audience role adds 0.3–0.4 s of buffering).
///
/// `avatarUid` is required: the avatar's uid in the channel (the one your server-side agent chose when it started the
/// avatar, 1...4294967295). Video from any other uid is ignored. `uid` is the local uid; 0 lets Agora assign one.
public enum AgoraConnection {
    case join(appId: String, channel: String, token: String?, avatarUid: UInt, uid: UInt = 0)
    case shared(engine: AgoraRtcEngineKit, avatarUid: UInt)

    var avatarUid: UInt {
        switch self {
        case let .join(_, _, _, avatarUid, _): return avatarUid
        case let .shared(_, avatarUid): return avatarUid
        }
    }
}

/// Options for the Agora route. Your server-side agent asks SpatialReal to publish the avatar into an Agora channel.
/// The SEI of the avatar's H.264 video carries both the animation and the avatar's speech audio (Opus, with a sample
/// timeline). The SDK reads the SEI from the encoded frame callback and plays it in host mode, so audio and lip sync
/// share one sample clock. The avatar user's regular Agora audio track is not played.
///
/// - `mic` (`.join` only): `.required` (default) publishes the microphone on join and throws `mic-denied` without
///   permission; `.optional` skips publishing when permission is missing; `.manual` leaves the microphone alone so you
///   can drive it through `AgoraAvatarSession.engine`. With `.shared`, your app fully owns the microphone.
public struct AgoraAvatarSessionOptions {
    public let avatarId: String
    public let credential: String
    public let container: UIView
    public let agora: AgoraConnection
    public let mic: MicPolicy

    public init(avatarId: String, credential: String, container: UIView, agora: AgoraConnection, mic: MicPolicy = .required) {
        self.avatarId = avatarId
        self.credential = credential
        self.container = container
        self.agora = agora
        self.mic = mic
    }
}

public extension SpatialReal {
    /// Creates an Agora-route session. Avatar assets are downloaded here (as with `HostAvatarSession`). With `.join`
    /// the engine is created here; the channel is joined only in `start()`.
    func createSession(_ options: AgoraAvatarSessionOptions) async throws -> AgoraAvatarSession {
        let avatarUid = options.agora.avatarUid
        guard avatarUid > 0, avatarUid <= UInt(UInt32.max) else { throw SpatialRealError(.invalidParams, "`agora.avatarUid` must be 1...4294967295.") }
        if case let .join(appId, channel, _, _, _) = options.agora {
            guard !appId.isEmpty else { throw SpatialRealError(.invalidParams, "`agora.appId` is required.") }
            guard !channel.isEmpty else { throw SpatialRealError(.invalidParams, "`agora.channel` is required.") }
        }
        let format = try SessionAudioFormat(codec: .pcm16, sampleRate: AgoraAvatarSession.sampleRate)
        let host = try await createSession(HostAvatarSessionOptions(avatarId: options.avatarId, credential: options.credential, container: options.container, audioFormat: format))
        return AgoraAvatarSession(host: host, options: options)
    }
}

@MainActor public final class AgoraAvatarSession {
    /// Sample rate of the host-mode player: the Opus audio in the SEI is 48 kHz mono.
    public static let sampleRate = 48000
    static let joinTimeout: TimeInterval = 15

    /// The underlying Agora engine; with `.shared` it is the one you passed in. Use it for your own microphone, data and
    /// UI. Do not replace its encoded video frame delegate or unmute the avatar user's audio (the SDK owns both).
    /// With `.join`, the SDK is the engine's delegate.
    public let engine: AgoraRtcEngineKit

    private let host: HostAvatarSession
    private let options: AgoraAvatarSessionOptions
    private let ownsEngine: Bool
    private let bridge: AgoraBridge
    private var timeline: SourceTimeline!
    private var sink: HostSink!
    private let logger = Logger(subsystem: "ai.spatialreal", category: "AgoraAvatarSession")

    private var tickTask: Task<Void, Never>?
    private var joinWaiter: CheckedContinuation<Void, Error>?
    private var joined = false
    private var errorListeners: [UUID: (SpatialRealError) -> Void] = [:]
    private var configuredUid: UInt?

    // Diagnostic counters (printed periodically by the demo).
    var dbgSeiFrames = 0, dbgPayloads = 0, dbgBadPayloads = 0, dbgTurns = 0, dbgAudioYielded = 0, dbgFramesYielded = 0
    var dbgLastError: String?

    init(host: HostAvatarSession, options: AgoraAvatarSessionOptions) {
        self.host = host
        self.options = options
        bridge = AgoraBridge(avatarUid: options.agora.avatarUid)
        switch options.agora {
        case let .join(appId, _, _, _, _):
            let config = AgoraRtcEngineConfig()
            config.appId = appId
            config.channelProfile = .liveBroadcasting
            engine = AgoraRtcEngineKit.sharedEngine(with: config, delegate: bridge)
            ownsEngine = true
        case let .shared(engine, _):
            self.engine = engine
            ownsEngine = false
        }
        sink = HostSink(self)
        timeline = SourceTimeline(sink: sink, makeDecoder: { try RtcOpusDecoder() })
        bridge.session = self
        _ = host.onError { [weak self] e in self?.emit(e) }
    }

    public var state: SessionState { host.state }
    public var view: SessionView? { host.view }
    public var volume: Float {
        get { host.volume }
        set { host.volume = newValue }
    }

    /// The avatar's uid (`options.agora.avatarUid`).
    public var avatarUid: UInt { options.agora.avatarUid }

    public func onState(_ listener: @escaping (SessionStateChange) -> Void) -> @MainActor () -> Void { host.onState(listener) }

    public func onError(_ listener: @escaping (SpatialRealError) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        errorListeners[id] = listener
        return { [weak self] in self?.errorListeners[id] = nil }
    }

    private func emit(_ e: SpatialRealError) {
        for l in errorListeners.values { l(e) }
    }

    /// One-line status: bound uid, SEI and turn counters, source timeline stats. For demos and logs only; the format
    /// is not stable.
    public func debugSnapshot() -> String {
        let st = timeline.stats
        var s = "joined=\(joined) avatarUid=\(options.agora.avatarUid) sei=\(dbgSeiFrames) payloads=\(dbgPayloads) bad=\(dbgBadPayloads) "
        s += "streams=\(st.streams) turnsEnded=\(st.turnsEnded) serverInterrupts=\(st.serverInterrupts) stalled=\(st.stalled) "
        s += "packets=\(st.packets) concealed=\(st.concealedPackets) frames=\(st.frames) out(samples=\(st.samplesOut) frames=\(st.framesOut)) "
        s += "noAudio=\(st.withoutAudio) invalid=\(st.invalid) decodeErrors=\(st.decodeErrors) yielded(audio=\(dbgAudioYielded) frames=\(dbgFramesYielded)) host=\(host.state)"
        if let e = dbgLastError { s += " lastError=\(e)" }
        return s
    }

    /// Starts the host player, then takes over the encoded frame callback. With `.join`, joins the channel as
    /// broadcaster and publishes the microphone according to `mic`. If any step fails, the session returns to idle
    /// and the error is thrown.
    public func start() async throws {
        try await host.start()
        do {
            timeline.reset()
            sink.close()
            startTicks()
            guard engine.setEncodedVideoFrameDelegate(bridge) else {
                throw SpatialRealError(.connectionFailed, "Agora refused the encoded video frame delegate.")
            }
            configureAvatar(options.agora.avatarUid)
            if case let .join(_, channel, token, _, uid) = options.agora {
                try await join(channel: channel, token: token, uid: uid)
            }
        } catch {
            await teardownAgora()
            try? await host.end()
            if let e = error as? SpatialRealError { throw e }
            if error is CancellationError { throw SpatialRealError(.cancelled, "The in-flight operation was cancelled by end() or dispose().") }
            throw SpatialRealError(.connectionFailed, "Could not join the Agora channel: \(error.localizedDescription)", cause: error)
        }
    }

    /// Leaves the channel (`.join`) or releases the encoded frame callback (`.shared`), and ends playback.
    public func end() async throws {
        await teardownAgora()
        try await host.end()
    }

    /// Leaves the channel and releases the view. With `.join`, also destroys the engine the SDK created. The object
    /// cannot be used afterwards.
    public func dispose() async {
        await teardownAgora()
        await host.dispose()
        bridge.session = nil
        if ownsEngine { AgoraRtcEngineKit.destroy() }
    }

    /// Interrupts: drops unplayed audio and frames and returns to idle. Retransmitted data for the interrupted turn
    /// that arrives later does not restart it.
    public func interrupt() throws {
        try host.interrupt()
        timeline.interrupt()
        sink.close()
    }

    /// Turns publishing of the microphone into the channel on or off (`.join`; requires microphone permission).
    public func setMicrophone(enabled: Bool) async throws {
        if enabled, !(await Self.recordPermission()) {
            throw SpatialRealError(.micDenied, "Microphone permission was not granted.")
        }
        let o = AgoraRtcChannelMediaOptions()
        o.publishMicrophoneTrack = enabled
        let rc = engine.updateChannel(with: o)
        if rc != 0 { throw SpatialRealError(.connectionFailed, "Agora updateChannel failed (\(rc)).") }
    }

    // MARK: - Channel

    private func join(channel: String, token: String?, uid: UInt) async throws {
        var publishMic = false
        switch options.mic {
        case .manual: break
        case .required:
            guard await Self.recordPermission() else { throw SpatialRealError(.micDenied, "Microphone permission was not granted.") }
            publishMic = true
        case .optional:
            publishMic = await Self.recordPermission()
            if !publishMic { logger.warning("microphone not published (mic=optional): permission not granted") }
        @unknown default: break
        }
        engine.enableVideo()
        engine.setClientRole(.broadcaster)
        let o = AgoraRtcChannelMediaOptions()
        o.channelProfile = .liveBroadcasting
        o.clientRoleType = .broadcaster
        o.autoSubscribeAudio = true
        o.autoSubscribeVideo = true
        o.publishCameraTrack = false
        o.publishMicrophoneTrack = publishMic
        joined = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                joinWaiter = c
                let rc = engine.joinChannel(byToken: token, channelId: channel, uid: uid, mediaOptions: o, joinSuccess: nil)
                if rc != 0 { resumeJoin(.failure(SpatialRealError(.connectionFailed, "Agora joinChannel failed (\(rc))."))) }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.joinTimeout * 1_000_000_000))
                    self?.resumeJoin(.failure(SpatialRealError(.connectionFailed, "Timed out joining the Agora channel after \(Int(Self.joinTimeout))s.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeJoin(.failure(CancellationError())) }
        }
    }

    private func resumeJoin(_ result: Result<Void, Error>) {
        guard let c = joinWaiter else { return }
        joinWaiter = nil
        c.resume(with: result)
    }

    private static func recordPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            default: return await AVAudioApplication.requestRecordPermission()
            }
        }
        return await withCheckedContinuation { c in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
    }

    /// Avatar user: subscribe to encoded frames only (the picture itself carries no content, so it is not decoded)
    /// and mute its audio track (the audio travels in the SEI).
    private func configureAvatar(_ uid: UInt) {
        guard configuredUid != uid else { return }
        configuredUid = uid
        let o = AgoraVideoSubscriptionOptions()
        o.encodedFrameOnly = true
        let rc1 = engine.setRemoteVideoSubscriptionOptions(uid, options: o)
        let rc2 = engine.muteRemoteAudioStream(uid, mute: true)
        logger.info("avatar uid \(uid): encodedFrameOnly rc=\(rc1), muteRemoteAudio rc=\(rc2)")
    }

    private func teardownAgora() async {
        tickTask?.cancel(); tickTask = nil
        engine.setEncodedVideoFrameDelegate(nil)
        timeline.reset()
        sink.close()
        resumeJoin(.failure(CancellationError()))
        if ownsEngine {
            if joined { engine.leaveChannel(nil) }
        } else if let uid = configuredUid {
            // Shared engine: restore the avatar user's settings we changed.
            engine.muteRemoteAudioStream(uid, mute: false)
            engine.setRemoteVideoSubscriptionOptions(uid, options: AgoraVideoSubscriptionOptions())
        }
        configuredUid = nil
        joined = false
    }

    private func startTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                self.timeline.tick()
            }
        }
    }

    // MARK: - Events from the callback thread (already hopped to the main thread)

    fileprivate func handle(_ batch: AgoraBridge.Batch) {
        guard host.state == .live else { return }
        dbgSeiFrames += 1
        dbgPayloads += batch.payloads
        dbgBadPayloads += batch.malformed
        for (message, content) in batch.messages { timeline.accept(message, content: content) }
    }

    fileprivate func engineEvent(_ ev: AgoraBridge.EngineEvent) {
        switch ev {
        case .joined:
            joined = true
            resumeJoin(.success(()))
        case let .userJoined(uid):
            // The avatar (re)joined the channel: reapply its subscription options and mute.
            if uid == options.agora.avatarUid { configuredUid = nil; configureAvatar(uid) }
        case let .userOffline(uid):
            guard uid == options.agora.avatarUid else { return }
            // The avatar left: forget the streams; start over the next time it publishes.
            timeline.reset()
            sink.close()
            configuredUid = nil
        case let .error(code):
            dbgLastError = "agora error \(code)"
            if joinWaiter != nil {
                resumeJoin(.failure(SpatialRealError(.connectionFailed, "Agora error \(code) while joining the channel.")))
            }
        case let .connection(state, reason):
            if state == AgoraConnectionState.failed.rawValue {
                let e = SpatialRealError(.connectionFailed, "Agora connection failed (reason \(reason)).")
                if joinWaiter != nil { resumeJoin(.failure(e)); return }
                if host.state == .live {
                    emit(e)
                    Task { try? await self.end() }
                }
            }
        }
    }

    /// Host pipeline below the source timeline. The host session does not accept an empty chunk to open a turn, so
    /// a turn opens in the player only when its first audio chunk arrives. Frames that arrive earlier are buffered
    /// and fed right after that audio.
    @MainActor private final class HostSink: SourceTimelineSink {
        private unowned let session: AgoraAvatarSession
        private var audioStarted = false
        private var pending: [Data] = []

        init(_ session: AgoraAvatarSession) { self.session = session }

        func turnAudio(_ pcm: Data) {
            guard !pcm.isEmpty, session.host.state == .live else { return }
            do {
                try session.host.yieldAudioData(pcm, end: false)
                session.dbgAudioYielded += 1
            } catch {
                session.dbgLastError = "yieldAudioData: \(error.localizedDescription)"
                session.logger.warning("yieldAudioData: \(error.localizedDescription, privacy: .public)")
                return
            }
            if !audioStarted {
                audioStarted = true
                session.dbgTurns += 1
                if !pending.isEmpty {
                    let copy = pending
                    pending.removeAll()
                    turnFrames(copy)
                }
            }
        }

        func turnFrames(_ messages: [Data]) {
            if !audioStarted {
                pending.append(contentsOf: messages)
                return
            }
            guard session.host.state == .live else { return }
            do {
                try session.host.yieldFramesData(messages)
                session.dbgFramesYielded += messages.count
            } catch {
                session.dbgLastError = "yieldFramesData: \(error.localizedDescription)"
                session.logger.warning("yieldFramesData: \(error.localizedDescription, privacy: .public)")
            }
        }

        func turnEnd() {
            if audioStarted, session.host.state == .live {
                try? session.host.yieldAudioData(Data(), end: true)
            }
            close()
        }

        func interruptPlayback() {
            try? session.host.interrupt()
            close()
        }

        func close() {
            audioStarted = false
            pending.removeAll()
        }
    }
}

/// The half that runs on Agora's callback thread: reads the SEI, decodes the envelope and the protobuf (all
/// stateless pure functions), then hands the result to the session on the main thread. Also serves as the engine
/// delegate with `.join`.
final class AgoraBridge: NSObject, AgoraEncodedVideoFrameDelegate, AgoraRtcEngineDelegate, @unchecked Sendable {
    struct Batch: Sendable {
        var messages: [(RtcSourceMessage, Bool)] = []
        var payloads = 0
        var malformed = 0
    }

    enum EngineEvent: Sendable {
        case joined
        case userJoined(UInt)
        case userOffline(UInt)
        case error(Int)
        case connection(Int, Int)
    }

    @MainActor weak var session: AgoraAvatarSession?
    private let avatarUid: UInt

    init(avatarUid: UInt) {
        self.avatarUid = avatarUid
        super.init()
    }

    // MARK: AgoraEncodedVideoFrameDelegate

    func onEncodedVideoFrameReceived(_ videoData: Data, length: Int, info videoFrameInfo: AgoraEncodedVideoFrameInfo, channelId: String, uid: UInt) -> Bool {
        guard uid == avatarUid else { return true }
        let frame = length > 0 && length < videoData.count ? videoData.prefix(length) : videoData
        let sei = H264Sei.agoraPayloads(frame)
        guard !sei.payloads.isEmpty || sei.malformed > 0 else { return true }
        var batch = Batch()
        batch.malformed = sei.malformed
        batch.payloads = sei.payloads.count
        for payload in sei.payloads {
            switch SeiPacket.decode(payload) {
            case let .success(packet):
                for m in packet.messages {
                    if let decoded = RtcSourceMessage.decode(m) { batch.messages.append((decoded, !packet.isControl)) }
                }
            case .failure:
                batch.malformed += 1
            }
        }
        let b = batch
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.session?.handle(b) }
        }
        return true
    }

    // MARK: AgoraRtcEngineDelegate (`.join` only)

    private func post(_ ev: EngineEvent) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.session?.engineEvent(ev) }
        }
    }

    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) { post(.joined) }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) { post(.userJoined(uid)) }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) { post(.userOffline(uid)) }
    func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) { post(.error(errorCode.rawValue)) }
    func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        post(.connection(state.rawValue, reason.rawValue))
    }
}
