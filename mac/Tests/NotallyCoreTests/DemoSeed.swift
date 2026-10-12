import Foundation
import Testing

@testable import NotallyCore

/// Fills a running server with demo notes for screenshots. Runs only with NXYZ_SEED_SERVER,
/// NXYZ_SEED_KEY and NXYZ_SEED_INVITE set; NXYZ_SEED_IMAGES is an optional folder of JPEGs.
@MainActor
@Suite struct DemoSeed {
    static let env = ProcessInfo.processInfo.environment

    @Test(.enabled(if: env["NXYZ_SEED_SERVER"] != nil)) func seed() async throws {
        let url = try #require(APIClient.validate(Self.env["NXYZ_SEED_SERVER"] ?? ""))
        let keys = try SyncKeys.parse(Self.env["NXYZ_SEED_KEY"] ?? "")
        let api = APIClient(baseURL: url, keys: keys)
        _ = try await api.createAccount(invite: Self.env["NXYZ_SEED_INVITE"] ?? "")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try NoteStore(directory: dir, keys: keys)
        let images = (try? FileManager.default.contentsOfDirectory(atPath: Self.env["NXYZ_SEED_IMAGES"] ?? ""))?
            .sorted().map { URL(fileURLWithPath: Self.env["NXYZ_SEED_IMAGES"]!).appendingPathComponent($0) } ?? []
        func image(_ i: Int) -> FileAttachment? {
            images.indices.contains(i) ? try? store.importAttachment(from: images[i], mimeType: "image/jpeg") : nil
        }

        for label in ["Todo", "Travel", "Work"] { store.createLabel(label) }
        let day: Int64 = 86_400_000
        func add(_ type: NoteType, _ title: String, color: String = NoteColor.defaultValue, ago: Int64,
                 _ change: (inout Note) -> Void) {
            var n = store.create(type, color: color)
            n.title = title
            n.timestamp = Note.now() - ago * day
            n.modifiedTimestamp = n.timestamp
            change(&n)
            store.save(n)
        }
        func items(_ spec: [(String, Bool, Bool)]) -> [ListItem] {
            ListOps.normalized(spec.enumerated().map { i, s in
                ListItem(body: s.0, checked: s.1, isChild: s.2, checkedTimestamp: s.1 ? Int64(i + 1) : nil)
            }, autoSort: true)
        }

        add(.note, "Daily Journal", ago: 1) { n in
            n.body = "Date: October 19, 2026\n\nToday was a productive day! I managed to:\n- Finish the presentation for Monday\n- Attend the team meeting"
            n.spans = [Span(start: 0, end: 22, bold: true)]
            n.reminders = [Reminder(id: 0, dateTime: Note.now() + day, repetition: Repetition(value: 1, unit: .days))]
        }
        add(.note, "Formatting", color: "#E9E3D3", ago: 30) { n in
            let text = "This text needs to be bold\n\nA very italic text\n\nOutdated stuff!\n\nSystem.out.println(\"Super useful code!\");\n\nhttps://github.com/Crustack/NotallyX"
            n.body = text
            let ns = text as NSString
            func r(_ s: String) -> NSRange { ns.range(of: s) }
            n.spans = [
                Span(start: 0, end: 26, bold: true),
                Span(start: r("A very italic text").location, end: NSMaxRange(r("A very italic text")), italic: true),
                Span(start: r("Outdated stuff!").location, end: NSMaxRange(r("Outdated stuff!")), strikethrough: true),
                Span(start: r("System").location, end: NSMaxRange(r("code!\");")), monospace: true),
                Span(start: r("https").location, end: ns.length, link: true, linkData: "https://github.com/Crustack/NotallyX"),
            ]
        }
        add(.list, "Grocery List", color: "#D3E4EC", ago: 90) { n in
            n.labels = ["Todo"]
            n.items = items([("Breakfast", false, false), ("Coffee", false, true), ("Bread", true, true),
                             ("Cleaning", false, false), ("Soap", false, true), ("Dishwasher Tabs", false, true),
                             ("Dinner", true, false), ("Chicken", true, true)])
        }
        add(.note, "Vacation", color: "#D3BFDB", ago: 4) { n in
            n.labels = ["Travel"]
            n.body = "Here are some places I'd like to visit this summer:\n- Beach Resort in Maldives\n- Mountain Hiking in Switzerland\n- City Tour in Tokyo"
            n.images = [image(0), image(1), image(2)].compactMap { $0 }
            n.reminders = [Reminder(id: 0, dateTime: Note.now() + 3 * day, repetition: nil)]
        }
        add(.list, "Dinner Bucketlist", color: "#F5E2DC", ago: 12) { n in
            n.labels = ["Todo"]
            n.items = items([("🌯 Burrito", false, false), ("🥪 Philly Cheesesteak", false, false),
                             ("🥟 Pierogi", false, false), ("🍜 Ramen", true, false)])
            n.pinned = true
        }
        add(.note, "Book ideas", color: "#B4DED4", ago: 6) { n in
            n.body = "Short stories about lighthouse keepers. Read Le Guin again."
            n.spans = [Span(start: 0, end: 13, italic: true)]
        }
        add(.note, "Meeting notes", ago: 2) { n in
            n.labels = ["Work"]
            n.body = """
                Attendees: Anna, Marco, Li

                1. Release plan: ship the sync beta on Friday, collect feedback for one week.
                2. Security review: the server stores only ciphertext; check the rate limits again.
                3. Docs: write the setup guide for the reverse proxy and the invite token.
                4. Next meeting: Thursday 10:00.

                Open questions: should attachments over 100 MB be refused on the client already? Who owns the Android release notes?
                """
            n.spans = [Span(start: 0, end: 10, bold: true)]
        }
        add(.list, "Packing list", color: "#FFF8B9", ago: 8) { n in
            n.labels = ["Travel"]
            n.items = items([("Passport", true, false), ("Charger", false, false), ("Phone", false, true),
                             ("Laptop", false, true), ("Sunscreen", false, false), ("Swimsuit", false, false),
                             ("Hiking boots", false, false), ("Rain jacket", false, false), ("Book", true, false),
                             ("Headphones", false, false), ("Snacks", false, false), ("Water bottle", false, false)])
        }
        add(.note, "Pancakes", color: "#FFCC80", ago: 20) { n in
            n.body = "200 g flour\n2 eggs\n300 ml milk\n1 tbsp sugar\nPinch of salt\n\nMix, rest 20 minutes, fry in butter."
        }
        add(.note, "Photo dump", ago: 3) { n in
            n.images = [image(3), image(1)].compactMap { $0 }
            n.body = "Weekend at the lake."
        }
        add(.note, "Quote", color: "#E2F6D3", ago: 15) { n in
            n.body = "“The best way out is always through.” — Robert Frost"
            n.spans = [Span(start: 0, end: 37, italic: true)]
        }
        add(.list, "Project ideas", color: "#AFCCDC", ago: 5) { n in
            n.labels = ["Work"]
            n.items = items([("Home server dashboard", false, false), ("Uptime alerts", false, true),
                             ("Backups to NAS", true, true), ("Plant watering bot", false, false)])
        }
        add(.note, "", color: "#FAAFA9", ago: 0) { n in
            n.body = "Call the dentist before 5 pm."
            n.reminders = [Reminder(id: 0, dateTime: Note.now() + day / 4, repetition: nil)]
        }
        add(.note, "Night sky", color: "#2E3A59", ago: 9) { n in
            n.body = "Perseids peak around 12 August. Best after midnight, away from city lights."
        }
        add(.note, "Wi-Fi at the cabin", color: "#F8BBD0", ago: 40) { n in
            n.body = "Network: cabin-guest\nAsk the owner for the password."
        }
        add(.note, "Old draft", ago: 60) { n in n.body = "Archived note."; n.folder = .archived }
        add(.note, "Trash", ago: 70) { n in n.body = "Deleted note."; n.folder = .deleted }

        let engine = SyncEngine(store: store, api: api)
        await engine.sync()
        #expect(engine.lastError == nil)
    }
}
