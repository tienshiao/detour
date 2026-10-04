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
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.detourbrowser.mac"
        return ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: ruleListDirectory),
            filterListCacheDirectory: cacheDirectory,
            defaults: UserDefaults(suiteName: "\(bundleIdentifier).\(name)") ?? .standard
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

    /// Whether a compiled rule is an exception: its action undoes the rules
    /// before it in the same rule list.
    static func isException(_ rule: [String: Any]) -> Bool {
        (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules"
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

    init(storage: ContentBlockerStorage = .current, maxRulesPerList: Int = ContentRuleStore.defaultMaxRulesPerList) {
        ruleListStore = storage.ruleListStore
        defaults = storage.defaults
        self.maxRulesPerList = maxRulesPerList
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
    /// it was.
    ///
    /// When at least one chunk compiled, the list is recorded as having this
    /// many chunks and the chunks a longer previous compile left behind are
    /// removed from WebKit's store. A chunk that failed keeps whatever an
    /// earlier compile left under its identifier.
    func compile(identifier: String, rules: [[String: Any]], completion: @escaping ([WKContentRuleList]) -> Void) {
        let chunks = ContentRuleListChunks.chunks(of: rules, maxRulesPerList: maxRulesPerList,
                                                  isException: ContentRuleListChunks.isException)
        guard !chunks.isEmpty else {
            completion([])
            return
        }
        if chunks.count > 1 {
            log.info("Splitting \(identifier, privacy: .public) into \(chunks.count) chunks (\(rules.count) rules)")
        }
        if rules.count > maxRulesPerList {
            let dropped = ContentRuleListChunks.droppedExceptionCount(
                ruleCount: rules.count, exceptionCount: rules.lazy.filter(ContentRuleListChunks.isException).count,
                maxRulesPerList: maxRulesPerList)
            if dropped > 0 {
                log.error("\(identifier, privacy: .public) has more exceptions than a split list can carry: \(dropped) left out")
            }
        }

        let group = DispatchGroup()
        var compiledAny = false
        for (index, chunk) in chunks.enumerated() {
            let chunkIdentifier = ContentRuleListChunks.identifier(forList: identifier, chunk: index)
            group.enter()
            compileChunk(identifier: chunkIdentifier, rules: chunk.rules,
                         countedRuleCount: chunk.countedRuleCount) { list in
                if list != nil { compiledAny = true }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, compiledAny else {
                completion([])
                return
            }
            self.recordChunkCount(chunks.count, forList: identifier)
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
    private func compileChunk(identifier: String, rules: [[String: Any]], countedRuleCount: Int,
                              completion: @escaping (WKContentRuleList?) -> Void) {
        guard !rules.isEmpty else {
            completion(nil)
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rules),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            log.error("Failed to serialize rules for \(identifier, privacy: .public)")
            completion(nil)
            return
        }

        ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
            if let error {
                log.error("Compile error for \(identifier, privacy: .public): \(error.localizedDescription)")
                // Try to recover by stripping bad rules via binary search
                self?.compileWithFallback(identifier: identifier, rules: rules,
                                          countedRuleCount: countedRuleCount, completion: completion)
                return
            }
            if let self, let list {
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

    // MARK: - Fallback Compilation

    /// When full compilation fails, use binary search to find and strip only the bad rules.
    private func compileWithFallback(identifier: String, rules: [[String: Any]], countedRuleCount: Int,
                                     completion: @escaping (WKContentRuleList?) -> Void) {
        log.info("Fallback: binary search for bad rules in \(rules.count) rules for \(identifier, privacy: .public)")

        findBadRules(rules: rules, offset: 0, depth: 0, identifier: identifier) { [weak self] badIndices in
            let badSet = Set(badIndices)

            guard !badSet.isEmpty else {
                // No individual bad rules found — the failure may be due to combined NFA state limits.
                // The full set fails but each half passes, so nothing to strip.
                log.error("Fallback: no individual bad rules found for \(identifier, privacy: .public), compilation not possible")
                completion(nil)
                return
            }

            let cleaned = rules.enumerated().compactMap { badSet.contains($0.offset) ? nil : $0.element }
            // A stripped rule only lowers the count when it was a counted one.
            let countedAfterStripping = countedRuleCount - badSet.lazy.filter { $0 < countedRuleCount }.count
            log.info("Stripped \(badSet.count) bad rule(s), recompiling \(cleaned.count) for \(identifier, privacy: .public)")

            guard let jsonData = try? JSONSerialization.data(withJSONObject: cleaned),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                completion(nil)
                return
            }

            self?.ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
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
        }
    }

    /// Recursively bisects rules to find indices of individually bad rules.
    private func findBadRules(rules: [[String: Any]], offset: Int, depth: Int, identifier: String, completion: @escaping ([Int]) -> Void) {
        // Bail out if recursion is too deep
        guard depth <= 20 else {
            log.warning("Binary search: max depth reached, marking \(rules.count) rules as bad at offset \(offset)")
            completion(Array(offset..<offset + rules.count))
            return
        }

        // Test if this chunk compiles
        let probeID = "\(identifier)-probe-\(offset)-\(rules.count)"
        testCompile(rules: rules, identifier: probeID) { [weak self] success in
            if success {
                // All rules in this chunk are fine
                completion([])
                return
            }

            if rules.count == 1 {
                // Found a single bad rule
                log.info("Binary search: found bad rule at index \(offset)")
                completion([offset])
                return
            }

            // Split in half and recurse serially (left then right)
            let mid = rules.count / 2
            let leftRules = Array(rules[..<mid])
            let rightRules = Array(rules[mid...])

            self?.findBadRules(rules: leftRules, offset: offset, depth: depth + 1, identifier: identifier) { leftBad in
                self?.findBadRules(rules: rightRules, offset: offset + mid, depth: depth + 1, identifier: identifier) { rightBad in
                    completion(leftBad + rightBad)
                }
            }
        }
    }

    private func testCompile(rules: [[String: Any]], identifier: String, completion: @escaping (Bool) -> Void) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: rules),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            completion(false)
            return
        }

        ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
            if list != nil {
                self?.ruleListStore.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
            completion(error == nil)
        }
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
