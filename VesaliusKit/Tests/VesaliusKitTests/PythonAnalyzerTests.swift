import Foundation
import Testing
import VesaliusCore
@testable import LanguageAnalysis

private func analyze(_ source: String, path: String = "app/module.py") throws -> FileAnalysis {
    try PythonAnalyzer().analyze(SourceFile(path: path, language: .python, text: source))
}

private extension FileAnalysis {
    func symbol(_ name: String, _ kind: SymbolKind? = nil) -> ExtractedSymbol? {
        symbols.first { $0.name == name && (kind == nil || $0.kind == kind) }
    }

    func references(named name: String) -> [ExtractedReference] {
        references.filter { $0.name == name }
    }

    func hasReference(_ name: String, _ kind: ReferenceKind, receiver: String? = nil) -> Bool {
        references.contains { $0.name == name && $0.kind == kind && $0.receiver == receiver }
    }

    func children(of symbol: ExtractedSymbol) -> [ExtractedSymbol] {
        symbols.filter { $0.parentLocalID == symbol.localID }
    }

    func reference(_ name: String, line: Int) -> ExtractedReference? {
        references.first { $0.name == name && $0.line == line }
    }

    func importFor(_ module: String) -> ExtractedImport? {
        imports.first { $0.module == module }
    }
}

private func describe(_ item: ExtractedImport) -> String {
    let names = item.names.map { name in name.alias.map { "\(name.name) as \($0)" } ?? name.name }
    return "\(item.module)[\(names.joined(separator: ","))]"
}

private let authModule = """
\"\"\"Authentication services.\"\"\"
from __future__ import annotations

import os
import logging as log
from typing import Optional, List
from . import models
from .models import User, Session as AuthSession
from ..core.config import settings
from .utils import *

__all__ = ["AuthService", "login"]

MAX_ATTEMPTS = 5
_cache = {}


class AuthError(Exception):
    \"\"\"Raised when authentication fails.\"\"\"


@dataclass
class Credentials(BaseModel, metaclass=ModelMeta):
    email: str
    password: str = ""


class AuthService(BaseService):
    \"\"\"Coordinates sign-in.

    Longer description that is not part of the summary.
    \"\"\"

    retries: int = 3

    def __init__(self, store: "SessionStore", clock=None):
        self.store = store
        self.clock = clock or default_clock()
        self._attempts = 0

    @property
    def attempts(self) -> int:
        return self._attempts

    async def login(self, creds: Credentials) -> Optional[AuthSession]:
        user = models.find_user(creds.email)
        if user is None or not user.check(creds.password):
            self._attempts += 1
            raise AuthError("invalid")
        session = AuthSession(user=user)
        self.store.save(session)
        log.info("login %s", user.id)
        return session

    def _helper(self, items: List[User]):
        return [item.name for item in items if item.active]


def login(email, password):
    service = AuthService(SessionStore())
    return service.login(Credentials(email=email, password=password))


if __name__ == "__main__":
    login(os.environ["EMAIL"], os.environ["PASSWORD"])
"""

@Suite("Python analyzer")
struct PythonAnalyzerTests {
    @Test func symbolsKindsAndNesting() throws {
        let analysis = try analyze(authModule, path: "app/auth/service.py")

        #expect(analysis.symbol("MAX_ATTEMPTS")?.kind == .constant)
        #expect(analysis.symbol("MAX_ATTEMPTS")?.isExported == true)
        #expect(analysis.symbol("_cache")?.kind == .variable)
        #expect(analysis.symbol("_cache")?.isExported == false)
        #expect(analysis.symbol("_cache")?.visibility == .private)
        #expect(analysis.symbol("__all__") == nil)

        let error = try #require(analysis.symbol("AuthError", .class))
        #expect(error.inheritedTypes == ["Exception"])
        #expect(error.doc == "Raised when authentication fails.")

        let credentials = try #require(analysis.symbol("Credentials", .class))
        #expect(credentials.attributes == ["@dataclass"])
        #expect(credentials.inheritedTypes == ["BaseModel"])
        #expect(credentials.range == LineRange(22, 25), "decorated definitions start at the decorator")
        #expect(analysis.children(of: credentials).map(\.name) == ["email", "password"])
        #expect(analysis.children(of: credentials).allSatisfy { $0.kind == .property })

        let service = try #require(analysis.symbol("AuthService", .class))
        #expect(service.doc == "Coordinates sign-in.")
        #expect(service.signature == "class AuthService(BaseService)")
        #expect(service.isExported)
        let members = analysis.children(of: service)
        #expect(members.map(\.name) == ["retries", "__init__", "store", "clock", "_attempts", "attempts", "login", "_helper"])
        #expect(analysis.symbol("__init__")?.kind == .initializer)
        #expect(analysis.symbol("store")?.kind == .property, "self.x assignments in __init__ declare properties")
        #expect(analysis.symbol("_attempts")?.visibility == .private)
        #expect(analysis.symbol("attempts")?.attributes == ["@property"])
        let login = try #require(analysis.symbols.first { $0.name == "login" && $0.kind == .method })
        #expect(login.attributes == ["async"])
        #expect(login.signature == "async def login(self, creds: Credentials) -> Optional[AuthSession]")
        #expect(login.isExported == false)
        #expect(analysis.symbol("_helper")?.visibility == .private)

        let function = try #require(analysis.symbols.first { $0.name == "login" && $0.kind == .function })
        #expect(function.parentLocalID == nil)
        #expect(function.isExported)
        #expect(analysis.exportedNames == ["AuthService=AuthService", "login=login"])
        #expect(analysis.isEntryPoint)
        #expect(analysis.syntaxErrorCount == 0)
    }

    @Test func importsAreRecordedPerName() throws {
        let analysis = try analyze(authModule, path: "app/auth/service.py")
        #expect(analysis.imports.map(describe) == [
            "os[]",
            "logging[* as log]",
            "typing[Optional]",
            "typing[List]",
            ".[models]",
            ".models[User]",
            ".models[Session as AuthSession]",
            "..core.config[settings]",
            ".utils[*]",
        ])
        #expect(analysis.imports.filter { $0.kind == .relative }.count == 5)
        #expect(analysis.imports.first { $0.module == "os" }?.kind == .module)

        let more = try analyze("""
        import a.b.c
        import numpy as np, pandas
        from .. import sibling
        from ...deep.pkg import thing
        """)
        #expect(more.imports.map(describe) == ["a.b.c[]", "numpy[* as np]", "pandas[]", "..[sibling]", "...deep.pkg[thing]"])
    }

    @Test func referenceKindsAndReceivers() throws {
        let analysis = try analyze(authModule, path: "app/auth/service.py")
        #expect(analysis.hasReference("BaseModel", .inherit))
        #expect(analysis.hasReference("BaseService", .inherit))
        #expect(analysis.references(named: "Exception").isEmpty, "built-in bases are not references")
        #expect(analysis.hasReference("dataclass", .decorator))
        #expect(analysis.references(named: "property").isEmpty)
        #expect(analysis.hasReference("SessionStore", .typeUse), "string annotations are forward references")
        #expect(analysis.hasReference("Credentials", .typeUse))
        #expect(analysis.hasReference("AuthSession", .typeUse))
        #expect(analysis.hasReference("User", .typeUse))
        #expect(analysis.references(named: "Optional").isEmpty)
        #expect(analysis.hasReference("find_user", .call, receiver: "models"))
        #expect(analysis.hasReference("check", .call, receiver: "user"))
        #expect(analysis.hasReference("save", .call, receiver: "self.store"))
        #expect(analysis.hasReference("info", .call, receiver: "log"))
        #expect(analysis.hasReference("default_clock", .call))
        #expect(analysis.hasReference("AuthError", .instantiate))
        #expect(analysis.hasReference("AuthSession", .instantiate))
        #expect(analysis.hasReference("AuthService", .instantiate))
        #expect(analysis.hasReference("SessionStore", .instantiate))
        #expect(analysis.hasReference("_attempts", .write, receiver: "self"))
        #expect(analysis.hasReference("_attempts", .read, receiver: "self"))
        #expect(analysis.hasReference("store", .write, receiver: "self"))
        // `os.environ["EMAIL"]` reads the environment variable EMAIL, not an attribute of `os`.
        #expect(analysis.hasReference("env:EMAIL", .read, receiver: "os.environ"))
        #expect(analysis.hasReference("env:PASSWORD", .read, receiver: "os.environ"))
        #expect(analysis.references(named: "environ").isEmpty)
        #expect(analysis.hasReference("login", .call), "module-level call in the __main__ guard")
        #expect(analysis.hasReference("ModelMeta", .read))

        let find = try #require(analysis.references(named: "find_user").first)
        #expect(find.line == 46)
        #expect(find.enclosingSymbol.map { analysis.symbols[$0].name } == "login")
    }

    @Test func localsParametersAndComprehensionsAreNotReferences() throws {
        let analysis = try analyze(authModule, path: "app/auth/service.py")
        for local in ["user", "session", "service", "email", "password", "creds", "items", "item", "store", "clock", "self"] {
            #expect(!analysis.references.contains { $0.name == local && $0.receiver == nil }, "\(local) is a local binding")
        }
        #expect(analysis.references(named: "email").allSatisfy { $0.receiver != nil })
        #expect(!analysis.references.contains { $0.receiver == "creds" }, "attributes of locals are not resolvable references")
        #expect(analysis.references(named: "name").isEmpty)
        #expect(analysis.references(named: "len").isEmpty)

        let scoped = try analyze("""
        TOTAL = 0

        def outer(data, *args, flag: bool = DEFAULT, **kwargs):
            counter = 0
            for index, value in enumerate(data):
                counter += value
            with open(PATH) as handle, lock():
                text = handle.read()
            try:
                risky()
            except LookupError as problem:
                report(problem)
            def inner(x):
                return x + counter + TOTAL
            squares = {k: v * v for k, v in mapping.items()}
            fn = lambda y: y * FACTOR
            if (match := pattern.search(text)):
                return match
            return inner(counter), fn, squares, args, kwargs, flag, index
        """)
        let names = Set(scoped.references.filter { $0.receiver == nil }.map(\.name))
        #expect(names.isSuperset(of: ["DEFAULT", "PATH", "lock", "risky", "report", "TOTAL", "FACTOR", "mapping", "pattern"]))
        #expect(scoped.hasReference("LookupError", .typeUse))
        for local in ["data", "args", "kwargs", "flag", "counter", "index", "value", "handle", "text", "problem", "inner", "x", "k", "v", "squares", "fn", "y", "match"] {
            #expect(!names.contains(local), "\(local) is a local binding")
        }
        #expect(scoped.symbol("inner")?.kind == .function)
        #expect(scoped.symbol("inner")?.parentLocalID == scoped.symbol("outer")?.localID)
    }

    @Test func complexityCountsDecisionPoints() throws {
        let analysis = try analyze("""
        def classify(value, items):
            if value > 10 and value < 20:
                return "teen"
            elif value or not items:
                return "x"
            for item in items:
                while item:
                    item = item.next
            try:
                pass
            except ValueError:
                pass
            except KeyError:
                pass
            evens = [i for i in items if i % 2 == 0]
            return "a" if value else "b"
        """)
        // if, and, elif, or, for, while, except, except, comprehension-if, conditional → 10.
        #expect(analysis.symbol("classify")?.complexity == 11)
        #expect(analysis.complexity == 11)
    }

    @Test func duplicateBodiesShareAStructuralHash() throws {
        let analysis = try analyze("""
        def total_a(items):
            \"\"\"Sum prices.\"\"\"
            result = 0
            for item in items:
                result += item.price
            # comments are ignored
            return result

        def total_b(entries):
            \"\"\"Sum costs.\"\"\"
            acc = 100
            for entry in entries:
                acc += entry.cost
            return acc

        def product(entries):
            \"\"\"Multiply costs.\"\"\"
            acc = 1
            for entry in entries:
                acc *= entry.cost
            return acc
        """)
        let a = try #require(analysis.symbol("total_a")?.bodyHash)
        let b = try #require(analysis.symbol("total_b")?.bodyHash)
        let c = try #require(analysis.symbol("product")?.bodyHash)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func classesWithGenericBasesAndNestedClasses() throws {
        let analysis = try analyze("""
        class Repository(Generic[T], models.Base):
            class Meta:
                table = "repo"

            def get(self, key: "models.Key") -> T:
                return self._store[key]
        """)
        let repository = try #require(analysis.symbol("Repository"))
        #expect(repository.inheritedTypes == ["Generic", "Base"])
        #expect(analysis.hasReference("Base", .inherit, receiver: "models"))
        #expect(analysis.references(named: "Generic").isEmpty)
        let meta = try #require(analysis.symbol("Meta"))
        #expect(meta.parentLocalID == repository.localID)
        #expect(analysis.symbol("table")?.parentLocalID == meta.localID)
        #expect(analysis.hasReference("Key", .typeUse, receiver: "models"))
        #expect(analysis.symbol("get")?.kind == .method)
    }

    @Test func malformedInputIsRecoveredNotThrown() throws {
        let analysis = try analyze("""
        def broken(:
            pass

        class Fine:
            def ok(self):
                return 1
        """)
        #expect(analysis.syntaxErrorCount > 0)
        #expect(analysis.symbol("Fine") != nil)
        _ = try analyze("")
        _ = try analyze("))) (((( def def class :::")
        _ = try analyze(String(repeating: "[", count: 20_000))
    }

    @Test func deeplyNestedExpressionsDoNotOverflowTheStack() throws {
        let chain = (0..<20_000).map { "v\($0)" }.joined(separator: " + ")
        let analysis = try analyze("TOTAL = \(chain)\n")
        #expect(analysis.symbol("TOTAL") != nil)
        #expect(analysis.references.count == 20_000)
    }

    @Test func largeGeneratedFileIsFast() throws {
        var lines: [String] = ["from .base import Base, helper", ""]
        for index in 0..<500 {
            lines.append("""
            class Service\(index)(Base):
                \"\"\"Service \(index).\"\"\"

                def __init__(self, value):
                    self.value = value

                def compute(self, number):
                    if number > \(index) and self.value:
                        return helper(number) + self.value
                    return Service\(max(0, index - 1))(number).compute(number - 1)

            """)
        }
        let source = lines.joined(separator: "\n")
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let start = Date()
        let analysis = try analyze(source, path: "app/generated.py")
        let elapsed = Date().timeIntervalSince(start)
        print("Python: \(lineCount) lines in \(String(format: "%.3f", elapsed))s (\(Int(Double(lineCount) / max(elapsed, 0.0001))) lines/sec)")
        #expect(lineCount >= 5_000)
        #expect(analysis.symbols.filter { $0.kind == .class }.count == 500)
        #expect(analysis.symbols.filter { $0.kind == .method }.count == 500)
        #expect(analysis.symbols.filter { $0.kind == .property }.count == 500)
        #expect(elapsed < 5)
    }

    @Test func analyzerContract() {
        let analyzer = PythonAnalyzer()
        #expect(analyzer.identifier == "tree-sitter-python")
        #expect(analyzer.canAnalyze(.python, path: "a.py"))
        #expect(!analyzer.canAnalyze(.typescript, path: "a.ts"))
    }

    // MARK: v2 reference data (statements, consumers, load time, environment, import flags)

    @Test func environmentVariablesBecomeEnvReferences() throws {
        let analysis = try analyze("""
        import os
        from os import environ

        API_KEY = os.environ["API_KEY"]
        DB_URL = os.environ.get("DB_URL", "sqlite://")


        def configure(name):
            port = os.getenv("PORT")
            os.environ["NEW_VAR"] = "1"
            del os.environ["OLD_VAR"]
            os.environ.setdefault("MODE", "dev")
            os.putenv("LEGACY", "x")
            value = os.environ[name]
            snapshot = dict(os.environ)
            home = environ["HOME"]
            return os.getenv(f"PREFIX_{name}"), port, value, snapshot, home
        """, path: "app/settings.py")
        let apiKey = try #require(analysis.reference("env:API_KEY", line: 4))
        #expect(apiKey.kind == .read && apiKey.context == "env" && apiKey.receiver == "os.environ")
        #expect(apiKey.atLoad, "a module-level read runs on import")
        #expect(analysis.reference("env:DB_URL", line: 5)?.kind == .read)
        let port = try #require(analysis.reference("env:PORT", line: 9))
        #expect(port.kind == .read && port.atLoad == false && port.receiver == "os")
        #expect(analysis.reference("env:NEW_VAR", line: 10)?.kind == .write)
        #expect(analysis.reference("env:OLD_VAR", line: 11)?.kind == .write)
        #expect(analysis.reference("env:OLD_VAR", line: 11)?.context == "delete")
        #expect(analysis.reference("env:MODE", line: 12)?.kind == .write)
        #expect(analysis.reference("env:LEGACY", line: 13)?.kind == .write)
        #expect(analysis.reference("env:*", line: 14)?.context == "env-dynamic")
        #expect(analysis.reference("env:*", line: 15)?.context == "env-all")
        #expect(analysis.reference("env:HOME", line: 16)?.receiver == "environ")
        #expect(analysis.reference("env:*", line: 17)?.context == "env-dynamic", "an f-string key is computed")
        for name in ["environ", "getenv", "putenv", "setdefault", "os"] {
            #expect(analysis.references(named: name).isEmpty, "\(name) is not a reference of its own")
        }
    }

    @Test func importFlagsForTypeCheckingAndFunctionLevelImports() throws {
        let analysis = try analyze("""
        from typing import TYPE_CHECKING
        import importlib

        if TYPE_CHECKING:
            from .models import User
        else:
            from .runtime import User

        from .base import (
            Base,
            Mixin,
        )


        def load():
            from .heavy import compute
            plugin = importlib.import_module("plugins.extra")
            legacy = __import__("legacy_mod")
            return compute(plugin, legacy)
        """, path: "app/loader.py")
        #expect(analysis.importFor(".models")?.isTypeOnly == true, "imported only for type checkers")
        #expect(analysis.importFor(".runtime")?.isTypeOnly == false, "the else branch runs")
        let base = analysis.imports.filter { $0.module == ".base" }
        #expect(base.map(\.line) == [10, 11])
        #expect(base.allSatisfy { $0.endLine == 12 && !$0.isDynamic })
        #expect(analysis.importFor(".heavy")?.isDynamic == true, "a function-level import runs when called")
        #expect(analysis.importFor("plugins.extra")?.isDynamic == true)
        #expect(analysis.importFor("plugins.extra")?.line == 17)
        #expect(analysis.importFor("legacy_mod")?.isDynamic == true)
        #expect(analysis.importFor("typing")?.isDynamic == false)
        #expect(analysis.importFor("importlib")?.isTypeOnly == false)
    }

    @Test func statementSpansConsumersAndLoadTime() throws {
        let analysis = try analyze("""
        from .db import connect


        def store(data):
            session = connect(
                data.url,
            )
            rows = fetch_rows()
            for row in rows:
                session.add(row)
            return finish(session)


        CONFIG = load_config()
        handler = lambda event: dispatch(event)


        @register("store")
        class Store(Base):
            pass
        """, path: "app/store.py")
        let connect = try #require(analysis.reference("connect", line: 5))
        #expect(connect.column == 15, "columns are 1-based")
        #expect(connect.statementLine == 5 && connect.endLine == 7 && connect.callEndLine == 7)
        #expect(connect.context == "call" && connect.atLoad == false)
        #expect(connect.assignedTo == "session")
        #expect(connect.consumerLine == 10, "the first later statement that reads `session`")
        #expect(analysis.reference("fetch_rows", line: 8)?.assignedTo == "rows")
        #expect(analysis.reference("fetch_rows", line: 8)?.consumerLine == 9, "a loop header reads `rows`")
        #expect(analysis.reference("finish", line: 11)?.assignedTo == "return")

        let config = try #require(analysis.reference("load_config", line: 14))
        #expect(config.atLoad)
        #expect(config.assignedTo == "CONFIG" && config.consumerLine == nil, "module globals have no consumer")
        #expect(analysis.reference("dispatch", line: 15)?.atLoad == false, "a lambda body runs when called")

        let register = try #require(analysis.reference("register", line: 18))
        #expect(register.kind == .decorator && register.context == "decorator" && register.atLoad)
        #expect(register.statementLine == 18 && register.endLine == 18 && register.callEndLine == 18)
        let base = try #require(analysis.reference("Base", line: 19))
        #expect(base.kind == .inherit && base.context == "heritage")
        #expect(base.statementLine == 19 && base.endLine == 19, "a class statement is its header")
    }

    @Test func versionAndStopListsForTheIndex() {
        // A new version re-parses every Python file of an existing index.
        #expect(PythonAnalyzer().version == 2)
        #expect(PythonAnalyzer.stopNames.contains("print"))
        #expect(AnalyzerStopLists.untrackedNames(language: .python) == PythonAnalyzer.stopNames)
    }
}
