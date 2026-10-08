import AppKit
import Foundation
import Testing
@testable import AgentKanban

@Suite("Native clipboard attachments") @MainActor
struct ClipboardAttachmentTests {
    private func isolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("agent-kanban-clipboard-test-\(UUID().uuidString)"))
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-clipboard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func imageData(_ format: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        return try #require(bitmap.representation(using: format, properties: [:]))
    }

    @Test func screenshotPNGIsSavedAsAReadableDraftAttachmentAndDeduplicated() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try imageData(.png)
        #expect(pasteboard.setData(image, forType: .png))
        let result = ClipboardAttachmentReader.read(from: pasteboard, directory: directory)
        #expect(result.handled)
        #expect(result.errors.isEmpty)
        let url = try #require(result.urls.first)
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == image)
        #expect(NSImage(contentsOf: url) != nil)
        let repeated = ClipboardAttachmentReader.read(from: pasteboard, existingURLs: result.urls, directory: directory)
        #expect(repeated.handled)
        #expect(repeated.urls.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
    }

    @Test func screenshotTIFFConvertsToPNG() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(pasteboard.setData(try imageData(.tiff), forType: .tiff))
        let result = ClipboardAttachmentReader.read(from: pasteboard, directory: directory)
        #expect(result.errors.isEmpty)
        let url = try #require(result.urls.first)
        #expect(url.pathExtension == "png")
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10])
    }

    @Test func finderFileURLsAreAttachedAndCanonicalDuplicatesAreSkipped() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("任务清单.xlsx")
        try Data("file fixture".utf8).write(to: file)
        #expect(pasteboard.writeObjects([file as NSURL]))
        let result = ClipboardAttachmentReader.read(from: pasteboard)
        #expect(result.handled)
        #expect(result.errors.isEmpty)
        #expect(result.urls == [file.standardizedFileURL.resolvingSymlinksInPath()])
        let repeated = ClipboardAttachmentReader.read(from: pasteboard, existingURLs: [file])
        #expect(repeated.urls.isEmpty)
    }

    @Test func ordinaryTextAndMultilineTextRemainNormalTextPaste() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let text = "补充问题描述\n第二行：保留换行\nfile:///tmp/example.png"
        #expect(pasteboard.setString(text, forType: .string))
        let result = ClipboardAttachmentReader.read(from: pasteboard)
        #expect(!result.handled)
        #expect(result.urls.isEmpty)
        #expect(result.errors.isEmpty)
        #expect(pasteboard.string(forType: .string) == text)
    }

    @Test func directoriesAndOversizedFilesAreRejectedWithoutConsumingValidFiles() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("notes.txt")
        try Data("valid".utf8).write(to: valid)
        let oversized = directory.appendingPathComponent("too-large.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ClipboardAttachmentReader.maximumFileSize + 1))
        try handle.close()
        #expect(pasteboard.writeObjects([directory as NSURL, oversized as NSURL, valid as NSURL]))
        let result = ClipboardAttachmentReader.read(from: pasteboard)
        #expect(result.handled)
        #expect(result.urls == [valid.standardizedFileURL.resolvingSymlinksInPath()])
        #expect(result.errors.count == 2)
        #expect(result.errors.contains { $0.contains("文件夹") })
        #expect(result.errors.contains { $0.contains("25 MB") })
    }

    @Test func malformedAndOversizedClipboardImagesReportErrors() throws {
        let pasteboard = isolatedPasteboard()
        defer { pasteboard.releaseGlobally() }
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(pasteboard.setData(Data("not an image".utf8), forType: .png))
        let malformed = ClipboardAttachmentReader.read(from: pasteboard, directory: directory)
        #expect(malformed.handled)
        #expect(malformed.urls.isEmpty)
        #expect(malformed.errors.count == 1)
        pasteboard.clearContents()
        #expect(pasteboard.setData(Data(repeating: 0, count: ClipboardAttachmentReader.maximumFileSize + 1), forType: .png))
        let oversized = ClipboardAttachmentReader.read(from: pasteboard, directory: directory)
        #expect(oversized.handled)
        #expect(oversized.urls.isEmpty)
        #expect(oversized.errors.first?.contains("25 MB") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
