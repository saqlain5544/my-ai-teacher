import XCTest
@testable import MyAITeacher

/// Probe (measurement, not a regression test): for each toolchain on this Mac, can a code mentor register a project
/// (`project_tests` set), and once the learner writes a correct solution, can the fenced review run go green?
/// Run with MENTOR_PROBE=1 swift test --filter MentorProbeTests.
final class MentorProbeTests: XCTestCase {
    struct Lang { var name: String; var files: [String: String]; var solution: [String: String]; var command: String; var targets: [String] = ["clamp"] }

    static let langs: [Lang] = [
        Lang(name: "python-pytest", files: ["clamp.py": "def clamp(x, lo, hi):\n    raise NotImplementedError\n",
                                            ".teacher/tests/test_clamp.py": "import sys, os\nsys.path.insert(0, os.getcwd())\nfrom clamp import clamp\ndef test_low():\n    assert clamp(-1, 0, 5) == 0\ndef test_high():\n    assert clamp(9, 0, 5) == 5\n"],
             solution: ["clamp.py": "def clamp(x, lo, hi):\n    return max(lo, min(x, hi))\n"], command: "python3 -m pytest .teacher/tests -q"),
        Lang(name: "python-unittest", files: ["clamp.py": "def clamp(x, lo, hi):\n    raise NotImplementedError\n",
                                              ".teacher/tests/test_clamp.py": "import sys, os, unittest\nsys.path.insert(0, os.getcwd())\nfrom clamp import clamp\nclass T(unittest.TestCase):\n    def test_low(self):\n        self.assertEqual(clamp(-1, 0, 5), 0)\n    def test_high(self):\n        self.assertEqual(clamp(9, 0, 5), 5)\n"],
             solution: ["clamp.py": "def clamp(x, lo, hi):\n    return max(lo, min(x, hi))\n"], command: "python3 -m unittest discover -s .teacher/tests"),
        Lang(name: "node-test", files: ["clamp.js": "export function clamp(x, lo, hi) {\n  throw new Error('TODO');\n}\n",
                                        "package.json": "{\"type\":\"module\"}\n",
                                        ".teacher/tests/clamp.test.js": "import test from 'node:test';\nimport assert from 'node:assert';\nimport { clamp } from '../../clamp.js';\ntest('low', () => assert.equal(clamp(-1, 0, 5), 0));\ntest('high', () => assert.equal(clamp(9, 0, 5), 5));\n"],
             solution: ["clamp.js": "export function clamp(x, lo, hi) {\n  return Math.max(lo, Math.min(x, hi));\n}\n"], command: "node --test .teacher/tests/"),
        Lang(name: "go", files: ["go.mod": "module clamp\n\ngo 1.21\n", "clamp.go": "package clamp\n\nfunc Clamp(x, lo, hi int) int {\n\tpanic(\"TODO\")\n}\n",
                                 "clamp_test.go": "package clamp\n\nimport \"testing\"\n\nfunc TestLow(t *testing.T) { if Clamp(-1, 0, 5) != 0 { t.Fatal(\"low\") } }\nfunc TestHigh(t *testing.T) { if Clamp(9, 0, 5) != 5 { t.Fatal(\"high\") } }\n"],
             solution: ["clamp.go": "package clamp\n\nfunc Clamp(x, lo, hi int) int {\n\tif x < lo {\n\t\treturn lo\n\t}\n\tif x > hi {\n\t\treturn hi\n\t}\n\treturn x\n}\n"], command: "go test ./...", targets: ["Clamp"]),
        Lang(name: "rust-cargo", files: ["Cargo.toml": "[package]\nname = \"clamp\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
                                         "src/lib.rs": "pub fn clamp(x: i32, lo: i32, hi: i32) -> i32 {\n    todo!()\n}\n",
                                         "tests/clamp.rs": "use clamp::clamp;\n#[test] fn low() { assert_eq!(clamp(-1, 0, 5), 0); }\n#[test] fn high() { assert_eq!(clamp(9, 0, 5), 5); }\n"],
             solution: ["src/lib.rs": "pub fn clamp(x: i32, lo: i32, hi: i32) -> i32 {\n    x.max(lo).min(hi)\n}\n"], command: "cargo test -q"),
        Lang(name: "zig", files: ["clamp.zig": "pub fn clamp(x: i32, lo: i32, hi: i32) i32 {\n    _ = x; _ = lo; _ = hi;\n    @panic(\"TODO\");\n}\n",
                                  ".teacher/tests/clamp_test.zig": "const std = @import(\"std\");\nconst c = @import(\"clamp\");\ntest \"low\" { try std.testing.expectEqual(@as(i32, 0), c.clamp(-1, 0, 5)); }\ntest \"high\" { try std.testing.expectEqual(@as(i32, 5), c.clamp(9, 0, 5)); }\n"],
             solution: ["clamp.zig": "pub fn clamp(x: i32, lo: i32, hi: i32) i32 {\n    return @max(lo, @min(x, hi));\n}\n"],
             command: "zig test --dep clamp -Mroot=.teacher/tests/clamp_test.zig -Mclamp=clamp.zig"),
        Lang(name: "c-make", files: ["clamp.c": "#include \"clamp.h\"\n#include <stdlib.h>\nint clamp(int x, int lo, int hi) {\n    abort(); /* TODO */\n}\n", "clamp.h": "int clamp(int x, int lo, int hi);\n",
                                     "Makefile": "test: runner\n\t./runner\nrunner: clamp.c .teacher/tests/test_clamp.c\n\tcc -o runner clamp.c .teacher/tests/test_clamp.c -I.\n",
                                     ".teacher/tests/test_clamp.c": "#include <stdio.h>\n#include \"clamp.h\"\nint main(void) {\n  int f = 0;\n  if (clamp(-1, 0, 5) != 0) { puts(\"FAIL low\"); f++; }\n  if (clamp(9, 0, 5) != 5) { puts(\"FAIL high\"); f++; }\n  printf(\"%d passed, %d failed\\n\", 2 - f, f);\n  return f != 0;\n}\n"],
             solution: ["clamp.c": "#include \"clamp.h\"\nint clamp(int x, int lo, int hi) {\n    if (x < lo) return lo;\n    if (x > hi) return hi;\n    return x;\n}\n"], command: "make -s test"),
        Lang(name: "java-javac", files: ["Clamp.java": "public class Clamp {\n    public static int clamp(int x, int lo, int hi) {\n        throw new UnsupportedOperationException(\"TODO\");\n    }\n}\n",
                                         ".teacher/tests/ClampTest.java": "public class ClampTest {\n  public static void main(String[] a) {\n    int f = 0;\n    try { if (Clamp.clamp(-1, 0, 5) != 0) f++; } catch (Exception e) { f++; }\n    try { if (Clamp.clamp(9, 0, 5) != 5) f++; } catch (Exception e) { f++; }\n    System.out.println(\"Tests run: 2, Failures: \" + f);\n    System.exit(f == 0 ? 0 : 1);\n  }\n}\n"],
             solution: ["Clamp.java": "public class Clamp {\n    public static int clamp(int x, int lo, int hi) {\n        return Math.max(lo, Math.min(x, hi));\n    }\n}\n"],
             command: "javac -d classes Clamp.java .teacher/tests/ClampTest.java && java -cp classes ClampTest"),
        Lang(name: "ruby-minitest", files: ["clamp.rb": "def clamp(x, lo, hi)\n  raise NotImplementedError\nend\n",
                                            ".teacher/tests/test_clamp.rb": "require 'minitest/autorun'\nrequire_relative '../../clamp'\nclass T < Minitest::Test\n  def test_low; assert_equal 0, clamp(-1, 0, 5); end\n  def test_high; assert_equal 5, clamp(9, 0, 5); end\nend\n"],
             solution: ["clamp.rb": "def clamp(x, lo, hi)\n  [[x, lo].max, hi].min\nend\n"], command: "ruby .teacher/tests/test_clamp.rb"),
        Lang(name: "elixir-exunit", files: ["clamp.ex": "defmodule C do\n  def clamp(x, lo, hi) do\n    raise \"TODO\"\n  end\nend\n",
                                            ".teacher/tests/clamp_test.exs": "Code.require_file(\"clamp.ex\")\nExUnit.start()\ndefmodule CT do\n  use ExUnit.Case\n  test \"low\", do: assert C.clamp(-1, 0, 5) == 0\n  test \"high\", do: assert C.clamp(9, 0, 5) == 5\nend\n"],
             solution: ["clamp.ex": "defmodule C do\n  def clamp(x, lo, hi) do\n    x |> max(lo) |> min(hi)\n  end\nend\n"], command: "elixir .teacher/tests/clamp_test.exs"),
        Lang(name: "deno", files: ["clamp.ts": "export function clamp(x: number, lo: number, hi: number): number {\n  throw new Error(\"TODO\");\n}\n",
                                   ".teacher/tests/clamp_test.ts": "import { clamp } from \"../../clamp.ts\";\nDeno.test(\"low\", () => { if (clamp(-1, 0, 5) !== 0) throw new Error(\"low\"); });\nDeno.test(\"high\", () => { if (clamp(9, 0, 5) !== 5) throw new Error(\"high\"); });\n"],
             solution: ["clamp.ts": "export function clamp(x: number, lo: number, hi: number): number {\n  return Math.max(lo, Math.min(x, hi));\n}\n"], command: "deno test .teacher/tests/"),
        Lang(name: "bun", files: ["clamp.ts": "export function clamp(x: number, lo: number, hi: number): number {\n  throw new Error(\"TODO\");\n}\n",
                                  ".teacher/tests/clamp.test.ts": "import { test, expect } from \"bun:test\";\nimport { clamp } from \"../../clamp.ts\";\ntest(\"low\", () => expect(clamp(-1, 0, 5)).toBe(0));\ntest(\"high\", () => expect(clamp(9, 0, 5)).toBe(5));\n"],
             solution: ["clamp.ts": "export function clamp(x: number, lo: number, hi: number): number {\n  return Math.max(lo, Math.min(x, hi));\n}\n"], command: "bun test ./.teacher/tests/clamp.test.ts"),
        Lang(name: "sql-sqlite", files: ["query.sql": "-- TODO: select the names of users older than 30, alphabetically\n",
                                         ".teacher/tests/check.sh": "out=$(sqlite3 :memory: \"create table u(name,age); insert into u values('b',40),('a',35),('c',20);\" \"$(cat query.sql)\")\n[ \"$out\" = \"$(printf 'a\\nb')\" ] && echo '1 passed, 0 failed' || { echo '0 passed, 1 failed'; exit 1; }\n"],
             solution: ["query.sql": "select name from u where age > 30 order by name;\n"], command: "sh .teacher/tests/check.sh", targets: []),
    ]

    @MainActor func testProbe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MENTOR_PROBE"] == "1")
        var rows: [String] = []
        for l in Self.langs {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(l.name)-\(UUID().uuidString.prefix(4))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("../\(dir.lastPathComponent).sqlite").path)), workspace: try Workspace(url: dir))
            let ws = services.workspace
            func put(_ files: [String: String]) throws {
                for (k, v) in files { let u = dir.appendingPathComponent(k); try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try v.write(to: u, atomically: true, encoding: .utf8) }
            }
            try put(l.files)
            let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
            let ctx = ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                                  client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
            let set = try await ProjectTestsTool().run(["action": "set", "command": .string(l.command), "targets": .array(l.targets.map { .string($0) }), "concept": "clamp"], ctx)
            let accepted = !set.isError
            try put(l.solution)
            let free = await ProjectTestRunner.run(l.command, ws: ws, timeout: 180, why: "probe", record: false)
            var fenced = "-"
            if accepted {
                let r = await WriteFence.$profile.withValue(MentorGuard.fence(ws)) { await ProjectTestRunner.run(l.command, ws: ws, timeout: 180, why: "review", record: false) }
                fenced = r.0.green ? "green" : (r.0.errored ? "ERRORED" : "red") + " " + String(r.1.suffix(160)).replacingOccurrences(of: "\n", with: " ⏎ ")
            }
            rows.append("| \(l.name) | \(accepted ? "accepted" : "REFUSED: " + String(set.text.prefix(140)).replacingOccurrences(of: "\n", with: " ")) | \(free.0.green ? "green" : "not green (\(free.0.line))") | \(fenced) |")
        }
        print("PROBE-TABLE\n| toolchain | `project_tests set` on a red starter | correct solution, unfenced | correct solution, fenced review run |\n|---|---|---|---|\n" + rows.joined(separator: "\n"))
    }
}

