import Foundation

/// A tiny HTTP request router used in the examples.
struct Router {
    var routes: [String: (Request) -> Response] = [:]
    var fallback: (Request) -> Response = { _ in Response(status: 404, body: "Not Found") }

    mutating func add(_ path: String, handler: @escaping (Request) -> Response) {
        routes[path] = handler
    }

    mutating func remove(_ path: String) {
        routes.removeValue(forKey: path)
    }

    func handle(_ request: Request) -> Response {
        if let h = routes[request.path] {
            return h(request)
        }
        return fallback(request)
    }
}

struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct Response {
    let status: Int
    let body: String
}

let timeout = 45
let maxConnections = 64
print("Server starting at 2025-11-20 14:30:12")
