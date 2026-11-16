// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// versions.json of the bundled media: the app's set (docs/guest-additions-design.md, section 4).
struct AdditionsVersions: Equatable {
    var additions = ""
    var protocolVersion: Int?
    /// Package name to version.
    var packages: [String: String] = [:]
    /// Packages the install may skip on a stock image: they are never "missing". The media's "optional" names them.
    var optional = AdditionsVersions.defaultOptional
    var built = ""

    /// For a media with no "optional" field: tux-codec-dkms needs dkms, gcc and the kernel headers.
    static let defaultOptional: Set<String> = ["tux-codec-dkms"]

    /// nil when the data is not a JSON object.
    static func decode(_ data: Data) -> AdditionsVersions? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var v = AdditionsVersions()
        v.additions = object["additions"] as? String ?? ""
        v.protocolVersion = object["protocol"] as? Int
        v.built = object["built"] as? String ?? ""
        for (name, value) in (object["packages"] as? [String: Any]) ?? [:] {
            if let version = value as? String { v.packages[name] = version }
        }
        if let names = object["optional"] as? [Any] { v.optional = Set(names.compactMap { $0 as? String }) }
        return v
    }
}

/// actions.json of the bundled media: what the wizard offers, with sizes and labels.
struct AdditionsCatalogue: Equatable {
    struct Desktop: Equatable, Identifiable {
        var id: String
        var title: String
        var sizeMB: Int
    }

    struct App: Equatable, Identifiable {
        var id: String
        var title: String
        var group: String
        var sizeMB: Int
    }

    struct SSHLimits: Equatable {
        var portMin = 1
        var portMax = 65535
        var defaultPort = 22
    }

    var protocolVersion = 0
    var desktops: [Desktop] = []
    var apps: [App] = []
    var ssh = SSHLimits()

    /// The order the wizard shows the groups in; a group not named here comes last, by name.
    static let groupOrder = ["web", "office", "media", "graphics", "develop", "tools"]

    static func groupTitle(_ group: String) -> String {
        switch group {
        case "web": return "Web"
        case "office": return "Office"
        case "media": return "Media"
        case "graphics": return "Graphics"
        case "develop": return "Develop"
        case "tools": return "Tools"
        default: return group.prefix(1).uppercased() + group.dropFirst()
        }
    }

    /// The apps by group, in groupOrder, each group keeping the file's order. An entry with no id or no title is left out.
    var appGroups: [(group: String, apps: [App])] {
        let names = Set(apps.map(\.group))
        let ordered = Self.groupOrder.filter(names.contains) + names.subtracting(Self.groupOrder).sorted()
        return ordered.map { g in (g, apps.filter { $0.group == g }) }
    }

    func desktop(_ id: String) -> Desktop? { desktops.first { $0.id == id } }
    func app(_ id: String) -> App? { apps.first { $0.id == id } }

    /// nil when the data is not a JSON object. Entries of the wrong shape are left out, so a newer media does not
    /// stop an older app.
    static func decode(_ data: Data) -> AdditionsCatalogue? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var c = AdditionsCatalogue()
        c.protocolVersion = object["protocol"] as? Int ?? 0
        for d in (object["desktops"] as? [[String: Any]]) ?? [] {
            guard let id = d["id"] as? String, !id.isEmpty else { continue }
            c.desktops.append(Desktop(id: id, title: d["title"] as? String ?? id, sizeMB: size(d["size_mb"])))
        }
        for a in (object["apps"] as? [[String: Any]]) ?? [] {
            guard let id = a["id"] as? String, !id.isEmpty else { continue }
            c.apps.append(App(id: id, title: a["title"] as? String ?? id, group: a["group"] as? String ?? "tools", sizeMB: size(a["size_mb"])))
        }
        if let s = object["ssh"] as? [String: Any] {
            c.ssh = SSHLimits(portMin: s["port_min"] as? Int ?? 1, portMax: s["port_max"] as? Int ?? 65535,
                              defaultPort: s["default_port"] as? Int ?? 22)
        }
        return c
    }

    private static func size(_ value: Any?) -> Int { max((value as? Int) ?? 0, 0) }

    /// "150 MB", "1.5 GB" (decimal units).
    static func sizeText(_ mb: Int) -> String {
        mb < 1000 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1000)
    }
}
