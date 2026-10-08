import Foundation
public struct HTTPRequest: Sendable {
    public let url: URL; public let headers: [String:String]
    public init(url: URL, headers: [String:String] = [:]) { self.url = url; self.headers = headers }
}
public struct HTTPResponse: Sendable {
    public let status: Int; public let headers: [String:String]; public let body: Data
    public init(status: Int, headers: [String:String] = [:], body: Data = Data()) { self.status = status; self.headers = Dictionary(headers.map { ($0.key.lowercased(),$0.value) }, uniquingKeysWith: { _, last in last }); self.body = body }
}
public protocol HTTPClient: Sendable { func send(_ request: HTTPRequest) async throws -> HTTPResponse }
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false; config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config,delegate: NoRedirectDelegate(),delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.scheme == "https", ["www.meteo.cat","static-m.meteo.cat"].contains(request.url.host ?? ""), request.url.user == nil, request.url.password == nil else { throw MeteocatError("URL de Meteocat no vàlida.") }
        var req = URLRequest(url: request.url,cachePolicy: .reloadIgnoringLocalCacheData,timeoutInterval: 12); req.httpMethod = "GET"
        for (key,value) in request.headers { req.setValue(value,forHTTPHeaderField: key) }
        let (stream,response) = try await session.bytes(for: req)
        guard let response = response as? HTTPURLResponse else { throw MeteocatError("Resposta HTTP no vàlida.") }
        guard response.expectedContentLength <= PNGDecoder.maximumBytes else { throw MeteocatError("Resposta massa gran.") }
        var body = Data(); body.reserveCapacity(max(0,min(Int(response.expectedContentLength),PNGDecoder.maximumBytes)))
        for try await byte in stream {
            try Task.checkCancellation()
            guard body.count < PNGDecoder.maximumBytes else { throw MeteocatError("Resposta massa gran.") }; body.append(byte)
        }
        var headers = [String:String](); for (key,value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return HTTPResponse(status: response.statusCode,headers: headers,body: body)
    }
}
