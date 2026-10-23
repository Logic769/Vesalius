import Foundation
@testable import QueryEngine
import RepositoryIndex
import VesaliusCore

/// Small repositories written to temporary folders. Every test process uses its own `VESALIUS_HOME`,
/// so indexes never touch the user's Application Support.
enum RepoFixture {
    static let home: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vesalius-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("VESALIUS_HOME", url.path, 1)
        return url
    }()

    /// Writes `files` (relative path → contents) into a fresh folder and returns its URL.
    static func make(_ files: [String: String], name: String = "repo") throws -> URL {
        _ = home
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vesalius-fixture-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return IndexLocation.canonicalRoot(root)
    }

    static func write(_ contents: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        // Make sure the modification time moves even within the same second.
        let date = Date().addingTimeInterval(Double.random(in: 1...5))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Indexes a fixture and returns its engine (no embeddings or git, for speed and determinism).
    static func indexed(_ files: [String: String], name: String = "repo") async throws -> (RepositoryEngine, URL) {
        let root = try make(files, name: name)
        let engine = try RepositoryEngine(repository: root)
        try await engine.index(options: fastOptions)
        return (engine, root)
    }

    static var fastOptions: IndexOptions { IndexOptions(computeEmbeddings: false, gitChurn: false) }

    /// A small multi-language application: a Swift app, a TypeScript web client with an import cycle,
    /// and a Python package with tests, plus things that must be excluded.
    static let app: [String: String] = [
        ".gitignore": """
            # build output
            ignored/
            *.gen.ts
            !keep.gen.ts
            /build
            """,
        "Sources/App/AuthService.swift": """
            import Foundation

            /// Signs users in and keeps their session.
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
                func save(token: String) {
                    UserDefaults.standard.set(token, forKey: "token")
                }
            }
            """,
        "Sources/App/LoginView.swift": """
            import SwiftUI

            struct LoginView: View {
                let auth = AuthService()

                var body: some View {
                    Button("Sign in") { tap() }
                }

                func tap() {
                    _ = auth.signIn(email: "a@b.c", password: "secret")
                }
            }
            """,
        "web/src/api/client.ts": """
            export class ApiClient {
              constructor(private base: string) {}
              get(path: string): Promise<Response> {
                return fetch(this.base + path);
              }
            }
            """,
        "web/src/api/users.ts": """
            import { ApiClient } from './client';

            export function fetchUser(id: number) {
              const client = new ApiClient('https://example.com');
              return client.get(`/users/${id}`);
            }
            """,
        "web/src/ui/UserCard.tsx": """
            import { fetchUser } from '../api/users';

            export function UserCard({ id }: { id: number }) {
              fetchUser(id);
              return <div>user</div>;
            }
            """,
        "web/src/cycle/a.ts": """
            import { b } from './b';
            export const a = (n: number): number => (n > 0 ? b(n - 1) : 0);
            """,
        "web/src/cycle/b.ts": """
            import { a } from './a';
            export const b = (n: number): number => (n > 0 ? a(n - 1) : 1);
            """,
        "web/src/keep.gen.ts": "export const kept = true;\n",
        "web/src/drop.gen.ts": "export const dropped = true;\n",
        "py/app/__init__.py": "",
        "py/app/models.py": """
            class User:
                \"\"\"A registered user.\"\"\"

                def __init__(self, name):
                    self.name = name
            """,
        "py/app/service.py": """
            from .models import User


            def load_user(name):
                return User(name)
            """,
        "py/tests/test_service.py": """
            from app.service import load_user


            def test_load_user():
                assert load_user("ada").name == "ada"
            """,
        "node_modules/leftpad/index.js": "module.exports = function () {};\n",
        "ignored/secret.ts": "export const secret = 1;\n",
        "build/output.ts": "export const built = 1;\n",
        "assets/logo.png": "not really a png",
        "vendor-lib/Dependencies/snapshot-master/LICENSE": "MIT",
        "vendor-lib/Dependencies/snapshot-master/CONTRIBUTING.md": "Contributions welcome",
        "vendor-lib/Dependencies/snapshot-master/lib.c": "int vendored(void) { return 1; }\n",
    ]

    /// Paths (repository-relative) that the scanner must index for `app`.
    static let expectedAppFiles: Set<String> = [
        "Sources/App/AuthService.swift", "Sources/App/SessionStore.swift", "Sources/App/LoginView.swift",
        "web/src/api/client.ts", "web/src/api/users.ts", "web/src/ui/UserCard.tsx",
        "web/src/cycle/a.ts", "web/src/cycle/b.ts", "web/src/keep.gen.ts",
        "py/app/__init__.py", "py/app/models.py", "py/app/service.py", "py/tests/test_service.py",
    ]
}

/// Runs the built `vesalius` executable (end-to-end tests drive the real binary).
enum CLI {
    static var executable: URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return packageRoot.appendingPathComponent(".build/debug/vesalius")
    }

    struct Output {
        let stdout: String
        let stderr: String
        let status: Int32
        var data: Data { Data(stdout.utf8) }
    }

    static func run(_ arguments: [String], directory: URL? = nil, input: String? = nil, timeout: TimeInterval = 120) throws -> Output {
        _ = RepoFixture.home
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(["VESALIUS_HOME": RepoFixture.home.path]) { $1 }
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return Output(stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self), status: process.terminationStatus)
    }
}
