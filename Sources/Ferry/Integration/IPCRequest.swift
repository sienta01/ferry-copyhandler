import Foundation

/// A request from the Finder extension to the app, carried in a `ferry://run?p=…` URL.
///
/// This file is compiled into both the app and the Finder extension. Requests must carry the
/// random token that `scripts/build.sh` writes into both Info.plists, so a web page or another
/// app can't use the URL scheme to make Ferry move files around.
struct IPCRequest: Codable {
    var token: String
    /// "paste" (sources come from the clipboard), "copyto" or "moveto" (asks for a destination).
    var action: String
    var move = false
    var destination: String?
    var sources: [String] = []

    static var bundleToken: String {
        Bundle.main.object(forInfoDictionaryKey: "FerryIPCToken") as? String ?? ""
    }

    init(action: String, move: Bool = false, destination: String? = nil, sources: [String] = []) {
        token = IPCRequest.bundleToken
        self.action = action
        self.move = move
        self.destination = destination
        self.sources = sources
    }

    var url: URL? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "ferry://run?p=" + payload)
    }

    init?(url: URL) {
        guard url.scheme == "ferry",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var payload = comps.queryItems?.first(where: { $0.name == "p" })?.value else { return nil }
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else { return nil }
        self = request
    }

    var isAuthentic: Bool {
        let expected = IPCRequest.bundleToken
        return !expected.isEmpty && token == expected
    }
}
