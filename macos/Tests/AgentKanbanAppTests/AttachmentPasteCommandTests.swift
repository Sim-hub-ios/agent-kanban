import AppKit
import Testing
@testable import AgentKanban

@Suite("Native paste command routing") @MainActor
struct AttachmentPasteCommandTests {
    private func imageData() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func pasteMenu(_ editor: NSTextView) -> (NSMenu, NSMenuItem) {
        _ = NSApplication.shared
        let menu = NSMenu(title: "Edit")
        let item = NSMenuItem(title: "Paste", action: #selector(NSTextView.paste(_:)), keyEquivalent: "v")
        item.keyEquivalentModifierMask = .command
        item.target = editor
        menu.addItem(item)
        return (menu, item)
    }

    private func commandV() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    }

    @Test func plainTextEditorAdvertisesImageAndFilePasteToAppKit() throws {
        let editor = AttachmentEditorView().editor
        #expect(!editor.isRichText)
        #expect(!editor.importsGraphics)
        let pasteboard = NSPasteboard(name: .init("kanban-paste-command-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = try imageData()
        #expect(pasteboard.setData(image, forType: .png))
        #expect(pasteboard.availableType(from: editor.readablePasteboardTypes) != nil,
                "AppKit must recognize PNG as pasteable before it dispatches the Paste menu / Command-V")
        pasteboard.clearContents()
        #expect(pasteboard.setData(image, forType: .tiff))
        #expect(pasteboard.availableType(from: editor.readablePasteboardTypes) != nil)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/fixture.png") as NSURL]))
        #expect(pasteboard.availableType(from: editor.readablePasteboardTypes) != nil)
    }

    @Test func commandVDispatchesThroughEnabledMenuAndCreatesImageAttachment() throws {
        let board = NSPasteboard(name: .init("kanban-paste-command-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(board.setData(try imageData(), forType: .png))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-paste-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = AttachmentEditorView(), editor = container.editor
        editor.string = "Existing task description\nSecond line"
        editor.pasteboardProvider = { board }
        var urls: [URL] = [], calls = 0
        editor.onPasteAttachments = { pasteboard in
            calls += 1
            let result = ClipboardAttachmentReader.read(from: pasteboard, directory: directory)
            urls.append(contentsOf: result.urls)
            return result.handled
        }
        let (menu, item) = pasteMenu(editor)
        menu.update()
        #expect(item.isEnabled, "Image-only Paste must be enabled before Command-V can reach paste(_:)")
        #expect(editor.validateUserInterfaceItem(item))
        #expect(urls.isEmpty, "Menu validation must not materialize clipboard images")
        #expect(calls == 0)
        #expect(menu.performKeyEquivalent(with: try commandV()))
        #expect(calls == 1)
        #expect(urls.count == 1)
        let image = try #require(urls.first)
        #expect(NSImage(contentsOf: image) != nil)
        #expect(editor.string == "Existing task description\nSecond line", "Image attachments must not be embedded in plain text")
    }

    @Test func disabledEmptyAndUnsupportedClipboardsDisablePasteWithoutReadingPayloads() throws {
        let board = NSPasteboard(name: .init("kanban-paste-command-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let editor = AttachmentEditorView().editor
        editor.pasteboardProvider = { board }
        var called = false
        editor.onPasteAttachments = { _ in called = true; return true }
        let (menu, item) = pasteMenu(editor)
        menu.update(); #expect(!item.isEnabled)
        #expect(board.setString("custom", forType: .init("com.agentkanban.unsupported")))
        menu.update(); #expect(!item.isEnabled)
        board.clearContents(); #expect(board.setData(try imageData(), forType: .png))
        editor.isEditable = false
        menu.update(); #expect(!item.isEnabled)
        editor.paste(nil)
        #expect(!called)
    }

    @Test func finderFileCommandVUsesSameAttachmentRoute() throws {
        let board = NSPasteboard(name: .init("kanban-paste-command-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-paste-file-\(UUID().uuidString).txt")
        try Data("file fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(board.writeObjects([file as NSURL]))
        let editor = AttachmentEditorView().editor
        editor.pasteboardProvider = { board }
        var urls: [URL] = []
        editor.onPasteAttachments = { pasteboard in
            let result = ClipboardAttachmentReader.read(from: pasteboard)
            urls = result.urls; return result.handled
        }
        let (menu, item) = pasteMenu(editor)
        menu.update(); #expect(item.isEnabled)
        #expect(menu.performKeyEquivalent(with: try commandV()))
        #expect(urls == [file.standardizedFileURL.resolvingSymlinksInPath()])
    }

    @Test func nativeSelectionPasteKeepsMultilineTextAndRoutesImages() throws {
        let board = NSPasteboard(name: .init("kanban-paste-command-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let editor = AttachmentEditorView().editor
        editor.pasteboardProvider = { board }
        var images = 0
        editor.onPasteAttachments = { pasteboard in
            guard pasteboard.types?.contains(.png) == true else { return false }
            images += 1; return true
        }
        #expect(board.setString("第一行\n第二行", forType: .string))
        let (menu, item) = pasteMenu(editor)
        menu.update(); #expect(item.isEnabled)
        #expect(editor.readSelection(from: board, type: .string))
        #expect(editor.string == "第一行\n第二行")
        board.clearContents(); #expect(board.setData(try imageData(), forType: .png))
        #expect(editor.readSelection(from: board, type: .png))
        #expect(images == 1)
        #expect(editor.string == "第一行\n第二行")
    }

    @Test func explicitlyPlainTextPasteDoesNotConsumeImageFromMixedClipboard() throws {
        let board = NSPasteboard(name: .init("kanban-paste-command-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(board.setString("Plain text\nSecond line", forType: .string))
        #expect(board.setData(try imageData(), forType: .png))
        let editor = AttachmentEditorView().editor
        var attachmentCalled = false
        editor.onPasteAttachments = { _ in attachmentCalled = true; return true }
        #expect(editor.readSelection(from: board, type: .string))
        #expect(!attachmentCalled)
        #expect(editor.string == "Plain text\nSecond line")
    }
}
