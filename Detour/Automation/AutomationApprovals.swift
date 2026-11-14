import Foundation
import Synchronization

/// What a client asks for at `POST /mcp/authorize` (TASK-228.5): a token
/// under its name. Every field is the client's own claim; the prompt says so.
nonisolated struct AutomationApprovalRequest: Equatable, Sendable {
    let name: String
    let title: String?
    let version: String?

    /// What the prompt and the indicator call the client.
    var displayName: String { title ?? name }

    /// The rate limits' key: one prompt at a time per name, and a name
    /// denied lately is refused without one.
    var key: String { name.lowercased() }

    /// What the prompt shows, as a key: a denial holds for it too, so a
    /// client cannot re-ask under a fresh name with the same title.
    var displayKey: String { displayName.lowercased() }

    static let maximumBodySize = 4096
    static let maximumNameLength = 64
    static let maximumVersionLength = 32

    struct Invalid: Error, Equatable {
        let reason: String
    }

    /// Reads `{"client_name": …, "client_title"?: …, "client_version"?: …}`.
    /// Names are cleaned before anything shows or keys on them.
    static func parse(_ body: Data) throws(Invalid) -> AutomationApprovalRequest {
        guard body.count <= maximumBodySize else { throw Invalid(reason: "The request is too large") }
        guard let value = try? JSONValue.parse(body), let object = value.objectValue else {
            throw Invalid(reason: "The body must be a JSON object")
        }
        func optionalString(_ key: String) throws(Invalid) -> String? {
            guard let field = object[key], !field.isNull else { return nil }
            guard let string = field.stringValue else { throw Invalid(reason: "\(key) must be a string") }
            return string
        }
        guard let rawName = try optionalString("client_name"),
              let name = sanitized(rawName, limit: maximumNameLength) else {
            throw Invalid(reason: "client_name is required: the name the client goes by")
        }
        let title = try optionalString("client_title").flatMap { sanitized($0, limit: maximumNameLength) }
        let version = try optionalString("client_version").flatMap { sanitized($0, limit: maximumVersionLength) }
        return AutomationApprovalRequest(name: name, title: title == name ? nil : title, version: version)
    }

    /// `value` without control, format (bidirectional overrides, zero-width
    /// characters), separator, private-use or unassigned characters, with
    /// runs of white space made one space, trimmed and cut to `limit`
    /// characters. Nil when nothing is left. A name in the prompt cannot
    /// reorder itself, hide text or span lines.
    static func sanitized(_ value: String, limit: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in value.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                continue
            default:
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        let cut = String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }
}

enum AutomationApprovalAnswer: Equatable {
    case allow
    case deny
}

/// A prompt on screen. `dismiss()` closes it (the answer came, it timed out,
/// the client went away, automation was turned off); it may be called more
/// than once.
protocol AutomationApprovalPrompt: AnyObject {
    func dismiss()
}

/// Shows the Allow / Deny prompt: the panel in the app, a fake in tests.
/// `answer` is called at most once, on the main actor, when the user
/// answers; never after `dismiss()`.
protocol AutomationApprovalPrompter: AnyObject {
    func present(_ request: AutomationApprovalRequest,
                 answer: @escaping (AutomationApprovalAnswer) -> Void) -> AutomationApprovalPrompt
}

/// Fired by the endpoint when an authorize request's connection closes
/// before it was answered. A handler added after that runs at once.
///
/// `Sendable`: the flag and handlers are behind a `Mutex`.
nonisolated final class AutomationRequestCancellation: Sendable {
    private let state = Mutex<(cancelled: Bool, handlers: [@Sendable () -> Void])>((false, []))

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { state in
            if state.cancelled { return true }
            state.handlers.append(handler)
            return false
        }
        if runNow { handler() }
    }

    func cancel() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.cancelled else { return [] }
            state.cancelled = true
            defer { state.handlers.removeAll() }
            return state.handlers
        }
        for handler in handlers { handler() }
    }
}

/// The answer to an authorize request, and what to do when it cannot be
/// delivered: an approval whose token never reached the client is revoked,
/// so no approved client exists that nobody holds the token of.
nonisolated struct AutomationAuthorizeOutcome: Sendable {
    var response: AutomationHTTP.Response
    var undo: (@Sendable () -> Void)?
}

/// The approval flow of the user's endpoint (TASK-228.5): a client with no
/// token asks for one, Detour shows the user its prompt, and the HTTP
/// request is held until the answer (`POST /mcp/authorize`).
///
/// - Allow approves the client (`AutomationClientStore.add`) and answers
///   200 with its token; Deny answers 403.
/// - No answer within `promptTimeout` (5 minutes) is a denial.
/// - One prompt per name at a time: a second request for a name being
///   asked about waits for that prompt to end, then gets a prompt of its
///   own (never the first one's answer, so a second process cannot ride on
///   a prompt the user expected). At most `maximumWaitersPerName` wait.
/// - At most `maximumPrompts` names are asked about at once; another
///   request is refused at once (429).
/// - A name denied (or not answered) within `denialWindow` (10 minutes) is
///   refused without a prompt, so a looping client cannot keep prompting.
///   The denial holds for the title the prompt showed too, so a client
///   cannot re-ask under a fresh name with the same title. A client that
///   hangs up while its prompt is shown is let off once (the person may
///   have closed it); a second time within `denialWindow` counts as a
///   denial, so closing and reconnecting cannot keep the panel flashing.
/// - At most `maximumPromptsPerWindow` prompts are shown in any
///   `denialWindow`, whatever the names: the bound on a client that rotates
///   both name and title. Past it, requests get 429 until the window moves.
/// - A request whose client went away closes its prompt; `stop()` closes
///   every prompt and answers every held request 503.
final class AutomationApprovals {

    static let maximumPrompts = 3
    static let maximumWaitersPerName = 1
    static let denialWindow: TimeInterval = 10 * 60
    static let maximumPromptsPerWindow = 5

    var promptTimeout: Duration = .seconds(300)
    /// Called after a client was approved (Settings lists the clients).
    var onApproval: (() -> Void)?

    private let store: AutomationClientStore
    private let prompter: AutomationApprovalPrompter
    private let now: () -> Date

    init(store: AutomationClientStore, prompter: AutomationApprovalPrompter, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.prompter = prompter
        self.now = now
    }

    enum Outcome: Equatable {
        case allow, deny, timedOut, withdrawn, stopped
    }

    /// One held request: queued behind another prompt for its name, or the
    /// one whose prompt is shown.
    private final class Pending {
        let request: AutomationApprovalRequest
        private var turn: CheckedContinuation<Bool, Never>?
        private var answer: CheckedContinuation<Outcome, Never>?
        /// The outcome, once there is one; later answers are ignored.
        private(set) var outcome: Outcome?
        /// Set when it was told to stop waiting before its turn came.
        private var turnRefused = false
        var prompt: AutomationApprovalPrompt?
        var timeout: Task<Void, Never>?
        /// Whether its prompt was put on screen (a withdrawal then counts
        /// as a denial).
        var wasShown = false

        init(request: AutomationApprovalRequest) {
            self.request = request
        }

        func awaitTurn() async -> Bool {
            if turnRefused || outcome != nil { return false }
            return await withCheckedContinuation { turn = $0 }
        }

        func grantTurn() {
            turn?.resume(returning: true)
            turn = nil
        }

        func awaitAnswer(show: (Pending) -> Void) async -> Outcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation in
                answer = continuation
                show(self)
            }
        }

        /// Settles it once, from whichever comes first: the user's answer,
        /// the timeout, the client going away, or `stop()`.
        func resolve(_ value: Outcome) {
            guard outcome == nil else { return }
            outcome = value
            timeout?.cancel()
            timeout = nil
            prompt?.dismiss()
            prompt = nil
            if let turn {
                self.turn = nil
                turnRefused = true
                turn.resume(returning: false)
            }
            if let answer {
                self.answer = nil
                answer.resume(returning: value)
            }
        }
    }

    /// Per name, the held requests: the first is the one asked about.
    private var queues: [String: [Pending]] = [:]
    /// When each name was last denied (or not answered).
    private var deniedAt: [String: Date] = [:]
    /// When each prompt of the last `denialWindow` was shown.
    private var shownAt: [Date] = []
    /// When each name last hung up while its prompt was shown.
    private var withdrawnAt: [String: Date] = [:]
    private var isStopped = false

    /// How many prompts are shown (or about to be), and how many wait.
    var heldCount: Int { queues.values.reduce(0) { $0 + $1.count } }
    var promptCount: Int { queues.count }

    /// Answers one `POST /mcp/authorize` (the endpoint checked its Host,
    /// Origin, method and size).
    func handle(_ http: AutomationHTTP.Request, cancellation: AutomationRequestCancellation) async
        -> AutomationAuthorizeOutcome {
        guard !isStopped else { return Self.answer(503, "Automation is turned off") }
        let request: AutomationApprovalRequest
        do {
            request = try AutomationApprovalRequest.parse(http.body)
        } catch {
            return Self.answer(400, error.reason)
        }
        let key = request.key
        if let refusal = recentDenial(of: request) { return refusal }
        if let refusal = promptBudgetRefusal() { return refusal }
        let ahead = queues[key]?.count ?? 0
        if ahead == 0 {
            guard queues.count < Self.maximumPrompts else {
                return Self.answer(429, "Detour is already asking about \(Self.maximumPrompts) clients; try again later")
            }
        } else if ahead > Self.maximumWaitersPerName {
            return Self.answer(429, "Detour is already asking about \(request.name); try again later")
        }

        let pending = Pending(request: request)
        queues[key, default: []].append(pending)
        defer { finish(pending, key: key) }
        cancellation.onCancel { [weak self, weak pending] in
            Task { @MainActor in
                guard let pending else { return }
                self?.withdraw(pending)
            }
        }

        if ahead > 0 {
            guard await pending.awaitTurn() else { return Self.response(for: pending.outcome ?? .withdrawn, request) }
            // The prompt ahead was denied: this one is refused with it.
            if let refusal = recentDenial(of: request) ?? promptBudgetRefusal() {
                pending.resolve(.deny)
                return refusal
            }
        }

        let outcome = await pending.awaitAnswer { pending in
            let prompt = prompter.present(request) { [weak pending] answer in
                pending?.resolve(answer == .allow ? .allow : .deny)
            }
            // Counted once presented, however soon it is answered.
            pending.wasShown = true
            shownAt.append(now())
            // A prompter may answer at once (tests): nothing to keep then.
            guard pending.outcome == nil else {
                prompt.dismiss()
                return
            }
            pending.prompt = prompt
            let timeout = promptTimeout
            pending.timeout = Task { [weak pending] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                pending?.resolve(.timedOut)
            }
        }
        switch outcome {
        case .allow:
            do {
                let (token, record) = try store.add(name: request.name, title: request.title,
                                                    version: request.version, now: now())
                onApproval?()
                let store = self.store
                let id = record.clientID
                let body: JSONValue = ["token": .string(token), "client_id": .string(id.uuidString),
                                       "name": .string(record.displayName)]
                return AutomationAuthorizeOutcome(response: .json(body), undo: { store.revoke(clientID: id) })
            } catch {
                return Self.answer(500, "Detour could not save the approval: \(error)")
            }
        case .deny, .timedOut:
            recordDenial(of: request)
            return Self.response(for: outcome, request)
        case .withdrawn:
            if pending.wasShown {
                let time = now()
                if let earlier = withdrawnAt[key], time.timeIntervalSince(earlier) < Self.denialWindow {
                    recordDenial(of: request)
                } else {
                    withdrawnAt[key] = time
                }
            }
            return Self.response(for: outcome, request)
        case .stopped:
            return Self.response(for: outcome, request)
        }
    }

    private func recordDenial(of request: AutomationApprovalRequest) {
        let time = now()
        deniedAt[request.key] = time
        deniedAt[request.displayKey] = time
    }

    /// 429 once `maximumPromptsPerWindow` prompts were shown in the last
    /// `denialWindow`.
    private func promptBudgetRefusal() -> AutomationAuthorizeOutcome? {
        let time = now()
        shownAt.removeAll { time.timeIntervalSince($0) >= Self.denialWindow }
        guard shownAt.count >= Self.maximumPromptsPerWindow, let oldest = shownAt.first else { return nil }
        let wait = Int((Self.denialWindow - time.timeIntervalSince(oldest)).rounded(.up))
        return Self.answer(429, "Detour has asked about clients \(Self.maximumPromptsPerWindow) times lately; "
                            + "try again in \(max(1, (wait + 59) / 60)) min",
                           headers: [("Retry-After", "\(max(1, wait))")])
    }

    private func recentDenial(of request: AutomationApprovalRequest) -> AutomationAuthorizeOutcome? {
        let time = now()
        deniedAt = deniedAt.filter { time.timeIntervalSince($0.value) < Self.denialWindow }
        guard let denied = [request.key, request.displayKey].compactMap({ deniedAt[$0] }).max() else { return nil }
        let elapsed = time.timeIntervalSince(denied)
        let minutes = Int(((Self.denialWindow - elapsed) / 60).rounded(.up))
        return Self.answer(403, "\(request.name) was denied control of Detour a short while ago; "
                            + "it can ask again in \(minutes) min",
                           headers: [("Retry-After", "\(Int((Self.denialWindow - elapsed).rounded(.up)))")])
    }

    private func withdraw(_ pending: Pending) {
        pending.resolve(.withdrawn)
    }

    /// Takes a settled request out of its queue and gives the next one for
    /// its name its turn.
    private func finish(_ pending: Pending, key: String) {
        pending.resolve(.withdrawn)  // no-op when it already has an outcome
        guard var queue = queues[key], let index = queue.firstIndex(where: { $0 === pending }) else { return }
        queue.remove(at: index)
        if queue.isEmpty {
            queues[key] = nil
        } else {
            queues[key] = queue
            if index == 0 { queue[0].grantTurn() }
        }
    }

    /// Closes every prompt and answers every held request 503, and refuses
    /// every later one (the endpoint is being turned off; the next start
    /// makes a new `AutomationApprovals`).
    func stop() {
        isStopped = true
        for pending in queues.values.flatMap({ $0 }) { pending.resolve(.stopped) }
    }

    private static func response(for outcome: Outcome, _ request: AutomationApprovalRequest) -> AutomationAuthorizeOutcome {
        switch outcome {
        case .allow:
            answer(500, "unexpected")
        case .deny:
            answer(403, "The user denied \(request.name) control of Detour")
        case .timedOut:
            answer(403, "Nobody answered Detour's prompt for \(request.name) in time")
        case .withdrawn:
            answer(400, "The request was withdrawn")
        case .stopped:
            answer(503, "Automation was turned off")
        }
    }

    private static func answer(_ status: Int, _ message: String, headers: [(String, String)] = []) -> AutomationAuthorizeOutcome {
        AutomationAuthorizeOutcome(response: .json(["error": .string(message)], status: status, headers: headers),
                                   undo: nil)
    }
}
