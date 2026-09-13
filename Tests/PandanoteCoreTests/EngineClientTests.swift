import Foundation
import Darwin
import XCTest
@testable import PandanoteCore

final class EngineClientTests: XCTestCase {
    func test_cancelledPreview_terminatesEvenWhenEngineIgnoresTermination() async throws {
        let fixture = try Fixture("process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);")
        defer { fixture.remove() }
        let client = EngineClient(script: fixture.script)
        let task = Task { try await client.call(action: "preview", root: fixture.root, file: nil, text: "", nodePath: fixture.node) }
        let pid = try await fixture.waitForProcess()
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled preview must throw") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "The cancelled engine must be reaped")
    }

    func test_previewDeadline_terminatesHungEngineAndReportsTimeout() async throws {
        let fixture = try Fixture("process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);")
        defer { fixture.remove() }
        let client = EngineClient(script: fixture.script, previewLimits: .init(timeout: 0.15, maximumOutputBytes: 1024))
        let started = Date()
        do {
            _ = try await client.call(action: "preview", root: fixture.root, file: nil, text: "", nodePath: fixture.node)
            XCTFail("A hung preview must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too long"), "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(Darwin.kill(try fixture.processID(), 0), -1)
    }

    func test_previewOutputLimit_stopsStdoutAndStderrFloods() async throws {
        for stream in ["stdout", "stderr"] {
            let fixture = try Fixture("const fill = () => { while (process.\(stream).write(Buffer.alloc(65536, 120))) {} }; process.\(stream).on('drain', fill); fill();")
            defer { fixture.remove() }
            let client = EngineClient(script: fixture.script, previewLimits: .init(timeout: 3, maximumOutputBytes: 128 * 1024))
            do {
                _ = try await client.call(action: "preview", root: fixture.root, file: nil, text: "", nodePath: fixture.node)
                XCTFail("An unbounded \(stream) stream must stop")
            } catch { XCTAssertTrue(error.localizedDescription.contains("too large"), "\(stream): \(error)") }
            XCTAssertEqual(Darwin.kill(try fixture.processID(), 0), -1)
        }
    }

    func test_preview_drainsBothStreamsWhileSendingLargeInput() async throws {
        let fixture = try Fixture("""
        process.stdin.pause();
        process.stdout.write('x'.repeat(1024 * 1024));
        process.stderr.write('diagnostic'.repeat(65536));
        let input = ''; process.stdin.on('data', c => input += c);
        process.stdin.on('end', () => { process.stdout.write(JSON.parse(input).text.length.toString()); });
        process.stdin.resume();
        """)
        defer { fixture.remove() }
        let client = EngineClient(script: fixture.script, previewLimits: .init(timeout: 3, maximumOutputBytes: 4 * 1024 * 1024))
        let data = try await client.call(action: "preview", root: fixture.root, file: nil,
                                        text: String(repeating: "a", count: 1024 * 1024), nodePath: fixture.node)
        XCTAssertEqual(data.count, 1024 * 1024 + 7)
        XCTAssertTrue(String(decoding: data.suffix(7), as: UTF8.self) == "1048576")
    }

    func test_explicitRun_isUnaffectedByPreviewLimitsAndCancellation() async throws {
        let fixture = try Fixture("setTimeout(() => { process.stdout.write(JSON.stringify({ success: true })); }, 200);")
        defer { fixture.remove() }
        let client = EngineClient(script: fixture.script, previewLimits: .init(timeout: 0.01, maximumOutputBytes: 1))
        let task = Task { try await client.call(action: "run", root: fixture.root, file: nil, text: "", trusted: true, nodePath: fixture.node) }
        _ = try await fixture.waitForProcess()
        task.cancel()
        let data = try await task.value
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: Bool], ["success": true])
    }

    private struct Fixture {
        let root: URL
        let script: URL
        let node: String
        init(_ body: String) throws {
            guard let runtime = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw XCTSkip("Node is needed for engine subprocess tests")
            }
            node = runtime
            root = FileManager.default.temporaryDirectory.appendingPathComponent("pandanote-engine-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            script = root.appendingPathComponent("engine.cjs")
            try ("require('node:fs').writeFileSync('engine.pid', process.pid.toString());\n" + body).write(to: script, atomically: true, encoding: .utf8)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func processID() throws -> pid_t {
            let text = try String(contentsOf: root.appendingPathComponent("engine.pid"), encoding: .utf8)
            return try XCTUnwrap(pid_t(text))
        }
        func waitForProcess() async throws -> pid_t {
            for _ in 0..<300 {
                if let pid = try? processID() { return pid }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw EngineFailure.failed("Test engine did not start")
        }
    }
}
