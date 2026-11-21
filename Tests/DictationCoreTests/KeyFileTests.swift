import Foundation
import Testing
@testable import DictationCore

@Suite struct KeyFileTests {
    private func temp() -> KeyFile {
        KeyFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("whisper-key-\(UUID().uuidString)"))
    }

    @Test func savesAndReadsTheKeyTrimmed() throws {
        let file = temp()
        defer { try? file.remove() }
        #expect(file.read() == nil)
        try file.write("  sk-test-123\n")
        #expect(file.read() == "sk-test-123")
    }

    @Test func onlyTheOwnerCanReadIt() throws {
        let file = temp()
        defer { try? file.remove() }
        try file.write("sk-test")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func anEmptyKeyRemovesTheFile() throws {
        let file = temp()
        try file.write("sk-test")
        try file.write("   ")
        #expect(file.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }
}
