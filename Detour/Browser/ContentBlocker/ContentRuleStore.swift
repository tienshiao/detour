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

    /// When full compilation fails, use binary search to find and strip only the bad rules.
    private func compileWithFallback(identifier: String, rules: [[String: Any]], completion: @escaping (WKContentRuleList?) -> Void) {
        print("[ContentBlocker] Fallback: binary search for bad rules in \(rules.count) rules for \(identifier)")

        findBadRules(rules: rules, offset: 0, depth: 0, identifier: identifier) { [weak self] badIndices in
            let badSet = Set(badIndices)

            guard !badSet.isEmpty else {
                // No individual bad rules found — the failure may be due to combined NFA state limits.
                // The full set fails but each half passes, so nothing to strip.
                print("[ContentBlocker] Fallback: no individual bad rules found for \(identifier), compilation not possible")
                completion(nil)
                return
            }

            let cleaned = rules.enumerated().compactMap { badSet.contains($0.offset) ? nil : $0.element }
            print("[ContentBlocker] Stripped \(badSet.count) bad rule(s), recompiling \(cleaned.count) for \(identifier)")

            guard let jsonData = try? JSONSerialization.data(withJSONObject: cleaned),
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
                    self?.compiledRuleCounts[identifier] = cleaned.count
                    UserDefaults.standard.set(cleaned.count, forKey: "ContentBlocker.\(identifier).compiledRuleCount")
                }
                completion(list)
            }
        }
    }

    /// Recursively bisects rules to find indices of individually bad rules.
    private func findBadRules(rules: [[String: Any]], offset: Int, depth: Int, identifier: String, completion: @escaping ([Int]) -> Void) {
        // Bail out if recursion is too deep
        guard depth <= 20 else {
            print("[ContentBlocker] Binary search: max depth reached, marking \(rules.count) rules as bad at offset \(offset)")
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
                print("[ContentBlocker] Binary search: found bad rule at index \(offset)")
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
