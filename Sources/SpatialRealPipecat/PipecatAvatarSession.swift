import Foundation
import PipecatClientIOSDaily
@_spi(RTC) import SpatialRealSDK
import UIKit
import os

/// Options for a Pipecat avatar session.
///
/// - `avatarId`: the avatar to show.
/// - `credential`: a session token from your backend; here it only authorises the avatar download.
/// - `container`: the view that hosts the avatar.
/// - `transport`: the `DailyTransport` your `PipecatClient` uses. The session uses it to send the bot
///   one request and to switch the bot's audio track off and on; it never joins, leaves or reads your
///   call otherwise.
public struct PipecatAvatarSessionOptions {
    public let avatarId: String
    public let credential: String
    public let container: UIView
    public let transport: DailyTransport

    public init(avatarId: String, credential: String, container: UIView, transport: DailyTransport) {
        self.avatarId = avatarId
        self.credential = credential
        self.container = container
        self.transport = transport
    }
}

public extension SpatialReal {
    /// Creates a Pipecat avatar session. The avatar is downloaded here; nothing connects until
    /// `start()`, and the session never opens a connection of its own.
    func createSession(_ options: PipecatAvatarSessionOptions) async throws -> PipecatAvatarSession {
        let format = try SessionAudioFormat.oggOpus(48000)
        let host = try await createSession(HostAvatarSessionOptions(avatarId: options.avatarId, credential: options.credential,
                                                                    container: options.container, audioFormat: format))
        return PipecatAvatarSession(host: host, link: DailyBotLink(transport: options.transport))
    }
}

/// An animated avatar for a Pipecat bot that runs the `pipecat-spatialreal` processor, over Pipecat's
/// Daily transport.
///
/// Your `PipecatClient` keeps the call, the microphone and the bot. The session asks the processor to
/// also send the bot's voice with the animation, and plays the two together on the avatar, in sync.
/// While it does, the bot's audio track is switched off so the voice is not heard twice; before that,
/// and whenever the stream breaks, Daily plays the bot's audio track as usual
/// (see `voiceRoute`). Echo cancellation stays with Daily.
///
/// ```swift
/// let session = try await sr.createSession(PipecatAvatarSessionOptions(
///     avatarId: avatarId, credential: token, container: avatarView, transport: transport))
/// try await session.start()
/// // in your PipecatClientDelegate:
/// func onBotReady(botReadyData: BotReadyData) { session.handleBotReady() }
/// func onServerMessage(data: Any) { session.handleServerMessage(data) }
/// ```
///
/// Never enable voice processing on the audio session or engine yourself while the call runs: Daily
/// already runs it, and a second one stops the app.
@MainActor public final class PipecatAvatarSession {
    private let host: HostAvatarSession
    private let link: DailyBotLink
    private let router: TurnRouter
    private let playback: HostPlayback
    private var routeListeners: [UUID: (PipecatVoiceRoute) -> Void] = [:]
    private var stateUnsubscribe: (() -> Void)?
    private let logger = Logger(subsystem: "ai.spatialreal", category: "PipecatAvatarSession")

    init(host: HostAvatarSession, link: DailyBotLink) {
        self.host = host
        self.link = link
        let playback = HostPlayback(host: host)
        self.playback = playback
        router = TurnRouter(player: playback, link: link)
        router.onRouteChange = { [weak self] route in self?.emitRoute(route) }
        link.onBotAudioLevel = { [weak self] level in
            self?.router.botAudioLevel(level, now: ProcessInfo.processInfo.systemUptime)
        }
        link.onReconnected = { [weak self] in self?.router.transportReconnected() }
        link.onBotLeft = { [weak self] in self?.router.botLeft() }
        stateUnsubscribe = host.onState { [weak self] change in
            guard let self else { return }
            if change.current == .live { self.router.activate() } else if change.previous == .live { self.router.deactivate() }
        }
    }

    /// `idle`, `connecting`, `live`, `ending` or `disposed`.
    public var state: SessionState { host.state }
    /// The avatar's rendering surface; nil after `dispose()`.
    public var view: SessionView? { host.view }
    /// Volume of the bot's voice while the avatar plays it, 0...1.
    public var volume: Float {
        get { host.volume }
        set { host.volume = newValue }
    }
    /// Where the bot's voice is played from right now.
    public var voiceRoute: PipecatVoiceRoute { router.route }

    @discardableResult
    public func onState(_ listener: @escaping (SessionStateChange) -> Void) -> @MainActor () -> Void { host.onState(listener) }

    @discardableResult
    public func onError(_ listener: @escaping (SpatialRealError) -> Void) -> @MainActor () -> Void { host.onError(listener) }

    /// Called when the bot's voice moves between the call's audio track and the avatar.
    @discardableResult
    public func onVoiceRouteChange(_ listener: @escaping (PipecatVoiceRoute) -> Void) -> @MainActor () -> Void {
        let id = UUID()
        routeListeners[id] = listener
        return { [weak self] in self?.routeListeners[id] = nil }
    }

    /// Starts the avatar player. Call it before or after `PipecatClient.connect()`; no network.
    public func start() async throws {
        try await host.start()
        link.attach()
    }

    /// Stops the avatar and gives the bot's voice back to the call's audio track.
    public func end() async throws {
        try await host.end()
        link.detach()
    }

    /// Releases the avatar view. The session cannot be used afterwards.
    public func dispose() async {
        await host.dispose()
        link.detach()
        stateUnsubscribe?()
        stateUnsubscribe = nil
    }

    /// Call from `PipecatClientDelegate.onBotReady(botReadyData:)`: the session then asks the bot's
    /// processor for the voice-with-animation stream.
    public func handleBotReady() {
        router.botReady()
    }

    /// Forward every RTVI server message here (`PipecatClientDelegate.onServerMessage(data:)`'s
    /// argument, or the raw RTVI message). Returns true when the message was the avatar's and false for
    /// anything else, so it can sit in front of your own handling. Never throws.
    @discardableResult
    public func handleServerMessage(_ data: Any) -> Bool {
        guard let message = AvatarWire.decode(data) else { return false }
        router.handle(message, now: ProcessInfo.processInfo.systemUptime)
        return true
    }

    private func emitRoute(_ route: PipecatVoiceRoute) {
        logger.info("bot voice route: \(route == .avatar ? "avatar" : "call", privacy: .public)")
        for l in routeListeners.values { l(route) }
    }
}

/// The router's player: the Host session's per-turn feed.
@MainActor final class HostPlayback: HostTurnPlayer {
    private let host: HostAvatarSession
    init(host: HostAvatarSession) { self.host = host }

    func beginTurn() -> String? { try? host.beginTurn() }
    func yieldAudio(_ slice: Data, turnID: String) { host.yieldTurnAudio(slice, turnID: turnID) }
    func yieldFrames(_ frames: [Data], turnID: String) { host.yieldTurnFrames(frames, turnID: turnID) }
    func setAudioOnly(turnID: String) { host.setTurnAudioOnly(turnID) }
    func endTurn(turnID: String) { host.endTurn(turnID) }
    func interrupt() { try? host.interrupt() }
}
