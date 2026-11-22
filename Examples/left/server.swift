import Foundation

/// A tiny HTTP-ish request router used in the examples.
struct Router {
    var routes: [String: (Request) -> Response] = [:]
	var fallback: (Request) -> Response = { _ in Response(status: 404, body: "Not found") }

    mutating func add(_ path: String, handler: @escaping (Request) -> Response) {
        routes[path] = handler
    }

    func handle(_ request: Request) -> Response {
        // Look up an exact match first.
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
}

struct Response {
    let status: Int
    let body: String
}

let timeout = 30
let maxConnections = 64
print("Server starting at 2024-05-01 10:00:00")
