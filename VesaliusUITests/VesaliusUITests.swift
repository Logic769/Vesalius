import XCTest

/// End-to-end tests: launch the real app on a generated repository and use it like a developer would.
/// The only stand-in is the folder picker: the repository is opened with a launch argument.
final class VesaliusUITests: XCTestCase {
    private var app: XCUIApplication!
    private var repository: URL!
    private var home: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vesalius-ui-\(UUID().uuidString.prefix(6))")
        repository = base.appendingPathComponent("SampleApp")
        home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try writeSampleRepository(at: repository)

        app = XCUIApplication()
        app.launchArguments += [
            "-VesaliusOpenRepository", repository.path,
            "-VesaliusResetRecents", "YES",
            "-ApplePersistenceIgnoreState", "YES",
        ]
        app.launchEnvironment["VESALIUS_HOME"] = home.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: repository.deletingLastPathComponent())
    }

    func testWelcomeShowsOpenRepository() {
        let welcome = XCUIApplication()
        welcome.launchArguments += ["-VesaliusResetRecents", "YES", "-ApplePersistenceIgnoreState", "YES"]
        welcome.launchEnvironment["VESALIUS_HOME"] = home.path
        welcome.launch()
        XCTAssertTrue(welcome.buttons["open-repository"].waitForExistence(timeout: 15))
        welcome.terminate()
    }

    func testIndexesAndExploresARepository() throws {
        app.launch()

        // First index completes and the overview teaches something immediately.
        XCTAssertTrue(app.otherElements["overview"].waitForExistence(timeout: 60) || app.scrollViews["overview"].waitForExistence(timeout: 5), "overview did not appear")
        XCTAssertTrue(app.staticTexts["SampleApp"].firstMatch.exists)
        // The stats row is exposed as one combined element whose type depends on the view (buttons today).
        XCTAssertTrue(app.descendants(matching: .any)["overview-stats"].firstMatch.exists, "overview stats missing")

        // System map: the canvas exposes nodes; double-click drills in.
        app.outlines["sidebar"].cells.containing(.staticText, identifier: "System Map").firstMatch.click()
        let canvas = app.descendants(matching: .any)["system-map"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15), "map canvas missing")
        let nodes = app.descendants(matching: .button).matching(NSPredicate(format: "identifier BEGINSWITH 'map-node-'"))
        XCTAssertTrue(nodes.firstMatch.waitForExistence(timeout: 15), "no map nodes")
        let before = nodes.count
        XCTAssertGreaterThan(before, 1)
        let area = nodes.matching(NSPredicate(format: "identifier CONTAINS 'dir:web' OR identifier CONTAINS 'dir:Sources'")).firstMatch
        if area.exists {
            area.doubleClick()
            let crumbs = app.descendants(matching: .any)["map-breadcrumbs"]
            XCTAssertTrue(crumbs.waitForExistence(timeout: 10))
        }

        // Files table → inspector with an Open button.
        app.outlines["sidebar"].cells.containing(.staticText, identifier: "Files").firstMatch.click()
        let table = app.tables["files-table"].exists ? app.tables["files-table"] : app.outlines["files-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 10), "files table missing")
        table.tableRows.firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["inspector-open"].waitForExistence(timeout: 10), "inspector did not open for the selected file")

        // Health: categories expand to show their deductions.
        app.outlines["sidebar"].cells.containing(.staticText, identifier: "Health").firstMatch.click()
        let cycles = app.buttons["health-category-cycles"]
        XCTAssertTrue(cycles.waitForExistence(timeout: 10))
        cycles.click()

        // Ask: a natural-language question returns ranked files.
        app.outlines["sidebar"].cells.containing(.staticText, identifier: "Ask").firstMatch.click()
        let field = app.textFields["ask-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("where do users sign in?\r")
        XCTAssertTrue(app.descendants(matching: .any)["ask-result-1"].waitForExistence(timeout: 15), "no answer")

        // Command palette: ⌘K, type, results, Esc.
        app.typeKey("k", modifierFlags: .command)
        let palette = app.textFields["palette-field"]
        XCTAssertTrue(palette.waitForExistence(timeout: 5))
        palette.typeText("AuthServ")
        XCTAssertTrue(app.staticTexts["AuthService"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        // Diagnostics → inspector → hand the finding to an agent (the sheet opens; we cancel).
        app.outlines["sidebar"].cells.containing(.staticText, identifier: "Diagnostics").firstMatch.click()
        let list = app.descendants(matching: .any)["diagnostics-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let firstDiagnostic = list.descendants(matching: .cell).firstMatch
        XCTAssertTrue(firstDiagnostic.waitForExistence(timeout: 10), "no diagnostics listed")
        firstDiagnostic.click()
        let improve = app.buttons["improve-with-agent"]
        XCTAssertTrue(improve.waitForExistence(timeout: 10))
        improve.click()
        XCTAssertTrue(app.descendants(matching: .any)["agent-prompt"].waitForExistence(timeout: 10), "agent sheet did not open")
        app.buttons["Cancel"].click()
    }

    // MARK: Fixture

    private func writeSampleRepository(at root: URL) throws {
        let files: [String: String] = [
            "Sources/App/AuthService.swift": """
                import Foundation

                final class AuthService {
                    let store = SessionStore()
                    func signIn(email: String, password: String) -> Bool {
                        guard !email.isEmpty else { return false }
                        store.save(token: email + password)
                        return true
                    }
                }
                """,
            "Sources/App/SessionStore.swift": """
                import Foundation

                struct SessionStore {
                    func save(token: String) { UserDefaults.standard.set(token, forKey: "token") }
                }
                """,
            "Sources/App/LoginView.swift": """
                import SwiftUI

                struct LoginView: View {
                    let auth = AuthService()
                    var body: some View { Button("Sign in") { _ = auth.signIn(email: "a", password: "b") } }
                }
                """,
            "web/src/api/client.ts": "export class ApiClient { get(path: string) { return fetch(path); } }\n",
            "web/src/api/users.ts": "import { ApiClient } from './client';\nexport function fetchUser(id: number) { return new ApiClient().get('/users/' + id); }\n",
            "web/src/cycle/a.ts": "import { b } from './b';\nexport const a = (n: number): number => (n > 0 ? b(n - 1) : 0);\n",
            "web/src/cycle/b.ts": "import { a } from './a';\nexport const b = (n: number): number => (n > 0 ? a(n - 1) : 1);\n",
        ]
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
