import Combine
import Daily
import Foundation
import PipecatClientIOS
import PipecatClientIOSDaily
import os

/// The Daily side of the router: sends `AudioRequest` over the transport, switches the bot's
/// microphone track subscription, and reports the bot's audio level, reconnects and departures from
/// the `CallClient`'s published state (so the app's own `PipecatClientDelegate` stays untouched).
///
/// The bot is the first remote participant, as in Pipecat's `DailyTransport`.
@MainActor final class DailyBotLink: BotAudioLink {
    private let transport: DailyTransport
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "ai.spatialreal", category: "PipecatDailyLink")

    var onBotAudioLevel: ((Float) -> Void)?
    var onReconnected: (() -> Void)?
    var onBotLeft: (() -> Void)?

    /// What the router wants for the bot's microphone track.
    private var wantSubscribed = true
    private var botID: ParticipantID?
    /// The bot's microphone went `interrupted` (Daily is reconnecting); its recovery is a reconnect.
    private var botInterrupted = false

    init(transport: DailyTransport) {
        self.transport = transport
    }

    private var call: CallClient? { transport.dailyCallClient }

    func attach() {
        guard cancellables.isEmpty, let call else { return }
        // Daily publishes these from its own event thread: hop to the main queue before touching state.
        call.$remoteParticipantsAudioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] levels in
                guard let self, let id = self.botID, let level = levels[id] else { return }
                self.onBotAudioLevel?(level)
            }
            .store(in: &cancellables)
        call.$participants
            .receive(on: DispatchQueue.main)
            .sink { [weak self] participants in self?.participantsChanged(participants) }
            .store(in: &cancellables)
        participantsChanged(call.participants)
        startBotAudioLevels()
    }

    /// Makes sure Daily reports remote audio levels (every 100 ms), which the quiet point needs.
    /// Pipecat starts Daily's observer only while it initialises devices, and `disconnect()` stops it;
    /// a `PipecatClient` reused for another call does not initialise devices again, so the levels
    /// would never come back. Starting it again is harmless.
    func startBotAudioLevels() {
        guard let call else { return }
        Task { @MainActor [logger] in
            do {
                try await call.startRemoteParticipantsAudioLevelObserver(intervalMs: 100)
            } catch {
                logger.error("could not start Daily's remote audio levels: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func detach() {
        cancellables.removeAll()
    }

    func sendAudioRequest() -> Bool {
        // Daily drops app messages sent outside a call without telling `DailyTransport.sendMessage`,
        // so a request sent then would wait for an answer that never comes.
        guard call?.callState == .joined else {
            logger.info("not in a call: the audio request waits for the next bot-ready")
            return false
        }
        do {
            // The generated AvatarClientMessage, as Pipecat's Value
            let data = try JSONDecoder().decode(Value.self, from: AvatarWire.audioRequestJSON())
            let message = RTVIMessageOutbound.clientMessage(msgType: AvatarWire.tag, data: data)
            try transport.sendMessage(message: message)
            logger.info("audio mode requested")
            return true
        } catch {
            logger.error("could not send the audio request: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setBotAudioSubscribed(_ subscribed: Bool) {
        wantSubscribed = subscribed
        applySubscription()
    }

    private func applySubscription() {
        guard let call, let id = botID else { return }
        let state: SubscriptionState = wantSubscribed ? .subscribed : .unsubscribed
        let update: Update<SubscriptionSettingsUpdate> = .set(media: .set(microphone: .set(subscriptionState: .set(state))))
        // The async form resumes on the main actor; the completion-handler form calls back on Daily's thread.
        Task { @MainActor [logger] in
            do {
                _ = try await call.updateSubscriptions(forParticipants: .set([id: update]))
            } catch {
                logger.error("could not update the bot's audio subscription: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func participantsChanged(_ participants: Participants) {
        let bot = participants.remote.first?.value
        if bot?.id != botID {
            let hadBot = botID != nil
            botID = bot?.id
            botInterrupted = false
            if hadBot { onBotLeft?() }
            if botID != nil, !wantSubscribed { applySubscription() }
        }
        guard let bot else { return }
        // While Daily reconnects the bot's media reads `interrupted`; app messages sent meanwhile are lost.
        let interrupted = bot.media?.microphone.state == .interrupted
        if interrupted, !botInterrupted {
            botInterrupted = true
            logger.info("bot media interrupted (reconnecting)")
        } else if !interrupted, botInterrupted {
            botInterrupted = false
            onReconnected?()
        }
    }
}
