import Foundation

struct TTCustomLiveKitTokenResponse: Decodable {
    let serverURL: String
    let participantToken: String

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case participantToken = "participant_token"
    }
}

enum TTCustomLiveKitAuthError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(statusCode: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "The server address is invalid"
        case .invalidResponse: return "The server returned an invalid token response"
        case let .server(statusCode, detail): return "Authentication failed (\(statusCode)): \(detail)"
        }
    }
}

struct TTCustomLiveKitAuthClient {
    func requestToken(
        host: String,
        username: String,
        password: String,
        room: String,
        participantName: String,
        participantIdentity: String
    ) async throws -> TTCustomLiveKitTokenResponse {
        let base = host.hasPrefix("http://") || host.hasPrefix("https://")
            ? host
            : "https://\(host)"
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/token") else {
            throw TTCustomLiveKitAuthError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TokenRequest(
            username: username,
            password: password,
            room: room,
            participantName: participantName,
            participantIdentity: participantIdentity
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTCustomLiveKitAuthError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown server error"
            throw TTCustomLiveKitAuthError.server(statusCode: httpResponse.statusCode, detail: detail)
        }
        guard let result = try? JSONDecoder().decode(TTCustomLiveKitTokenResponse.self, from: data) else {
            throw TTCustomLiveKitAuthError.invalidResponse
        }
        return result
    }

    private struct TokenRequest: Encodable {
        let username: String
        let password: String
        let room: String
        let participantName: String
        let participantIdentity: String

        enum CodingKeys: String, CodingKey {
            case username
            case password
            case room
            case participantName = "participant_name"
            case participantIdentity = "participant_identity"
        }
    }
}
