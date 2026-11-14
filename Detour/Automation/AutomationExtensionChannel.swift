import Foundation
import WebKit
import os

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "automation")

/// Detour's private channel from the automation endpoint into an extension's
/// background, the service worker (or background page), for
/// `call_extension_api`, `read_extension_global` and `wait_for
/// worker_started` (TASK-228.2).
///
/// Nothing public evaluates script in an extension's service worker, and an
/// MV3 worker's CSP forbids `eval` and `new Function`, so commands are data,
/// not code: call the function at a dotted path with JSON arguments, read the
/// value at a path, or answer a ping. The worker half is the polyfill module
/// `polyfillModuleJS`. Like `notifications.awaitEvent` (TASK-247) it parks a
/// request, `automation.awaitCommand`, that this side answers with the next
/// command; it acknowledges the command at once (`automation.ack`), parks
/// again, and sends the result when the command settles
/// (`automation.result`), so a call that never settles holds up nothing
/// else. Chosen over the alternatives:
///
/// - A `runtime.onMessage` listener would be seen by the extension's own
///   listeners, and a Proxy on (or a replacement of) the `chrome`/`browser`
///   globals is never done (wiki: never-replace-chrome-globals).
/// - A native port (`connectNative`) would push without parking, but opening
///   and closing ports changes how long WebKit keeps the background alive and
///   can make it forget another port's activity (TASK-141), which would skew
///   what a compatibility run measures. A pending native-message reply
///   changes neither (wiki: service-worker-unload-rules).
/// - A hidden extension page relaying through `chrome.*` would run in a page,
///   not in the worker, and could not read the worker's globals.
///
/// What follows from parking:
/// - A park does not keep the background alive, and WebKit says nothing when
///   it unloads one: a reply to the dead worker's park goes nowhere. So a
///   delivered command must be acknowledged within `ackTimeout`; if it is
///   not, the park is taken as dead, the background is started
///   (`loadBackgroundContent`), and the command goes to the new worker's park.
///   With no park at all the background is started the same way.
/// - The worker parks when it starts and the channel is open. A worker that
///   started while automation was off was told to stop, and parks again only
///   at its next start (an idle background unloads after about 30 s), so a
///   call to it answers `worker_not_running` until then.
/// - Each background context is one key (extension, profile). A newer start
///   supersedes an older park, which is answered `stop`.
/// - Only the verified extension's background context may park or
///   acknowledge (`ExtensionPolyfillHandler`): never a web page, a content
///   script or another extension. A worker's requests arrive as native
///   messages, which WebKit attributes to the extension's context but not to
///   a page, so for a service-worker extension any of its own pages that calls
///   `runtime.sendNativeMessage` directly counts as the background too. The
///   extension's own code can therefore take (or, by parking, supersede) its
///   own commands, which a test of that extension accepts.
final class AutomationExtensionChannel {

    static let shared = AutomationExtensionChannel()

    struct Key: Hashable {
        let extensionID: String
        let profileID: UUID
    }

    typealias Reply = (Any?, String?) -> Void

    /// Whether backgrounds open the channel: set when the endpoint starts (in
    /// the same main-actor turn as the launch, before any worker's first
    /// message is handled) and cleared when it stops, which stops every park
    /// and fails every waiting command. Tests set it themselves.
    var isOpen = false {
        didSet { if oldValue && !isOpen { closeAll() } }
    }

    /// How long a delivered command waits to be acknowledged before its park
    /// counts as dead (its worker was unloaded).
    var ackTimeout: Duration = .milliseconds(1500)
    /// How many times one command is sent to a park that never acknowledges
    /// it before the call fails.
    static let maximumDeliveries = 3

    /// Starts a key's background. Injected so tests can see the wakes.
    var wake: (Key) -> Void = { AutomationExtensionChannel.loadBackground($0) }

    private struct Park {
        let instance: String
        let reply: Reply
    }

    private final class Command {
        let id: Int
        let key: Key
        let payload: [String: Any]
        var continuation: CheckedContinuation<JSONValue, any Error>?
        /// The instance the last delivery went to; nil while it waits for a park.
        var deliveredTo: String?
        var acknowledged = false
        var deliveries = 0
        /// The `limit` timer of `send`, cancelled when the command finishes
        /// so it does not hold the command for the rest of its limit.
        var limitTimer: Task<Void, Never>?

        init(id: Int, key: Key, payload: [String: Any]) {
            self.id = id
            self.key = key
            self.payload = payload
        }

        func finish(_ result: Result<JSONValue, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            limitTimer?.cancel()
            limitTimer = nil
            continuation.resume(with: result)
        }
    }

    private var parks: [Key: Park] = [:]
    /// Commands waiting for a park, oldest first.
    private var queues: [Key: [Command]] = [:]
    /// Commands sent to a park and not finished, by id.
    private var delivered: [Int: Command] = [:]
    /// The instance each key's background last parked with: a worker that
    /// has parked since automation started.
    private var lastInstance: [Key: String] = [:]
    private var nextID = 1

    // MARK: From the polyfill

    /// The background parks: answered at once with `stop` while the channel
    /// is closed, else with the next command when there is one.
    func park(key: Key, instance: String, reply: @escaping Reply) {
        guard isOpen else {
            reply(["stop": true], nil)
            return
        }
        if let old = parks.removeValue(forKey: key) {
            // A newer start of the background, or a second park from the
            // same one: only the newest park is answered with commands.
            old.reply(["stop": true], nil)
        }
        if lastInstance[key] != instance {
            // A new start of the background. Commands an older start took are
            // lost with it (they may have had effects, so they are not run
            // twice); those it never took go to this one.
            for command in delivered.values where command.key == key && command.deliveredTo != instance {
                delivered[command.id] = nil
                if command.acknowledged {
                    command.finish(.failure(AutomationToolError(
                        .workerNotRunning, "The extension's background restarted while running the command")))
                } else {
                    command.deliveredTo = nil
                    queues[key, default: []].insert(command, at: 0)
                }
            }
        }
        lastInstance[key] = instance
        parks[key] = Park(instance: instance, reply: reply)
        deliverNext(key)
    }

    /// The background took the command: its park was live.
    func acknowledge(key: Key, instance: String, commandID: Int) {
        if let command = delivered[commandID], command.key == key, command.deliveredTo == instance {
            command.acknowledged = true
        } else if let index = queues[key]?.firstIndex(where: { $0.id == commandID }),
                  let command = queues[key]?.remove(at: index) {
            // Acknowledged late, by a busy worker, after it was put back: it
            // is running there. (The worker skips a command it has seen.)
            command.deliveredTo = instance
            command.acknowledged = true
            delivered[command.id] = command
            if queues[key]?.isEmpty == true { queues[key] = nil }
        }
    }

    /// A command finished in the background: `resultJSON` is the runner's
    /// result object, with the command's id.
    func complete(key: Key, resultJSON: String) {
        guard let result = try? JSONValue.parse(Data(resultJSON.utf8)), let id = result["id"]?.intValue,
              let command = delivered[id], command.key == key else { return }
        delivered[id] = nil
        command.finish(.success(result))
    }

    // MARK: From the tools

    /// Whether `key`'s background has parked since automation started (it is
    /// running, or was until WebKit unloaded it).
    func hasParked(_ key: Key) -> Bool { lastInstance[key] != nil }

    /// Runs `op` (`call`, `get`, `ping` or `probe`) in `key`'s background and returns
    /// the runner's result object (`ok`, `type`, `value`, `truncated`, or
    /// `ok: false` with the thrown error). Starts the background when it is
    /// not running. Fails with `worker_not_running` when no live background
    /// takes the command within `limit`, and `timeout` when it took it but
    /// did not finish.
    func send(_ key: Key, op: String, path: String? = nil, argumentsJSON: String? = nil,
              limit: Duration) async throws -> JSONValue {
        guard isOpen else {
            throw AutomationToolError(.workerNotRunning, "The automation channel is closed")
        }
        let id = nextID
        nextID += 1
        var payload: [String: Any] = ["id": id, "op": op]
        if let path { payload["path"] = path }
        if let argumentsJSON { payload["args"] = argumentsJSON }
        let command = Command(id: id, key: key, payload: payload)
        let milliseconds = AutomationPage.milliseconds(limit)
        return try await withCheckedThrowingContinuation { continuation in
            command.continuation = continuation
            queues[key, default: []].append(command)
            if parks[key] == nil { wake(key) }
            deliverNext(key)
            command.limitTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                guard let self, command.continuation != nil else { return }
                self.forget(command)
                if command.acknowledged {
                    command.finish(.failure(AutomationToolError(
                        .timeout, "The call did not finish within \(milliseconds) ms (it keeps running in the worker)")))
                } else {
                    command.finish(.failure(AutomationToolError(
                        .workerNotRunning, Self.notRunningMessage(milliseconds: milliseconds,
                                                                  hasParked: self.hasParked(key)))))
                }
            }
        }
    }

    static func notRunningMessage(milliseconds: Int, hasParked: Bool) -> String {
        if hasParked {
            return "The extension's background did not take the command within \(milliseconds) ms"
        }
        return "The extension's background did not start or did not open the automation channel within "
            + "\(milliseconds) ms (a background that started before automation was turned on opens it at its next start)"
    }

    // MARK: Lifecycle

    /// The context was unloaded (disabled, uninstalled, reloaded): its parks
    /// are dead and nothing will answer what waits for it.
    func contextUnloaded(extensionID: String, profileID: UUID) {
        let key = Key(extensionID: extensionID, profileID: profileID)
        parks.removeValue(forKey: key)?.reply(["stop": true], nil)
        lastInstance[key] = nil
        failAll(key, AutomationToolError(.workerNotRunning, "The extension was unloaded"))
    }

    private func closeAll() {
        for park in parks.values { park.reply(["stop": true], nil) }
        parks.removeAll()
        lastInstance.removeAll()
        let keys = Set(queues.keys).union(delivered.values.map(\.key))
        for key in keys {
            failAll(key, AutomationToolError(.workerNotRunning, "Automation was turned off"))
        }
    }

    private func failAll(_ key: Key, _ error: AutomationToolError) {
        let waiting = (queues.removeValue(forKey: key) ?? []) + delivered.values.filter { $0.key == key }
        for command in waiting {
            delivered[command.id] = nil
            command.finish(.failure(error))
        }
    }

    // MARK: Delivery

    /// Sends the oldest waiting command to the park, if both are there. One
    /// command per park: the background parks again once it has taken it.
    private func deliverNext(_ key: Key) {
        guard var queue = queues[key], !queue.isEmpty, let park = parks.removeValue(forKey: key) else { return }
        let command = queue.removeFirst()
        queues[key] = queue.isEmpty ? nil : queue
        command.deliveredTo = park.instance
        command.acknowledged = false
        command.deliveries += 1
        delivered[command.id] = command
        park.reply(["command": command.payload], nil)

        let wait = ackTimeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, self.delivered[command.id] === command, !command.acknowledged,
                  command.deliveredTo == park.instance else { return }
            // Never taken: the park belonged to a background WebKit has
            // unloaded. Start it, and send the command to its new park.
            self.delivered[command.id] = nil
            command.deliveredTo = nil
            guard command.deliveries < Self.maximumDeliveries else {
                command.finish(.failure(AutomationToolError(
                    .workerNotRunning, "The extension's background never took the command")))
                return
            }
            log.debug("Automation command \(command.id) not acknowledged by \(key.extensionID, privacy: .public); starting its background")
            self.queues[key, default: []].insert(command, at: 0)
            if self.parks[key] == nil { self.wake(key) }
            self.deliverNext(key)
        }
    }

    private func forget(_ command: Command) {
        if delivered[command.id] === command { delivered[command.id] = nil }
        queues[command.key]?.removeAll { $0 === command }
        if queues[command.key]?.isEmpty == true { queues[command.key] = nil }
    }

    /// Starts the background of `key`'s context, if it is loaded and not
    /// running; WebKit answers at once when it is.
    static func loadBackground(_ key: Key) {
        guard let profile = TabStore.shared.profiles.first(where: { $0.id == key.profileID }),
              !profile.isIncognito,
              let context = profile.extensionContext(for: key.extensionID) else { return }
        context.loadBackgroundContent { error in
            if let error {
                log.error("Automation: the background of \(key.extensionID, privacy: .public) did not load: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: The runner

    /// `__detourAutomationRun(command)`: runs one command and resolves with
    /// its result as a JSON string, never rejecting. `call` calls the
    /// function at `path` (dotted, from the global scope; a leading
    /// `globalThis`, `self` or `window` is skipped) on the object holding it,
    /// with `args` (a JSON array string), and awaits what it returns; `get`
    /// reads the value at `path` (a promise is not awaited); `ping` answers
    /// the context kind and URL; `probe` answers, for each dotted path in
    /// `args` (a JSON array, at most `probeLimit`), whether it is there, its
    /// `typeof`, and whether the function (or an event's `addListener`) is
    /// WebKit's own (`native`), for the compatibility report. Results go
    /// through `AutomationPage`'s
    /// serialiser, so any value comes back. A missing member, or a call of
    /// something that is not a function, is a TypeError like the one the
    /// extension would get. Shared by the worker module and by calls into
    /// popup and options pages. `let`/`const` only.
    /// The most paths one `probe` answers for.
    static let probeLimit = 4000

    static let runnerJS = """
        const __detourAutomationRun = async (command) => {
          \(AutomationPage.plainFunction)
          const maximum = \(AutomationPage.maximumResultLength);
          const id = command && typeof command.id === 'number' ? command.id : null;
          const typeOf = (value) => {
            if (value === null) return 'null';
            if (Array.isArray(value)) return 'array';
            if (value instanceof Error) return 'error';
            return typeof value;
          };
          const succeed = (value) => {
            const plain = __detourPlain(value);
            const type = typeOf(value);
            let json = JSON.stringify({ id, ok: true, type, value: plain });
            if (json.length > maximum) {
              json = JSON.stringify({ id, ok: true, type, truncated: true, value: JSON.stringify(plain).slice(0, maximum) });
            }
            return json;
          };
          try {
            const op = command ? command.op : null;
            if (op === 'ping') {
              let url = null;
              try { url = String(globalThis.location.href); } catch (error) {}
              return succeed({ kind: globalThis.__detourContextKind || null, url });
            }
            if (op === 'probe') {
              const paths = typeof command.args === 'string' && command.args !== '' ? JSON.parse(command.args) : [];
              if (!Array.isArray(paths)) throw new TypeError('probe takes a JSON array of paths');
              const nativeness = typeof globalThis.__detourNativeness === 'function' ? globalThis.__detourNativeness : null;
              const out = {};
              for (const raw of paths.slice(0, \(probeLimit))) {
                const path = String(raw);
                const parts = path.split('.');
                let value = globalThis;
                let present = true;
                try {
                  for (let index = 0; index < parts.length; index++) {
                    if (value === null || (typeof value !== 'object' && typeof value !== 'function')) {
                      present = false;
                      value = undefined;
                      break;
                    }
                    const owner = value;
                    value = owner[parts[index]];
                    // A member (chrome.ns.member) that is there with the value
                    // undefined (runtime.lastError) is present; a namespace
                    // WebKit hides reads undefined and is not.
                    if (value === undefined && !(index >= 2 && parts[index] in owner)) {
                      present = false;
                      break;
                    }
                  }
                  const callable = typeof value === 'function' ? value
                    : (value && typeof value === 'object' && typeof value.addListener === 'function' ? value.addListener : null);
                  out[path] = {
                    present,
                    type: present ? (value === null ? 'null' : typeof value) : 'undefined',
                    native: callable && nativeness ? nativeness(callable) === 'native' : null
                  };
                } catch (error) {
                  out[path] = { present: false, type: 'error', native: null,
                                error: String(error && error.message ? error.message : error) };
                }
              }
              return succeed(out);
            }
            if (op !== 'call' && op !== 'get') throw new TypeError('Unknown automation command ' + String(op));
            const path = String(command.path || '');
            const parts = path.split('.');
            if (path === '' || parts.some((part) => part === '')) throw new TypeError('Not a dotted path: "' + path + '"');
            const first = (parts[0] === 'globalThis' || parts[0] === 'self' || parts[0] === 'window') ? 1 : 0;
            let owner = globalThis;
            let value = globalThis;
            for (let index = first; index < parts.length; index++) {
              if (value === null || value === undefined) {
                throw new TypeError(parts.slice(0, index).join('.') + ' is ' + String(value));
              }
              owner = value;
              value = value[parts[index]];
            }
            if (op === 'get') return succeed(value);
            if (typeof value !== 'function') {
              throw new TypeError(path + ' is not a function (it is ' + (value === null ? 'null' : typeof value) + ')');
            }
            const args = typeof command.args === 'string' && command.args !== '' ? JSON.parse(command.args) : [];
            if (!Array.isArray(args)) throw new TypeError('args must be a JSON array');
            return succeed(await value.apply(owner, args));
          } catch (error) {
            const isError = error instanceof Error;
            let message;
            try { message = isError ? String(error.message) : JSON.stringify(__detourPlain(error)); }
            catch (inner) { message = '[Unreadable]'; }
            return JSON.stringify({ id, ok: false, name: isError ? String(error.name) : null, message,
                                    stack: isError && error.stack ? String(error.stack) : null,
                                    thrown_type: typeOf(error) });
          }
        };
        """

    /// The `callAsyncJavaScript` body that runs `command` in an extension
    /// page (popup, options): the same runner, in the page's world.
    static let pageCommandBody = runnerJS + "\nreturn await __detourAutomationRun(command);"

    /// The polyfill module (`ExtensionAPIPolyfill`): in the background
    /// context only, park for commands; acknowledge each one, park again, run
    /// it, and send its result when it settles. A command seen before (sent
    /// again after a late acknowledgement) is acknowledged and not run twice.
    /// Stops for good when told to (the channel was closed when it asked, or a
    /// newer park superseded it) or refused.
    static let polyfillModuleJS = """
        (function() {
            const g = globalThis;
            const kind = g.__detourContextKind;
            if (kind !== 'worker' && kind !== 'background-page') return;
            if (typeof g.__detourPolyfillRequest !== 'function') return;
            const request = g.__detourPolyfillRequest;
            const instance = g.__detourContextInstance;
            \(runnerJS)
            const ignore = function() {};
            const seen = new Set();
            const send = function(type, params) {
                try { request(type, params).then(null, ignore); } catch (e) {}
            };
            const park = function() {
                let pending;
                try { pending = request('automation.awaitCommand', { instance: instance }); } catch (e) { return; }
                pending.then(function(reply) {
                    if (!reply || typeof reply !== 'object' || reply.stop === true) return;
                    const command = reply.command;
                    if (command && typeof command === 'object') {
                        send('automation.ack', { instance: instance, id: command.id });
                        if (!seen.has(command.id)) {
                            if (seen.size >= 1000) seen.clear();
                            seen.add(command.id);
                            __detourAutomationRun(command).then(function(json) {
                                send('automation.result', { instance: instance, result: json });
                            });
                        }
                    }
                    park();
                }, ignore);
            };
            park();
        })();
        """
}
