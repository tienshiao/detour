import Foundation

final class SearchSuggestionsService {
    static let shared = SearchSuggestionsService()
    private init() {}

    func fetchSuggestions(for query: String, engine: SearchEngine) async -> [String] {
        guard !query.isEmpty,
              let url = engine.suggestionsURL(for: query)
        else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            if engine == .yahoo {
                return parseYahooSuggestions(data)
            }

            // OpenSearch JSON format: ["query", ["sug1", "sug2", ...]]
            if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
               json.count >= 2,
               let suggestions = json[1] as? [String] {
                return Array(suggestions.prefix(5))
            }
        } catch {}
        return []
    }

    private func parseYahooSuggestions(_ data: Data) -> [String] {
        // Yahoo gossip format: {"gossip":{"query":"...","results":[{"key":"sug1"},...]}}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gossip = json["gossip"] as? [String: Any],
              let results = gossip["results"] as? [[String: Any]] else { return [] }
        return Array(results.compactMap { $0["key"] as? String }.prefix(5))
    }
}
