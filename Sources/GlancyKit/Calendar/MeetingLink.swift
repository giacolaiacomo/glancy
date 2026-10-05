import Foundation

/// A video-meeting link found in an event's url / location / notes.
public struct MeetingLink: Equatable, Sendable {
    public enum Provider: String, Sendable, CaseIterable {
        case zoom, meet, teams, webex, whereby, facetime
        public var displayName: String {
            switch self {
            case .zoom: "Zoom"
            case .meet: "Google Meet"
            case .teams: "Teams"
            case .webex: "Webex"
            case .whereby: "Whereby"
            case .facetime: "FaceTime"
            }
        }
    }

    public let provider: Provider
    /// The https link as found in the event.
    public let webURL: URL
    /// What to open: a native-app URL where that is safe, otherwise `webURL`.
    public let joinURL: URL

    /// Scans `url`, then `location`, then `notes` (in that order) and returns the first
    /// recognised meeting link. Unknown links (docs, agendas, dial-in pages) are ignored.
    public static func extract(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        if let url, let link = classify(url) { return link }
        for text in [location, notes] {
            guard let text, !text.isEmpty else { continue }
            for candidate in links(in: text) {
                if let link = classify(candidate) { return link }
            }
        }
        return nil
    }

    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap { $0.url }
    }

    static func classify(_ url: URL) -> MeetingLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)

        func make(_ provider: Provider, join: URL? = nil) -> MeetingLink {
            MeetingLink(provider: provider, webURL: url, joinURL: join ?? url)
        }
        func isHost(_ base: String) -> Bool { host == base || host.hasSuffix("." + base) }

        if isHost("zoom.us") || isHost("zoomgov.com") {
            if path.hasPrefix("/j/") {
                let id = path.dropFirst(3).split(separator: "/").first.map(String.init) ?? ""
                guard !id.isEmpty else { return nil }
                var native: URL?
                if id.allSatisfy(\.isNumber) {
                    var c = URLComponents()
                    c.scheme = "zoommtg"
                    c.host = host
                    c.path = "/join"
                    var items = [URLQueryItem(name: "confno", value: id)]
                    if let pwd = comps?.queryItems?.first(where: { $0.name == "pwd" })?.value, !pwd.isEmpty {
                        items.append(URLQueryItem(name: "pwd", value: pwd))
                    }
                    c.queryItems = items
                    native = c.url
                }
                return make(.zoom, join: native)
            }
            if path.hasPrefix("/my/"), path.count > 4 { return make(.zoom) }
            return nil
        }
        if host == "meet.google.com" {
            let room = path.dropFirst().split(separator: "/").first.map(String.init) ?? ""
            let isCode = room.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
            return (isCode || room == "lookup") ? make(.meet) : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            guard path.hasPrefix("/l/meetup-join") || path.hasPrefix("/meet/") else { return nil }
            var native: URL?
            if host == "teams.microsoft.com", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.scheme = "msteams"
                native = c.url
            }
            return make(.teams, join: native)
        }
        if isHost("webex.com") {
            return path.count > 1 ? make(.webex) : nil
        }
        if host == "whereby.com" || host == "www.whereby.com" {
            let room = path.dropFirst()
            return (!room.isEmpty && !room.contains("information")) ? make(.whereby) : nil
        }
        if host == "facetime.apple.com" {
            return path.hasPrefix("/join") ? make(.facetime) : nil
        }
        return nil
    }
}
