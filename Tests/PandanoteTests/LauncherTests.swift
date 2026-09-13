import XCTest
@testable import Pandanote

final class LauncherTests: XCTestCase {
    func testApplicationDiscoveryIncludesUtilitiesAndSkipsAppContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Utilities/Example.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Helpers/Hidden.app"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleName": "Example", "CFBundleDisplayName": "Example Editor", "CFBundleIdentifier": "test.example"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let items = LauncherItem.applications(in: [root, root.appendingPathComponent("Utilities")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Example Editor")
        // macOS can enumerate the same temporary directory through /private/var
        // and add a trailing slash to directory URLs. Compare the resolved paths.
        XCTAssertEqual(items.first?.url.resolvingSymlinksInPath().path, app.resolvingSymlinksInPath().path)
        XCTAssertEqual(items.first?.isApplication, true)
    }

    func testRankingAccentInsensitiveMultipleWordsAndEmptyResults() {
        let items = [
            LauncherItem(url: URL(fileURLWithPath: "/notes/safari.md"), title: "Using Safari", detail: "Reference", isApplication: false),
            LauncherItem(url: URL(fileURLWithPath: "/Applications/Safari.app"), title: "Safari", detail: "/Applications", isApplication: true),
            LauncherItem(url: URL(fileURLWithPath: "/notes/cafe.md"), title: "Café notes", detail: "Travel", isApplication: false)
        ]
        XCTAssertEqual(LauncherItem.matching(items, query: "SAFARI").map(\.title), ["Safari", "Using Safari"])
        XCTAssertEqual(LauncherItem.matching(items, query: " cafe  travel ").map(\.title), ["Café notes"])
        XCTAssertTrue(LauncherItem.matching(items, query: "missing").isEmpty)
        XCTAssertEqual(LauncherItem.matching(items, query: "  ").count, 3)
    }
}
