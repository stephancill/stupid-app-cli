import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal, credential-safe App Store Connect API client. Issues one request per call,
/// appends the ES256 JWT authorization header, and surfaces API error bodies without
/// ever echoing the raw JWT or request bodies into diagnostic output.
public struct ASCClient: Sendable {
    public var baseURL: URL
    public var jwt: @Sendable () throws -> String
    public var logger: (@Sendable (String) -> Void)?

    public init(baseURL: URL = URL(string: "https://api.appstoreconnect.apple.com/v1")!, jwt: @escaping @Sendable () throws -> String) {
        self.baseURL = baseURL
        self.jwt = jwt
    }

    public enum Method: String {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public struct Response: Sendable {
        public var statusCode: Int
        public var data: Data
        public var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    public func request(
        method: Method,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) throws -> Response {
        var url = baseURL.appendingPathComponent(path)
        if let query, !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            url = components.url!
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(try jwt())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }

        logger?("\(method.rawValue) \(url.path)")
        let (data, response) = try perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw ASCError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            throw ASCError.http(http.statusCode, Self.redactedErrorBody(data))
        }
        return Response(statusCode: http.statusCode, data: data)
    }

    /// Executes a raw request against an arbitrary URL (used for presigned delivery
    /// uploads). No JWT is added and the URL is never logged because presigned URLs
    /// carry their upload capability in the URL itself. The caller must redact any
    /// secret-bearing response detail before surfacing it.
    public func rawRequest(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data,
        timeout: TimeInterval = 300
    ) throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        let (data, response) = try perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw ASCError.invalidResponse
        }
        return Response(statusCode: http.statusCode, data: data)
    }

    /// Performs a request synchronously (Foundation URLSession is async-callback based
    /// on both Darwin and Linux FoundationNetworking).
    private func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var failure: (any Error)?
        }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.failure = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure = box.failure {
            throw ASCError.transport(failure.localizedDescription)
        }
        guard let data = box.data, let response = box.response else {
            throw ASCError.invalidResponse
        }
        return (data, response)
    }

    /// Extracts a concise public-safe API error summary, preserving the errors array
    /// but truncating it to bound output.
    private static func redactedErrorBody(_ data: Data) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Sendable],
              let errors = object["errors"] as? [[String: Sendable]] else {
            return String(decoding: data, as: UTF8.self).prefix(500).description
        }
        let summaries = errors.prefix(5).map { entry -> String in
            let code = entry["code"] as? String ?? ""
            let detail = entry["detail"] as? String ?? ""
            return code.isEmpty ? detail : "\(code): \(detail)"
        }
        return summaries.joined(separator: "\n")
    }
}

public enum ASCError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidResponse
    case transport(String)
    case http(Int, String)
    case malformedPayload(String)

    public var description: String {
        switch self {
        case .invalidResponse:
            return "App Store Connect returned an invalid response."
        case let .transport(detail):
            return "Request to App Store Connect failed: \(detail)"
        case let .http(status, body):
            return "App Store Connect returned HTTP \(status).\n\(body)"
        case let .malformedPayload(detail):
            return "App Store Connect response could not be decoded: \(detail)"
        }
    }
}