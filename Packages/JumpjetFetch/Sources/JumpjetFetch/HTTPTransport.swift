import Foundation
import JumpjetCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The seam between the clients and the network.
///
/// Every client takes one of these rather than reaching for `URLSession.shared`
/// directly, so the whole fetch layer can be tested against recorded responses
/// with no network, no flakiness and no dependence on what EBI happens to be
/// serving this morning.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

/// The real one.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A transport configured for JUMPjet's usage: short timeouts, because a
    /// user staring at a HUD would rather be told the server is slow than watch
    /// a spinner for a minute, and the system cache disabled because JUMPjet
    /// keeps its own on disk and two caches disagreeing is worse than one.
    public static func standard() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("JUMPjet/1.0 (marcdeller.com)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch let error as URLError {
            throw Self.translate(error, url: url)
        }
    }

    /// Turn a URLError into something the HUD can say.
    ///
    /// `.notConnectedToInternet` and `.networkConnectionLost` both mean offline
    /// as far as a user is concerned; a caller that only checked the first
    /// shows "server unavailable" to someone in a tunnel.
    static func translate(_ error: URLError, url: URL) -> JumpjetError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed:
            .offlineAndUncached(accession: url.lastPathComponent)
        default:
            .serverError(status: error.code.rawValue, endpoint: url.host ?? url.absoluteString)
        }
    }
}

extension HTTPTransport {

    /// Fetch and decode JSON, turning HTTP status codes into JUMPjet errors.
    ///
    /// 404 is separated from every other failure because it is the one the user
    /// can act on: it means the accession is wrong, not that EBI is down.
    func json<T: Decodable>(
        _ type: T.Type, from url: URL, accession: String, endpoint: String
    ) async throws -> T? {
        let (data, status) = try await get(url)
        switch status {
        case 200:
            break
        case 404:
            return nil
        default:
            throw JumpjetError.serverError(status: status, endpoint: endpoint)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JumpjetError.parseFailure(
                reason: "\(endpoint) returned JSON that could not be read: "
                    + "\(error.localizedDescription)")
        }
    }
}
