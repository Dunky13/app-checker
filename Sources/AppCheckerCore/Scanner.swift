import Foundation

/// One installed thing. `id` is what rules match on:
/// "app:<bundle id>", "brew:<formula>", "cask:<token>", "npm:<package>", "ext:<publisher.name>".
public struct Item: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var version: String
    public var path: String

    public var kind: String { String(id.prefix { $0 != ":" }) }

    public init(id: String, name: String, version: String, path: String) {
        self.id = id
        self.name = name
        self.version = version
        self.path = path
    }
}

public enum Scanner {
    static var fm: FileManager { .default }

    static func children(_ dir: URL) -> [URL] {
        // Numeric-aware, so version folder 1.10 sorts after 1.9 and `last` is the newest.
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func json(_ url: URL) -> Any? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// .app bundles directly in each directory and one folder below (e.g. /Applications/Utilities).
    public static func apps(in dirs: [URL]) -> [Item] {
        dirs.flatMap { dir in children(dir).flatMap { $0.pathExtension == "app" ? [$0] : children($0).filter { $0.pathExtension == "app" } } }
            .compactMap { url in
                // Read the plist directly: Bundle caches Info.plist, so it would miss in-place updates.
                guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                      let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
                return Item(
                    id: "app:\(bundleID)",
                    name: url.deletingPathExtension().lastPathComponent,
                    version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "",
                    path: url.path
                )
            }
    }

    /// Homebrew itself, formulae installed on request (not pulled in as dependencies), and casks that only install CLI binaries.
    /// Casks that install an .app are already covered by `apps`.
    public static func brew(prefix: URL) -> [Item] {
        let cellar = prefix.appendingPathComponent("Cellar"), caskroom = prefix.appendingPathComponent("Caskroom")
        guard fm.fileExists(atPath: cellar.path) else { return [] }
        var items = [Item(id: "brew:homebrew", name: "Homebrew", version: "", path: prefix.path)]
        for formula in children(cellar) {
            guard let keg = children(formula).last,
                  let receipt = json(keg.appendingPathComponent("INSTALL_RECEIPT.json")) as? [String: Any],
                  receipt["installed_on_request"] as? Bool == true else { continue }
            items.append(Item(id: "brew:\(formula.lastPathComponent)", name: formula.lastPathComponent, version: keg.lastPathComponent, path: keg.path))
        }
        for cask in children(caskroom) {
            guard let receipt = json(cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")) as? [String: Any],
                  let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]] else { continue }
            let kinds = Set(artifacts.flatMap(\.keys))
            guard kinds.contains("binary"), kinds.isDisjoint(with: ["app", "pkg", "suite"]),
                  let version = children(cask).last(where: { !$0.lastPathComponent.hasPrefix(".") }) else { continue }
            items.append(Item(id: "cask:\(cask.lastPathComponent)", name: cask.lastPathComponent, version: version.lastPathComponent, path: version.path))
        }
        return items
    }

    /// Packages in global node_modules directories (npm and pnpm), including scoped ones.
    public static func npm(roots: [URL]) -> [Item] {
        roots.flatMap { root in children(root).flatMap { $0.lastPathComponent.hasPrefix("@") ? children($0) : [$0] } }
            .compactMap { dir in
                guard let package = json(dir.appendingPathComponent("package.json")) as? [String: Any],
                      let name = package["name"] as? String else { return nil }
                return Item(id: "npm:\(name)", name: name, version: package["version"] as? String ?? "", path: dir.path)
            }
    }

    /// Editor extensions from each editor's extensions.json.
    /// shortcut: an extension installed in two editors is listed once, so its state reflects whichever editor has telemetry off; split per editor if that matters.
    public static func extensions(in dirs: [URL]) -> [Item] {
        var seen = Set<String>()
        return dirs.flatMap { dir -> [Item] in
            (json(dir.appendingPathComponent("extensions.json")) as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = ((entry["identifier"] as? [String: Any])?["id"] as? String)?.lowercased(),
                      seen.insert(id).inserted else { return nil }
                let location = entry["relativeLocation"] as? String ?? ""
                return Item(id: "ext:\(id)", name: id, version: entry["version"] as? String ?? "", path: dir.appendingPathComponent(location).path)
            }
        }
    }
}

/// Offline hint for items no rule covers: looks for endpoint names of well-known analytics and crash-reporting SDKs.
/// Matches are leads only. Example of a false positive: one leftover ga.js snippet inside a 300 MB Electron bundle.
public enum SDKScan {
    static let markers: [(sdk: String, needles: [String])] = [
        ("Sentry", ["sentry.io"]),
        ("Firebase / Google Analytics", ["app-measurement.com", "google-analytics.com", "crashlytics.com"]),
        ("Amplitude", ["amplitude.com"]),
        ("Mixpanel", ["api.mixpanel.com"]),
        ("PostHog", ["posthog.com"]),
        ("Segment", ["api.segment.io"]),
        ("App Center", ["appcenter.ms"]),
        ("Bugsnag", ["bugsnag.com"]),
        ("TelemetryDeck", ["telemetrydeck.com"]),
        ("Datadog", ["datadoghq.com"]),
        ("Aptabase", ["aptabase.com"]),
        ("Countly", ["count.ly"]),
        ("Rollbar", ["api.rollbar.com"]),
        ("Statsig", ["statsigapi.net"]),
        ("Microsoft telemetry", ["events.data.microsoft.com"]),
    ]

    /// Names of SDKs whose endpoints appear in the item's own code.
    /// shortcut: reads the main executable, Electron's app.asar and a formula's bin/ only; frameworks and npm packages are not searched (Chromium alone would false-positive).
    public static func scan(_ item: Item) -> [String] {
        let root = URL(fileURLWithPath: item.path)
        var files: [URL] = []
        switch item.kind {
        case "app":
            let info = NSDictionary(contentsOf: root.appendingPathComponent("Contents/Info.plist"))
            if let exe = info?["CFBundleExecutable"] as? String { files.append(root.appendingPathComponent("Contents/MacOS/\(exe)")) }
            files.append(root.appendingPathComponent("Contents/Resources/app.asar"))
        case "brew", "cask":
            files = Scanner.children(root.appendingPathComponent("bin"))
        default:
            return []
        }
        let blobs = files.compactMap { url -> Data? in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
            return size <= 500_000_000 ? try? Data(contentsOf: url, options: .mappedIfSafe) : nil
        }
        return markers.filter { marker in
            marker.needles.contains { needle in blobs.contains { $0.range(of: Data(needle.utf8)) != nil } }
        }.map(\.sdk)
    }
}
