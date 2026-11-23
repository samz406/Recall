import Foundation

/// Finds model servers running on this Mac. Only loopback addresses are probed; nothing is sent
/// beyond a request for the model list.
public struct LocalModelServer: Sendable, Equatable, Identifiable {
    public var id: String { baseURL }
    public var name: String
    public var baseURL: String
    public var models: [String]
}

public enum LocalModelDiscovery {
    public static let candidates: [(name: String, baseURL: String)] = [
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1")
    ]

    public static func discover(timeout: TimeInterval = 1.5, session: URLSession = .shared) async -> [LocalModelServer] {
        await withTaskGroup(of: LocalModelServer?.self) { group in
            for candidate in candidates {
                group.addTask { await probe(name: candidate.name, baseURL: candidate.baseURL, timeout: timeout, session: session) }
            }
            var found: [LocalModelServer] = []
            for await server in group { if let server { found.append(server) } }
            return found.sorted { $0.name < $1.name }
        }
    }

    static func probe(name: String, baseURL: String, timeout: TimeInterval, session: URLSession) async -> LocalModelServer? {
        guard LLMConfiguration.isLoopback(baseURL), let url = URL(string: baseURL + "/models") else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return LocalModelServer(name: name, baseURL: baseURL, models: modelNames(from: data))
    }

    /// OpenAI-compatible `{"data":[{"id":...}]}`. Embedding models are listed last since they cannot chat.
    public static func modelNames(from data: Data) -> [String] {
        struct List: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        let names = (try? JSONDecoder().decode(List.self, from: data))?.data.map(\.id) ?? []
        return names.filter { !$0.lowercased().contains("embed") } + names.filter { $0.lowercased().contains("embed") }
    }
}
