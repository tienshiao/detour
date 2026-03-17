import Foundation
import WebKit

class ContentRuleStore {
    private let ruleListStore = WKContentRuleListStore.default()!
    private var compiledLists: [String: WKContentRuleList] = [:]
    private(set) var compiledRuleCounts: [String: Int] = [:]
    private let maxRulesPerList = 150_000

    func lookupOrCompile(identifier: String, rules: [[String: Any]], completion: @escaping (WKContentRuleList?) -> Void) {
        // Try cached in-memory first
        if let cached = compiledLists[identifier] {
            completion(cached)
            return
        }

        // Try looking up already-compiled rules in WebKit's store
        ruleListStore.lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            if let list {
                self?.compiledLists[identifier] = list
                // Restore compiled count from UserDefaults (saved during prior compilation)
                let key = "ContentBlocker.\(identifier).compiledRuleCount"
                if let count = UserDefaults.standard.object(forKey: key) as? Int {
                    self?.compiledRuleCounts[identifier] = count
                }
                completion(list)
                return
            }
            // Need to compile
            self?.compile(identifier: identifier, rules: rules, completion: completion)
        }
    }

    func compile(identifier: String, rules: [[String: Any]], completion: @escaping (WKContentRuleList?) -> Void) {
        guard !rules.isEmpty else {
            completion(nil)
            return
        }

        // If rules exceed limit, split into chunks
        if rules.count > maxRulesPerList {
            compileSplit(identifier: identifier, rules: rules, completion: completion)
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rules),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[ContentBlocker] Failed to serialize rules for \(identifier)")
            completion(nil)
            return
        }

        ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
            if let error {
                print("[ContentBlocker] Compile error for \(identifier): \(error.localizedDescription)")
                // Try to recover by stripping bad rules via binary search
                self?.compileWithFallback(identifier: identifier, rules: rules, completion: completion)
                return
            }
            if let list {
                self?.compiledLists[identifier] = list
                self?.compiledRuleCounts[identifier] = rules.count
                UserDefaults.standard.set(rules.count, forKey: "ContentBlocker.\(identifier).compiledRuleCount")
            }
            completion(list)
        }
    }

    private func compileSplit(identifier: String, rules: [[String: Any]], completion: @escaping (WKContentRuleList?) -> Void) {
        let chunks = stride(from: 0, to: rules.count, by: maxRulesPerList).map {
            Array(rules[$0..<min($0 + maxRulesPerList, rules.count)])
        }

        print("[ContentBlocker] Splitting \(identifier) into \(chunks.count) chunks (\(rules.count) rules)")

        // Compile first chunk with base identifier, rest with suffixed identifiers
        let group = DispatchGroup()
        var firstList: WKContentRuleList?

        for (index, chunk) in chunks.enumerated() {
            let chunkID = index == 0 ? identifier : "\(identifier)-\(index)"
            group.enter()
            compile(identifier: chunkID, rules: chunk) { list in
                if index == 0 { firstList = list }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            completion(firstList)
        }
    }

    // MARK: - Fallback Compilation

    /// When full compilation fails, compile in batches, keep good batches, discard bad ones.
    private func compileWithFallback(identifier: String, rules: [[String: Any]], completion: @escaping (WKContentRuleList?) -> Void) {
        let batchSize = 5000
        let batches = stride(from: 0, to: rules.count, by: batchSize).map {
            Array(rules[$0..<min($0 + batchSize, rules.count)])
        }
        print("[ContentBlocker] Fallback: testing \(batches.count) batches of ~\(batchSize) for \(identifier)")

        var goodRules: [[String: Any]] = []
        let group = DispatchGroup()
        let lock = NSLock()
        var strippedCount = 0

        for (index, batch) in batches.enumerated() {
            group.enter()
            let probeID = "\(identifier)-probe-\(index)"
            testCompile(rules: batch, identifier: probeID) { success in
                lock.lock()
                if success {
                    goodRules.append(contentsOf: batch)
                } else {
                    strippedCount += batch.count
                    print("[ContentBlocker] Fallback: discarded batch \(index) (\(batch.count) rules) for \(identifier)")
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !goodRules.isEmpty else {
                print("[ContentBlocker] Fallback: no good batches for \(identifier)")
                completion(nil)
                return
            }

            print("[ContentBlocker] Fallback: recompiling \(goodRules.count) rules for \(identifier) (stripped \(strippedCount))")

            guard let jsonData = try? JSONSerialization.data(withJSONObject: goodRules),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                completion(nil)
                return
            }

            self?.ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { [weak self] list, error in
                if let error {
                    print("[ContentBlocker] Fallback compile still failed for \(identifier): \(error.localizedDescription)")
                    completion(nil)
                    return
                }
                if let list {
                    print("[ContentBlocker] Fallback compile succeeded for \(identifier)")
                    self?.compiledLists[identifier] = list
                    self?.compiledRuleCounts[identifier] = goodRules.count
                    UserDefaults.standard.set(goodRules.count, forKey: "ContentBlocker.\(identifier).compiledRuleCount")
                }
                completion(list)
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

    func getCachedList(identifier: String) -> WKContentRuleList? {
        compiledLists[identifier]
    }

    func getAllCachedLists() -> [String: WKContentRuleList] {
        compiledLists
    }

    func removeCachedList(identifier: String) {
        compiledLists.removeValue(forKey: identifier)
        ruleListStore.removeContentRuleList(forIdentifier: identifier) { error in
            if let error {
                print("[ContentBlocker] Remove error for \(identifier): \(error.localizedDescription)")
            }
        }
    }

    func invalidateAll() {
        for id in compiledLists.keys {
            ruleListStore.removeContentRuleList(forIdentifier: id) { _ in }
        }
        compiledLists.removeAll()
    }
}
