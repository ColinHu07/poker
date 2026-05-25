import Foundation
import MWDATCore
import MWDATDisplay

@MainActor
final class PokerDisplayViewModel {
    private let wearables: WearablesInterface
    private var deviceSelector: AutoDeviceSelector
    private var deviceSession: DeviceSession?
    private var sharedDeviceSession: DeviceSession?
    private var ownsDeviceSession = false
    private var display: Display?
    private var sessionStateTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?
    private var displayStateTask: Task<Void, Never>?
    private var stateListenerToken: AnyListenerToken?
    private var displayStateContinuation: AsyncStream<DisplayState>.Continuation?
    private var pendingView: FlexBox?
    private var analyzeHandler: (@MainActor () async -> Void)?

    private(set) var isConnected = false
    private(set) var lastError: String?

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    }

    deinit {
        sessionStateTask?.cancel()
        sessionErrorTask?.cancel()
        displayStateTask?.cancel()
    }

    func configureAnalyzeHandler(_ handler: @escaping @MainActor () async -> Void) {
        analyzeHandler = handler
    }

    func useSharedDeviceSession(_ session: DeviceSession?) {
        sharedDeviceSession = session
    }

    func showIdle() async {
        await send(PokerDisplayRenderer.idle { [weak self] in
            Task { @MainActor in
                await self?.runAnalyze()
            }
        })
    }

    func showAnalyzing() async {
        await send(PokerDisplayRenderer.analyzing())
    }

    func showAnalysis(_ analysis: PokerSceneAnalysis) async {
        await send(PokerDisplayRenderer.tableRead(analysis) { [weak self] in
            Task { @MainActor in
                await self?.runAnalyze()
            }
        })
    }

    func showUnavailable(_ message: String) async {
        await send(PokerDisplayRenderer.unavailable(message: message) { [weak self] in
            Task { @MainActor in
                await self?.runAnalyze()
            }
        })
    }

    func showDecision(_ decision: PokerDisplayDecisionHUDState) async {
        await send(PokerDisplayRenderer.decision(decision) { [weak self] in
            Task { @MainActor in
                await self?.runAnalyze()
            }
        })
    }

    func showNotReady(_ state: PokerDisplayReadinessState) async {
        await send(PokerDisplayRenderer.notReady(state) { [weak self] in
            Task { @MainActor in
                await self?.runAnalyze()
            }
        })
    }

    func detach() async {
        stateListenerToken = nil
        displayStateContinuation?.finish()
        displayStateContinuation = nil
        displayStateTask?.cancel()
        displayStateTask = nil
        await display?.stop()
        display = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        if ownsDeviceSession {
            deviceSession?.stop()
        }
        deviceSession = nil
        sharedDeviceSession = nil
        ownsDeviceSession = false
        isConnected = false
        pendingView = nil
    }

    private func runAnalyze() async {
        guard let analyzeHandler else {
            await showUnavailable("Phone app is not ready yet.")
            return
        }
        await showAnalyzing()
        await analyzeHandler()
    }

    private func send(_ view: FlexBox) async {
        if let display, isConnected {
            await doSend(view, on: display)
            return
        }

        pendingView = view
        if display == nil {
            await attachToDisplay()
        }
    }

    private func doSend(_ view: FlexBox, on capability: Display) async {
        do {
            try await capability.send(view)
        } catch {
            lastError = (error as? DisplayError)?.description ?? error.localizedDescription
        }
    }

    private func attachToDisplay() async {
        guard display == nil else { return }

        do {
            let devSession: DeviceSession
            if let sharedDeviceSession {
                devSession = sharedDeviceSession
                ownsDeviceSession = false
            } else {
                devSession = try wearables.createSession(deviceSelector: deviceSelector)
                ownsDeviceSession = true
            }
            deviceSession = devSession

            let stateStream = devSession.stateStream()
            sessionStateTask = Task { [weak self] in
                for await sessionState in stateStream {
                    guard let self, !Task.isCancelled else { return }
                    switch sessionState {
                    case .started:
                        await self.setupDisplay(on: devSession)
                    case .stopping, .stopped:
                        self.isConnected = false
                        self.display = nil
                    case .idle, .starting, .paused:
                        break
                    @unknown default:
                        break
                    }
                }
            }

            let errorStream = devSession.errorStream()
            sessionErrorTask = Task { [weak self] in
                for await error in errorStream {
                    guard let self, !Task.isCancelled else { return }
                    self.lastError = error.localizedDescription
                }
            }

            if ownsDeviceSession {
                try devSession.start()
            } else if devSession.state == .started {
                await setupDisplay(on: devSession)
            }
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            lastError = DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription
            try? await wearables.openDATGlassesAppUpdate()
        } catch {
            lastError = "Display session failed: \(error.localizedDescription)"
        }
    }

    private func setupDisplay(on devSession: DeviceSession) async {
        guard display == nil else { return }

        do {
            let capability = try devSession.addDisplay()
            let (stateStream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            displayStateContinuation = continuation
            stateListenerToken = capability.statePublisher.listen { state in
                continuation.yield(state)
            }

            displayStateTask = Task { [weak self] in
                for await state in stateStream {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .started:
                        self.isConnected = true
                        if let pendingView = self.pendingView {
                            self.pendingView = nil
                            await self.doSend(pendingView, on: capability)
                        }
                    case .stopping, .stopped:
                        self.isConnected = false
                        self.display = nil
                    case .starting:
                        break
                    }
                }
            }

            await capability.start()
            display = capability
        } catch {
            lastError = "Display start failed: \(error.localizedDescription)"
        }
    }
}
