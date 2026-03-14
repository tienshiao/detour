import Foundation

final class SearchSuggestionsService {
    static let shared = SearchSuggestionsService()
    private init() {}

    func fetchSuggestions(for query: String) async -> [String] {
        guard !query.isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)")
        else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // Response format: ["query", ["sug1", "sug2", ...]]
            if let json = try JSONSerialization.jsonObject(with: data) as? [Any],
               json.count >= 2,
               let suggestions = json[1] as? [String] {
                return Array(suggestions.prefix(5))
            }
        } catch {}
        return []
    }
}
