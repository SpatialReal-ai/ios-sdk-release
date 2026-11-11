import AgoraRtcKit
import AVFoundation
import Foundation
@_spi(RTC) import SpatialRealSDK
import SpatialRealAgoraSEI
import UIKit
import os

/// 怎么进 Agora 频道。
///
/// - `join`:SDK 自己建引擎(直播场景、主播角色)并加入频道。适合只用 Agora 看形象的 app。
/// - `shared`:app 已经有一个在频道里的 `AgoraRtcEngineKit`(一个 app 一个引擎;agent 类 app 自己加入以发布麦克风)。
///   SDK 只接管这个引擎的编码视频帧回调(`setEncodedVideoFrameDelegate`),静掉形象那一路的音频、只要它的编码帧;
///   进出频道、麦克风、引擎的 delegate 都还是 app 的。频道场景须是直播、角色主播(观众会多 0.3–0.4 s 缓冲)。
///
/// `avatarUid` 必填:形象在频道里的 uid(你的服务端 agent 起形象时选定的那个,1...4294967295);其他 uid 的视频一概不看
/// (对齐 Web `agora.avatarUid` / Android)。`uid` 是本端的 uid,0 = 让 Agora 分配。
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

/// Agora 路由:你的服务端 agent(如 TEN 扩展)让后端把形象发布进 Agora 频道,形象那路 H.264 视频的 SEI 里
/// 同时带着动画和形象说话的音频(Opus,带样本时间线)。本端从编码帧回调里读 SEI,交给宿主模式播放,
/// 音频和嘴型在同一条样本时钟上(不播 Agora 自己那一路音频)。
///
/// - `mic`(只对 `.join` 有效):`.required`(默认)加入时发布麦克风,没有权限抛 `mic-denied`;`.optional` 没权限就不发布;
///   `.manual` 不碰麦,自己用 `AgoraAvatarSession.engine`。`.shared` 时麦克风完全由 app 管。
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
    /// 创建 Agora 路由会话。形象资源在这里下载(和 HostAvatarSession 一样);`.join` 时引擎在这里建好,频道在 `start()` 时才进。
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
    /// 宿主模式播放器的采样率:SEI 里的 Opus 是 48 kHz 单声道。
    public static let sampleRate = 48000
    static let joinTimeout: TimeInterval = 15

    /// 底下的 Agora 引擎:`.shared` 时就是你传进来的那个。给你自己的麦克风、数据和 UI 用;
    /// 别替换它的编码视频帧回调,也别打开形象那一路的音频(SDK 已接管)。`.join` 时 SDK 是它的 delegate。
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

    // 诊断计数(demo 定时打印)
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

    /// 形象的 uid(`options.agora.avatarUid`)。
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

    /// 一行状态:绑定的 uid、SEI / 回合计数、源时间线统计。给 demo / 日志用,格式不保证稳定。
    public func debugSnapshot() -> String {
        let st = timeline.stats
        var s = "joined=\(joined) avatarUid=\(options.agora.avatarUid) sei=\(dbgSeiFrames) payloads=\(dbgPayloads) bad=\(dbgBadPayloads) "
        s += "streams=\(st.streams) turnsEnded=\(st.turnsEnded) serverInterrupts=\(st.serverInterrupts) stalled=\(st.stalled) "
        s += "packets=\(st.packets) concealed=\(st.concealedPackets) frames=\(st.frames) out(samples=\(st.samplesOut) frames=\(st.framesOut)) "
        s += "noAudio=\(st.withoutAudio) invalid=\(st.invalid) decodeErrors=\(st.decodeErrors) yielded(audio=\(dbgAudioYielded) frames=\(dbgFramesYielded)) host=\(host.state)"
        if let e = dbgLastError { s += " lastError=\(e)" }
        return s
    }

    /// 先起宿主播放器,再接管编码帧回调;`.join` 时加入频道(主播角色),按 `mic` 发布麦克风。任一步失败都退回 idle 并抛错。
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

    /// 离开频道(`.join`)/ 交还编码帧回调(`.shared`),结束播放。
    public func end() async throws {
        await teardownAgora()
        try await host.end()
    }

    /// 离开频道、释放视图;`.join` 时销毁 SDK 建的引擎。之后这个对象不能再用。
    public func dispose() async {
        await teardownAgora()
        await host.dispose()
        bridge.session = nil
        if ownsEngine { AgoraRtcEngineKit.destroy() }
    }

    /// 打断:丢掉未播的音频和帧,回到待机;被切断那句后面重复到达的数据不会再把它开起来。
    public func interrupt() throws {
        try host.interrupt()
        timeline.interrupt()
        sink.close()
    }

    /// 开/关发布到频道里的麦克风(`.join`;需要麦克风权限)。
    public func setMicrophone(enabled: Bool) async throws {
        if enabled, !(await Self.recordPermission()) {
            throw SpatialRealError(.micDenied, "Microphone permission was not granted.")
        }
        let o = AgoraRtcChannelMediaOptions()
        o.publishMicrophoneTrack = enabled
        let rc = engine.updateChannel(with: o)
        if rc != 0 { throw SpatialRealError(.connectionFailed, "Agora updateChannel failed (\(rc)).") }
    }

    // MARK: - 频道

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

    /// 形象那一路:只要编码帧(不解码那张无意义的画面),它自己的音频静掉(音频在 SEI 里)。
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
            // 共享引擎:把我们改过的那一路还原
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

    // MARK: - 来自回调线程的事件(都已切到主线程)

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
            // 形象(重新)进频道:再设一次它那一路的订阅选项和静音
            if uid == options.agora.avatarUid { configuredUid = nil; configureAvatar(uid) }
        case let .userOffline(uid):
            guard uid == options.agora.avatarUid else { return }
            // 形象走了:正在收的那一轮按已有的收尾,忘掉流;下次它再发布时重新开始
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

    /// 源时间线下面的宿主管线:iOS 的宿主会话不接受"空块开回合",回合在第一块音频到达时才在播放器里开;
    /// 之前到的帧先攒着,音频一到就跟在后面喂进去。
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

/// Agora 回调线程上的那一半:读 SEI、解封套、解 protobuf(都是无状态的纯函数),结果切到主线程交给会话。
/// 同时是 `.join` 时引擎的 delegate。
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

    // MARK: AgoraRtcEngineDelegate(`.join` 时)

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
