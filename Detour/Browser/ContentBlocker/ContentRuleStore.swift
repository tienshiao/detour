import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "content-blocker")

/// Where the content blocker keeps its compiled rule lists, downloaded filter
/// list text and bookkeeping defaults (TASK-36).
///
/// WebKit's default rule list store lives in
/// `~/Library/WebKit/<bundle id>/ContentRuleLists/`, and the standard defaults
/// domain is the bundle id's, so both are shared by every process with the
/// production app's bundle id: the test host and isolated `DETOUR_DATA_DIR` runs
/// would compile into, and refresh, the production app's lists. The default
/// data directory keeps exactly what it used before; any other data directory
/// gets its own store, cache and defaults suite.
struct ContentBlockerStorage {
    let ruleListStore: WKContentRuleListStore
    let filterListCacheDirectory: URL
    let defaults: UserDefaults

    /// The storage of this process's data directory.
    static let current = forDataDirectory(named: WebKitStorageScope.currentDataDirectoryName)

    static func forDataDirectory(named name: String) -> ContentBlockerStorage {
        let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        let cacheDirectory = dataDirectory.appendingPathComponent("ContentBlocker", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        guard name != defaultDetourDataDirectoryName else {
            return ContentBlockerStorage(
                ruleListStore: .default(), filterListCacheDirectory: cacheDirectory, defaults: .standard)
        }
        let ruleListDirectory = dataDirectory.appendingPathComponent("ContentRuleLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: ruleListDirectory, withIntermediateDirectories: true)
        return ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: ruleListDirectory),
            filterListCacheDirectory: cacheDirectory,
            defaults: UserDefaultsScope.suiteName(dataDirectory: name).flatMap { UserDefaults(suiteName: $0) } ?? .standard
        )
    }
}

/// The arithmetic of a filter list that needs more than one
/// `WKContentRuleList` (TASK-145).
///
/// WebKit compiles a rule list only up to a number of rules, so a longer
/// filter list is compiled in chunks of at most that many: chunk 0 under the
/// list's own identifier, chunk N under `<identifier>-<N>`. Each chunk is a
/// rule list of its own in WebKit's store and nothing there ties them
/// together, so `ContentRuleStore` attaches, counts, looks up and removes them
/// as a set.
///
/// WebKit also evaluates each rule list on its own: an `ignore-previous-rules`
/// rule (an `@@` exception) only undoes rules earlier in its own list. So a
/// split list's chunks are not plain slices: every chunk ends with the list's
/// exceptions (`chunks(of:maxRulesPerList:isException:)`, TASK-155).
enum ContentRuleListChunks {
    /// One rule list of a filter list.
    struct Chunk<Rule> {
        /// What is compiled, at most the cap.
        let rules: [Rule]
        /// How many of `rules`, counted from the start, the list's rule count
        /// includes. The exceptions every chunk repeats are counted in the
        /// first chunk only, so there they are part of this number and in the
        /// later chunks they are the tail it leaves out.
        let countedRuleCount: Int
    }

    /// The most exceptions a split list's chunks carry: half the cap, so
    /// every chunk still has room for at least as many block rules and the
    /// number of chunks at most doubles.
    static func maxCarriedExceptions(maxRulesPerList: Int) -> Int {
        max(maxRulesPerList, 0) / 2
    }

    /// The rule lists `rules` compile into.
    ///
    /// A list within the cap is one chunk, in list order, as it always was.
    /// A longer one is split so that exceptions keep working: the rules that
    /// are not exceptions are sliced in list order, and every slice is
    /// followed by the list's exceptions, which therefore come after, and
    /// undo, the block rules of every chunk. A slice holds the cap less the
    /// exceptions it carries.
    ///
    /// Exceptions beyond `maxCarriedExceptions` are left out of a split list:
    /// each would have to be in every chunk, and past that point the chunks
    /// would hold little else. `droppedExceptionCount` says how many.
    static func chunks<Rule>(of rules: [Rule], maxRulesPerList: Int,
                             isException: (Rule) -> Bool) -> [Chunk<Rule>] {
        guard !rules.isEmpty, maxRulesPerList > 0 else { return [] }
        guard rules.count > maxRulesPerList else {
            return [Chunk(rules: rules, countedRuleCount: rules.count)]
        }

        var blocking: [Rule] = []
        var exceptions: [Rule] = []
        for rule in rules {
            if isException(rule) { exceptions.append(rule) } else { blocking.append(rule) }
        }
        let carried = Array(exceptions.prefix(maxCarriedExceptions(maxRulesPerList: maxRulesPerList)))
        // Nothing to exempt: the exceptions alone, which undo nothing.
        guard !blocking.isEmpty else {
            return carried.isEmpty ? [] : [Chunk(rules: carried, countedRuleCount: carried.count)]
        }
        let slices = ruleRanges(ruleCount: blocking.count, maxRulesPerList: maxRulesPerList - carried.count)
        return slices.enumerated().map { index, range in
            Chunk(rules: Array(blocking[range]) + carried,
                  countedRuleCount: range.count + (index == 0 ? carried.count : 0))
        }
    }

    /// How many of a list's exceptions `chunks(of:…)` leaves out: none for a
    /// list within the cap, otherwise the ones beyond `maxCarriedExceptions`.
    static func droppedExceptionCount(ruleCount: Int, exceptionCount: Int, maxRulesPerList: Int) -> Int {
        guard ruleCount > maxRulesPerList else { return 0 }
        return max(exceptionCount - maxCarriedExceptions(maxRulesPerList: maxRulesPerList), 0)
    }

    /// The rule lists the parser's output compiles into: `chunks(of:…)`,
    /// with every exception carried to the end of each chunk except the
    /// page-wide ones ahead of the list's first block rule (TASK-199).
    ///
    /// Those are the parser's `$generichide` / `$elemhide` exceptions. In list
    /// order they undo only the element hiding before them; carried behind a
    /// chunk's block rules they would undo those too, on every page they name.
    /// So they keep their place, and the element-hiding section, which the
    /// parser puts first, stays together at the start of the first chunk as
    /// long as it is shorter than a chunk. A page-wide exception after the
    /// first block rule (a `$document` allowlist) is carried like any other.
    static func chunks(ofCompiledRules rules: [[String: Any]], maxRulesPerList: Int) -> [Chunk<[String: Any]>] {
        let carried = carriedExceptions(rules)
        return chunks(of: Array(rules.indices), maxRulesPerList: maxRulesPerList) { carried[$0] }
            .map { Chunk(rules: $0.rules.map { rules[$0] }, countedRuleCount: $0.countedRuleCount) }
    }

    /// How many of the rules `chunks(ofCompiledRules:…)` carries into every
    /// chunk of a split list.
    static func carriedExceptionCount(ofCompiledRules rules: [[String: Any]]) -> Int {
        carriedExceptions(rules).lazy.filter { $0 }.count
    }

    private static func carriedExceptions(_ rules: [[String: Any]]) -> [Bool] {
        let firstBlock = rules.firstIndex { actionType($0) == "block" } ?? rules.endIndex
        return rules.indices.map { index in
            isException(rules[index]) && !(index < firstBlock && isPageWideException(rules[index]))
        }
    }

    /// Whether a compiled rule is a page-wide exception: it undoes the rules
    /// before it for every load (`url-filter` `.*`) of the pages its condition
    /// names (`EasyListParser`'s `$generichide`, `$elemhide` and `$document`
    /// rules).
    static func isPageWideException(_ rule: [String: Any]) -> Bool {
        isException(rule) && (rule["trigger"] as? [String: Any])?["url-filter"] as? String == ".*"
    }

    private static func actionType(_ rule: [String: Any]) -> String? {
        (rule["action"] as? [String: Any])?["type"] as? String
    }

    /// Whether a compiled rule is an exception: its action undoes the rules
    /// before it in the same rule list.
    static func isException(_ rule: [String: Any]) -> Bool {
        actionType(rule) == "ignore-previous-rules"
    }

    /// How many rule lists `ruleCount` rules compile into; 0 for no rules.
    static func chunkCount(ruleCount: Int, maxRulesPerList: Int) -> Int {
        guard ruleCount > 0, maxRulesPerList > 0 else { return 0 }
        return (ruleCount + maxRulesPerList - 1) / maxRulesPerList
    }

    /// The identifier chunk `index` of the list `base` is compiled under.
    static func identifier(forList base: String, chunk index: Int) -> String {
        index == 0 ? base : "\(base)-\(index)"
    }

    /// The identifiers of a list compiled as `chunkCount` chunks, in order.
    static func identifiers(forList base: String, chunkCount: Int) -> [String] {
        (0 ..< max(chunkCount, 0)).map { identifier(forList: base, chunk: $0) }
    }

    /// The slice of the rules each chunk holds, in order.
    static func ruleRanges(ruleCount: Int, maxRulesPerList: Int) -> [Range<Int>] {
        guard ruleCount > 0, maxRulesPerList > 0 else { return [] }
        return stride(from: 0, to: ruleCount, by: maxRulesPerList).map { $0 ..< min($0 + maxRulesPerList, ruleCount) }
    }

    /// The chunk identifiers a compile of `previousChunkCount` chunks left
    /// behind once the list compiles as `chunkCount`: the ones to remove from
    /// WebKit's store when a list shrinks. The list's own identifier is every
    /// compile's first chunk and is never among them.
    static func staleIdentifiers(forList base: String, previousChunkCount: Int, chunkCount: Int) -> [String] {
        let firstStale = max(chunkCount, 1)
        guard previousChunkCount > firstStale else { return [] }
        return (firstStale ..< previousChunkCount).map { identifier(forList: base, chunk: $0) }
    }
}

/// Compiles filter lists into WebKit rule lists and keeps them, by list and
/// chunk.
///
/// Threading (TASK-200): `compile`, `lookUpList` and every other method are
/// called on the main queue, and all state here is main-queue state.
/// `WKContentRuleListStore` must be called on main (`WK_SWIFT_UI_ACTOR`;
/// WebKit asserts `RunLoop::isMain()` in each call and completes on main).
/// The CPU work of a compile that is ours runs on `workQueue`: splitting the
/// rules into chunks, encoding each chunk to the JSON WebKit takes (about
/// 270 ms for EasyList), and, when WebKit refuses a chunk, slicing and
/// encoding every probe of the bad-rule search and the cleaned chunk.
///
/// Compiles of one list run one at a time in call order: a compile waits
/// until the previous compile of its list has completed, bad-rule search
/// included, so a slower earlier compile can never record its list over a
/// later one. Different lists compile independently.
class ContentRuleStore {
    /// The most rules handed to WebKit as one rule list.
    static let defaultMaxRulesPerList = 150_000

    private let ruleListStore: WKContentRuleListStore
    private let defaults: UserDefaults
    /// Compiled rule lists by **chunk** identifier (`ContentRuleListChunks`).
    private var compiledLists: [String: WKContentRuleList] = [:]
    /// The rules each chunk adds to its list's count, by chunk identifier: the
    /// rules compiled into it, less the exceptions it repeats from the first
    /// chunk (`ContentRuleListChunks.Chunk.countedRuleCount`).
    private var compiledRuleCounts: [String: Int] = [:]
    /// How many chunks each list's last compile produced, by list identifier.
    /// Filled from the defaults on first use; read it through
    /// `chunkCount(forList:)`.
    private var chunkCounts: [String: Int] = [:]
    /// Injected so a test can split a handful of rules instead of compiling
    /// 150,000 real ones.
    private let maxRulesPerList: Int

    /// Turns rules into the JSON WebKit compiles; called on `workQueue` only.
    typealias RuleListEncoder = ([[String: Any]]) -> String?
    /// Serial, so the chunks of a list, and the lists, reach WebKit in the
    /// order they were asked for.
    private let workQueue: DispatchQueue
    private let encode: RuleListEncoder
    /// The compiles waiting for the running compile of their list, by list
    /// identifier. A list has an entry while one of its compiles runs.
    private var waitingCompiles: [String: [() -> Void]] = [:]

    /// `workQueue` and `encode` are injected so a test can see where the
    /// encoding runs.
    init(storage: ContentBlockerStorage = .current, maxRulesPerList: Int = ContentRuleStore.defaultMaxRulesPerList,
         workQueue: DispatchQueue = DispatchQueue(label: "com.detourbrowser.content-rule-store", qos: .utility),
         encode: @escaping RuleListEncoder = ContentRuleStore.encodedRuleList) {
        ruleListStore = storage.ruleListStore
        defaults = storage.defaults
        self.maxRulesPerList = maxRulesPerList
        self.workQueue = workQueue
        self.encode = encode
    }

    /// The JSON WebKit compiles a rule list from. Never on the main queue: it
    /// takes a few hundred milliseconds for a real list.
    static func encodedRuleList(_ rules: [[String: Any]]) -> String? {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - A list and its chunks

    private func compiledRuleCountKey(_ chunkIdentifier: String) -> String {
        "ContentBlocker.\(chunkIdentifier).compiledRuleCount"
    }

    private func chunkCountKey(_ listIdentifier: String) -> String {
        "ContentBlocker.\(listIdentifier).chunkCount"
    }

    /// How many rule lists the list is compiled as: what its last compile
    /// recorded, and 1 for a list that has never been split (no key is
    /// written for those).
    private func chunkCount(forList identifier: String) -> Int {
        if let count = chunkCounts[identifier] { return count }
        let count = max(defaults.object(forKey: chunkCountKey(identifier)) as? Int ?? 1, 1)
        chunkCounts[identifier] = count
        return count
    }

    private func chunkIdentifiers(forList identifier: String) -> [String] {
        ContentRuleListChunks.identifiers(forList: identifier, chunkCount: chunkCount(forList: identifier))
    }

    /// Every compiled chunk of the list, in order: what a web view of a
    /// profile that has the list switched on must be given. Empty when the
    /// list is not compiled.
    func cachedLists(forList identifier: String) -> [WKContentRuleList] {
        chunkIdentifiers(forList: identifier).compactMap { compiledLists[$0] }
    }

    /// The rules compiled into the list, summed over its chunks, with an
    /// exception every chunk repeats counted once; nil when none is known.
    func compiledRuleCount(forList identifier: String) -> Int? {
        let counts = chunkIdentifiers(forList: identifier).compactMap { compiledRuleCounts[$0] }
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// Whether any chunk of the list is compiled and can be attached. A list
    /// one of whose chunks failed to compile still counts: the rest is
    /// active, and `compiledRuleCount(forList:)` shows what is missing.
    func isCompiled(list identifier: String) -> Bool {
        !cachedLists(forList: identifier).isEmpty
    }

    /// Looks the list's chunks up in WebKit's store (the launch path: nothing
    /// is in memory yet) and completes, on the main queue, with the ones
    /// found. Empty means the list has to be compiled.
    func lookUpList(identifier: String, completion: @escaping ([WKContentRuleList]) -> Void) {
        let group = DispatchGroup()
        for chunkIdentifier in chunkIdentifiers(forList: identifier) where compiledLists[chunkIdentifier] == nil {
            group.enter()
            ruleListStore.lookUpContentRuleList(forIdentifier: chunkIdentifier) { [weak self] list, _ in
                if let self, let list {
                    self.compiledLists[chunkIdentifier] = list
                    // Restore the compiled count saved by the compile that produced it
                    if let count = self.defaults.object(forKey: self.compiledRuleCountKey(chunkIdentifier)) as? Int {
                        self.compiledRuleCounts[chunkIdentifier] = count
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            completion(self?.cachedLists(forList: identifier) ?? [])
        }
    }

    /// Compiles `rules` as the list `identifier`, in as many chunks as the
    /// cap requires, and completes on the main queue with every chunk of the
    /// list — empty when nothing compiled, in which case the list is left as
    /// it was. Call on the main queue. Starts once the previous compile of
    /// the same list has completed.
    ///
    /// When at least one chunk compiled, the list is recorded as having this
    /// many chunks and the chunks a longer previous compile left behind are
    /// removed from WebKit's store. A chunk that failed keeps whatever an
    /// earlier compile left under its identifier.
    func compile(identifier: String, rules: [[String: Any]], completion: @escaping ([WKContentRuleList]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let start = { [weak self] in
            guard let self else { return completion([]) }
            self.compileNow(identifier: identifier, rules: rules) { [weak self] lists in
                completion(lists)
                self?.startNextCompile(of: identifier)
            }
        }
        if waitingCompiles[identifier] != nil {
            waitingCompiles[identifier]?.append(start)
        } else {
            waitingCompiles[identifier] = []
            start()
        }
    }

    private func startNextCompile(of identifier: String) {
        guard var waiting = waitingCompiles[identifier], !waiting.isEmpty else {
            waitingCompiles[identifier] = nil
            return
        }
        let next = waiting.removeFirst()
        waitingCompiles[identifier] = waiting
        next()
    }

    /// One chunk as handed to WebKit: its rules (kept for the bad-rule
    /// search), how many of them its list counts, and their JSON (nil when
    /// encoding failed).
    private struct EncodedChunk {
        let rules: [[String: Any]]
        let countedRuleCount: Int
        let json: String?
    }

    /// Chunks and encodes the rules on `workQueue`, then compiles every chunk
    /// from the main queue.
    private func compileNow(identifier: String, rules: [[String: Any]], completion: @escaping ([WKContentRuleList]) -> Void) {
        let maxRulesPerList = maxRulesPerList
        let encode = encode
        offMain({ () -> [EncodedChunk] in
            let chunks = ContentRuleListChunks.chunks(ofCompiledRules: rules, maxRulesPerList: maxRulesPerList)
            if chunks.count > 1 {
                log.info("Splitting \(identifier, privacy: .public) into \(chunks.count) chunks (\(rules.count) rules)")
            }
            if rules.count > maxRulesPerList {
                let dropped = ContentRuleListChunks.droppedExceptionCount(
                    ruleCount: rules.count, exceptionCount: ContentRuleListChunks.carriedExceptionCount(ofCompiledRules: rules),
                    maxRulesPerList: maxRulesPerList)
                if dropped > 0 {
                    log.error("\(identifier, privacy: .public) has more exceptions than a split list can carry: \(dropped) left out")
                }
            }
            return chunks.map {
                EncodedChunk(rules: $0.rules, countedRuleCount: $0.countedRuleCount, json: encode($0.rules))
            }
        }, then: { [weak self] encoded in
            guard let self, !encoded.isEmpty else { return completion([]) }
            self.compileChunks(encoded, identifier: identifier, completion: completion)
        })
    }

    private func compileChunks(_ chunks: [EncodedChunk], identifier: String,
                               completion: @escaping ([WKContentRuleList]) -> Void) {
        let group = DispatchGroup()
        var compiledAny = false
        // Only the count outlives the loop: the chunks' JSON is not kept
        // while WebKit compiles.
        let chunkCount = chunks.count
        for (index, chunk) in chunks.enumerated() {
            let chunkIdentifier = ContentRuleListChunks.identifier(forList: identifier, chunk: index)
            group.enter()
            compileChunk(identifier: chunkIdentifier, chunk: chunk) { list in
                if list != nil { compiledAny = true }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, compiledAny else {
                completion([])
                return
            }
            self.recordChunkCount(chunkCount, forList: identifier)
            completion(self.cachedLists(forList: identifier))
        }
    }

    /// Records that the list is now `chunkCount` chunks and removes the
    /// chunks of a previous, longer compile.
    private func recordChunkCount(_ chunkCount: Int, forList identifier: String) {
        let stale = ContentRuleListChunks.staleIdentifiers(
            forList: identifier, previousChunkCount: self.chunkCount(forList: identifier), chunkCount: chunkCount)
        if !stale.isEmpty {
            log.info("\(identifier, privacy: .public) shrank to \(chunkCount) chunk(s), removing \(stale.count) stale chunk(s)")
        }
        for chunkIdentifier in stale {
            removeChunk(chunkIdentifier)
        }

        chunkCounts[identifier] = chunkCount
        // Only a split list needs the key: a missing one reads as one chunk.
        if chunkCount > 1 {
            defaults.set(chunkCount, forKey: chunkCountKey(identifier))
        } else {
            defaults.removeObject(forKey: chunkCountKey(identifier))
        }
    }

    private func removeChunk(_ chunkIdentifier: String) {
        compiledLists.removeValue(forKey: chunkIdentifier)
        compiledRuleCounts.removeValue(forKey: chunkIdentifier)
        defaults.removeObject(forKey: compiledRuleCountKey(chunkIdentifier))
        ruleListStore.removeContentRuleList(forIdentifier: chunkIdentifier) { error in
            if let error {
                log.error("Failed to remove stale chunk \(chunkIdentifier, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - One rule list

    /// Compiles one rule list of at most `maxRulesPerList` rules under
    /// `identifier`, stripping individually bad rules when the whole set is
    /// refused. The first `countedRuleCount` rules are the ones the chunk adds
    /// to its list's rule count.
    private func compileChunk(identifier: String, chunk: EncodedChunk,
                              completion: @escaping (WKContentRuleList?) -> Void) {
        guard !chunk.rules.isEmpty else {
            completion(nil)
            return
        }
        guard let jsonString = chunk.json else {
            log.error("Failed to serialize rules for \(identifier, privacy: .public)")
            completion(nil)
            return
        }

        // The completion keeps the rules for the bad-rule search, not the JSON.
        let rules = chunk.rules
        let countedRuleCount = chunk.countedRuleCount
        ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
            guard let self else { return completion(nil) }
            if let error {
                log.error("Compile error for \(identifier, privacy: .public): \(error.localizedDescription)")
                // Try to recover by stripping bad rules via binary search
                self.compileWithFallback(identifier: identifier, rules: rules,
                                         countedRuleCount: countedRuleCount, completion: completion)
                return
            }
            if let list {
                self.recordCompiled(list, identifier: identifier, countedRuleCount: countedRuleCount)
            }
            completion(list)
        }
    }

    private func recordCompiled(_ list: WKContentRuleList, identifier: String, countedRuleCount: Int) {
        compiledLists[identifier] = list
        compiledRuleCounts[identifier] = countedRuleCount
        defaults.set(countedRuleCount, forKey: compiledRuleCountKey(identifier))
    }

    /// Runs `work` on `workQueue` and hands its result to `then` on the main
    /// queue.
    private func offMain<T>(_ work: @escaping () -> T, then: @escaping (T) -> Void) {
        workQueue.async {
            let result = work()
            DispatchQueue.main.async { then(result) }
        }
    }

    // MARK: - Fallback Compilation

    /// When full compilation fails, use binary search to find and strip only
    /// the bad rules. The search's probes and the cleaned rules are sliced and
    /// encoded on `workQueue`; only WebKit's compile calls are made on main.
    private func compileWithFallback(identifier: String, rules: [[String: Any]], countedRuleCount: Int,
                                     completion: @escaping (WKContentRuleList?) -> Void) {
        log.info("Fallback: binary search for bad rules in \(rules.count) rules for \(identifier, privacy: .public)")

        findBadRules(rules[...], depth: 0, identifier: identifier) { [weak self] badIndices in
            guard let self else { return completion(nil) }
            let badSet = Set(badIndices)

            guard !badSet.isEmpty else {
                // No individual bad rules found — the failure may be due to combined NFA state limits.
                // The full set fails but each half passes, so nothing to strip.
                log.error("Fallback: no individual bad rules found for \(identifier, privacy: .public), compilation not possible")
                completion(nil)
                return
            }

            // A stripped rule only lowers the count when it was a counted one.
            let countedAfterStripping = countedRuleCount - badSet.lazy.filter { $0 < countedRuleCount }.count
            log.info("Stripped \(badSet.count) bad rule(s), recompiling \(rules.count - badSet.count) for \(identifier, privacy: .public)")

            let encode = self.encode
            self.offMain({
                encode(rules.enumerated().compactMap { badSet.contains($0.offset) ? nil : $0.element })
            }, then: { [weak self] jsonString in
                guard let self, let jsonString else { return completion(nil) }
                self.ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
                    if let error {
                        log.error("Fallback compile still failed for \(identifier, privacy: .public): \(error.localizedDescription)")
                        completion(nil)
                        return
                    }
                    if let self, let list {
                        log.info("Fallback compile succeeded for \(identifier, privacy: .public)")
                        self.recordCompiled(list, identifier: identifier, countedRuleCount: countedAfterStripping)
                    }
                    completion(list)
                }
            })
        }
    }

    /// Recursively bisects rules to find indices of individually bad rules.
    /// `rules` is a slice of the chunk, so its indices are the chunk's.
    private func findBadRules(_ rules: ArraySlice<[String: Any]>, depth: Int, identifier: String,
                              completion: @escaping ([Int]) -> Void) {
        // Bail out if recursion is too deep
        guard depth <= 20 else {
            log.warning("Binary search: max depth reached, marking \(rules.count) rules as bad at offset \(rules.startIndex)")
            completion(Array(rules.indices))
            return
        }

        // Test if this chunk compiles
        let probeID = "\(identifier)-probe-\(rules.startIndex)-\(rules.count)"
        testCompile(rules, identifier: probeID) { [weak self] success in
            if success {
                // All rules in this chunk are fine
                completion([])
                return
            }

            if rules.count == 1 {
                // Found a single bad rule
                log.info("Binary search: found bad rule at index \(rules.startIndex)")
                completion([rules.startIndex])
                return
            }

            // Split in half and recurse serially (left then right)
            let mid = rules.startIndex + rules.count / 2
            guard let self else { return completion([]) }
            self.findBadRules(rules[..<mid], depth: depth + 1, identifier: identifier) { [weak self] leftBad in
                guard let self else { return completion(leftBad) }
                self.findBadRules(rules[mid...], depth: depth + 1, identifier: identifier) { rightBad in
                    completion(leftBad + rightBad)
                }
            }
        }
    }

    /// Whether `rules` compile on their own: encoded on `workQueue`, compiled
    /// under the probe's identifier and removed again.
    private func testCompile(_ rules: ArraySlice<[String: Any]>, identifier: String, completion: @escaping (Bool) -> Void) {
        let encode = encode
        offMain({ encode(Array(rules)) }, then: { [weak self] jsonString in
            guard let self, let jsonString else { return completion(false) }
            self.ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
                if list != nil {
                    self?.ruleListStore.removeContentRuleList(forIdentifier: identifier) { _ in }
                }
                completion(error == nil)
            }
        })
    }

    func getAllCachedLists() -> [String: WKContentRuleList] {
        compiledLists
    }

    /// Removes compiled lists nothing owns any more: the per-profile
    /// `content-blocker-whitelist-<uuid>` lists earlier builds compiled (they
    /// encoded the user's whitelisted hosts in `if-domain` triggers) — the
    /// per-site switch no longer uses a rule list (TASK-69). `invalidateAll`
    /// only walks `compiledLists`, so an upgraded install would otherwise keep
    /// them on disk forever with no removal path.
    func removeRetiredLists(withPrefix prefix: String) {
        ruleListStore.getAvailableContentRuleListIdentifiers { [weak self] identifiers in
            for identifier in identifiers ?? [] where identifier.hasPrefix(prefix) {
                self?.ruleListStore.removeContentRuleList(forIdentifier: identifier) { error in
                    if let error {
                        log.error("Failed to remove retired list \(identifier, privacy: .public): \(error.localizedDescription)")
                    }
                }
                self?.compiledLists.removeValue(forKey: identifier)
            }
        }
    }

    /// Removes every compiled chunk of every list from WebKit's store and
    /// forgets the counts and chunk counts that described them.
    func invalidateAll() {
        for chunkIdentifier in compiledLists.keys {
            ruleListStore.removeContentRuleList(forIdentifier: chunkIdentifier) { _ in }
        }
        for chunkIdentifier in Set(compiledLists.keys).union(compiledRuleCounts.keys) {
            defaults.removeObject(forKey: compiledRuleCountKey(chunkIdentifier))
        }
        compiledLists.removeAll()
        compiledRuleCounts.removeAll()
        for listIdentifier in chunkCounts.keys {
            defaults.removeObject(forKey: chunkCountKey(listIdentifier))
        }
        chunkCounts.removeAll()
    }
}
