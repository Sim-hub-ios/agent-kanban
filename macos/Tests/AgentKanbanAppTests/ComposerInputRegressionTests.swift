import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AgentKanban

/// These tests host the actual composer. They do not reproduce its placeholder condition in a test-only view.
@Suite("Composer native input regressions", .serialized) @MainActor
struct ComposerInputRegressionTests {
    private let placeholder = "Composer placeholder probe"

    @MainActor private final class HostedComposer {
        let directory: URL
        let store: AppStore
        let window: NSWindow
        let host: NSHostingView<ComposerView>
        var editor: AttachmentPasteTextView {
            get throws {
                try #require(Self.descendants(host).compactMap { $0 as? AttachmentPasteTextView }.first)
            }
        }

        init(placeholder: String) {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-composer-input-\(UUID().uuidString)", isDirectory: true)
            store = AppStore(dataDirectory: directory)
            host = NSHostingView(rootView: ComposerView(store: store, conversationID: "composer-fixture", placeholder: placeholder))
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 150)
            host.appearance = NSAppearance(named: .aqua)
            window = NSWindow(contentRect: NSRect(x: -2_000, y: 2_000, width: 760, height: 150),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            // The test window remains offscreen and is never activated or made key.
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
        }

        func settle() async throws {
            // Allow real SwiftUI binding and accessibility updates, without pumping arbitrary application events.
            await Task.yield()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        func close() {
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }

        private static func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
    }

    @MainActor private final class HostedSurface<Content: View> {
        let directory: URL
        let store: AppStore
        let window: NSWindow
        let host: NSHostingView<Content>
        var editor: AttachmentPasteTextView {
            get throws {
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                return try #require(descendants(host).compactMap { $0 as? AttachmentPasteTextView }.first)
            }
        }
        init(size: NSSize, content: (AppStore) -> Content) {
            _ = NSApplication.shared
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("kanban-editor-surface-\(UUID().uuidString)", isDirectory: true)
            store = AppStore(dataDirectory: directory)
            host = NSHostingView(rootView: content(store))
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: .aqua)
            window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -2_000, y: 2_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
        }
        func settle() async throws {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        func close() {
            window.contentView = nil
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor private final class EditorBindings {
        var text = ""
        var attachments: [URL] = []
        func view(placeholder: String) -> AttachmentTextEditor {
            AttachmentTextEditor(text: Binding(get: { self.text }, set: { self.text = $0 }),
                                 attachments: Binding(get: { self.attachments }, set: { self.attachments = $0 }),
                                 accessibilityLabel: "Programmatic editor update fixture", placeholder: placeholder)
        }
    }

    @MainActor private struct BitmapCapture {
        let image: NSBitmapImageRep
        let pointSize: NSSize

        func ink(in region: NSRect) -> (count: Int, bounds: NSRect?) {
            let scaleX = CGFloat(image.pixelsWide) / pointSize.width
            let scaleY = CGFloat(image.pixelsHigh) / pointSize.height
            var count = 0
            var bounds: NSRect?
            let left = max(0, Int(region.minX * scaleX)), right = min(image.pixelsWide, Int(region.maxX * scaleX))
            let top = max(0, Int(region.minY * scaleY)), bottom = min(image.pixelsHigh, Int(region.maxY * scaleY))
            guard left < right, top < bottom else { return (0, nil) }
            for y in top..<bottom {
                for x in left..<right {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5,
                          color.redComponent < 0.8, color.greenComponent < 0.8, color.blueComponent < 0.85 else { continue }
                    count += 1
                    let pixel = NSRect(x: CGFloat(x) / scaleX, y: CGFloat(y) / scaleY, width: 1 / scaleX, height: 1 / scaleY)
                    bounds = bounds.map { $0.union(pixel) } ?? pixel
                }
            }
            return (count, bounds)
        }
    }

    private func capture(_ fixture: HostedComposer, name: String) throws -> BitmapCapture {
        let bounds = fixture.host.bounds
        let bitmap = try #require(fixture.host.bitmapImageRepForCachingDisplay(in: bounds))
        fixture.host.cacheDisplay(in: bounds, to: bitmap)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("validation/composer-input-20261008", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        return BitmapCapture(image: bitmap, pointSize: bounds.size)
    }

    // To the right of the short marked/committed strings, only the long placeholder can produce ink.
    private let placeholderTail = NSRect(x: 90, y: 20, width: 130, height: 35)

    @Test func markedChineseCompositionHidesActualPlaceholderBeforeCommittedBindingChanges() async throws {
        let fixture = HostedComposer(placeholder: placeholder)
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try fixture.editor
        let coordinator = try #require(editor.delegate as? AttachmentTextEditor.Coordinator)
        let before = try capture(fixture, name: "ime-before")
        let beforeInk = before.ink(in: placeholderTail).count
        try #require(beforeInk > 8, "The real placeholder tail must be present in the cached composer bitmap before checking overlap")
        #expect(coordinator.parent.text.isEmpty)
        editor.setMarkedText("qq'q", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(editor.hasMarkedText(), "Exercise AppKit marked text, not only a placeholder Boolean")
        #expect(editor.string == "qq'q")
        let marked = try capture(fixture, name: "ime-marked")
        let actualPlaceholderInk = marked.ink(in: placeholderTail).count
        print("composer-ime-probe binding_utf16=\(coordinator.parent.text.utf16.count) native_utf16=\(editor.string.utf16.count) marked=\(editor.hasMarkedText()) before_placeholder_ink=\(beforeInk) marked_placeholder_ink=\(actualPlaceholderInk)")
        #expect(actualPlaceholderInk == 0, "Placeholder pixels must not remain beside the native IME marked text even while the SwiftUI binding is still empty")

        editor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "中文")
        #expect(coordinator.parent.text == "中文")
        #expect(try capture(fixture, name: "ime-committed").ink(in: placeholderTail).count == 0)

        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("", replacementRange: editor.selectedRange())
        try await fixture.settle()
        #expect(editor.string.isEmpty && coordinator.parent.text.isEmpty)
        #expect(try capture(fixture, name: "ime-cleared").ink(in: placeholderTail).count > 8, "The placeholder must return after committed content is removed")
    }

    @Test func cancellingMarkedCompositionRestoresPlaceholderOnlyAfterNativeTextIsEmpty() async throws {
        let fixture = HostedComposer(placeholder: placeholder)
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try fixture.editor
        try #require(try capture(fixture, name: "cancel-before").ink(in: placeholderTail).count > 8)
        editor.setMarkedText("pin'yin", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(editor.hasMarkedText())
        #expect(try capture(fixture, name: "cancel-marked").ink(in: placeholderTail).count == 0, "An in-progress IME candidate is already visible text")
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor.markedRange())
        editor.unmarkText()
        try await fixture.settle()
        #expect(!editor.hasMarkedText() && editor.string.isEmpty)
        #expect(try capture(fixture, name: "cancel-cleared").ink(in: placeholderTail).count > 8)
    }

    @Test func realComposerPlaceholderSharesCaretXAndFirstTextBaseline() async throws {
        let fixture = HostedComposer(placeholder: "H")
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try fixture.editor
        let glyphRegion = NSRect(x: 16, y: 16, width: 34, height: 45)
        let placeholderInk = try #require(try capture(fixture, name: "layout-placeholder").ink(in: glyphRegion).bounds)
        let caret = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        try #require(caret.height > 0, "An insertion caret may have zero width, but must have a native line height")

        editor.insertText("H", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        let manager = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        manager.ensureLayout(for: container)
        try #require(manager.numberOfGlyphs > 0)
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = manager.location(forGlyphAt: 0)
        let origin = editor.textContainerOrigin
        let nativeBaselinePoint = editor.convert(NSPoint(x: origin.x + line.minX + glyph.x,
                                                        y: origin.y + line.minY + glyph.y), to: nil)
        let nativeBaseline = fixture.window.convertPoint(toScreen: nativeBaselinePoint).y
        let nativeInk = try #require(try capture(fixture, name: "layout-native").ink(in: glyphRegion).bounds)
        let xDifference = placeholderInk.minX - nativeInk.minX
        let baselineDifference = placeholderInk.maxY - nativeInk.maxY
        print("composer-layout-probe caret_x=\(caret.minX) placeholder_glyph=\(placeholderInk) native_glyph=\(nativeInk) x_delta=\(xDifference) native_baseline=\(nativeBaseline) glyph_bottom_delta=\(baselineDifference) text_inset_y=\(editor.textContainerInset.height)")
        #expect(abs(xDifference) <= 1, "The actual placeholder H and native H must share the horizontal origin")
        #expect(abs(baselineDifference) <= 1, "The actual placeholder H and native H must share the glyph baseline")
    }

    @Test func nativeMultilineCommitDoesNotChangeReturnIntoSendOrBreakTextBinding() async throws {
        let fixture = HostedComposer(placeholder: placeholder)
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try fixture.editor
        let coordinator = try #require(editor.delegate as? AttachmentTextEditor.Coordinator)
        editor.insertText("第一行", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertNewline(nil)
        editor.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(editor.string == "第一行\n第二行")
        #expect(coordinator.parent.text == editor.string)
        #expect(fixture.store.snapshot.runs.isEmpty)
        #expect(try capture(fixture, name: "multiline-native").ink(in: placeholderTail).count == 0)
    }

    @Test func actualTaskSheetDescriptionHidesPlaceholderForMarkedTextAndRestoresItAfterCancellation() async throws {
        let fixture = HostedSurface(size: NSSize(width: 760, height: 700)) { TaskEditorSheet(store: $0) }
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try fixture.editor
        let coordinator = try #require(editor.delegate as? AttachmentTextEditor.Coordinator)
        #expect(editor.accessibilityLabel() == "说明与备注，多行编辑")
        #expect(editor.textContainerInset == .zero)
        #expect(editor.placeholder.contains("支持多行输入"))
        #expect(editor.isPlaceholderVisible && coordinator.parent.text.isEmpty)
        let placeholderOrigin = try #require(editor.placeholderFirstGlyphOrigin)
        editor.setMarkedText("qq'q", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(editor.hasMarkedText() && editor.string == "qq'q")
        #expect(!editor.isPlaceholderVisible)
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: editor.markedRange())
        editor.unmarkText()
        try await fixture.settle()
        #expect(!editor.hasMarkedText() && editor.string.isEmpty && coordinator.parent.text.isEmpty)
        #expect(editor.isPlaceholderVisible)
        editor.setMarkedText("zhong'wen", selectedRange: NSRange(location: 9, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("中文备注\n保留换行", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(!editor.hasMarkedText() && editor.string == "中文备注\n保留换行")
        #expect(coordinator.parent.text == editor.string && !editor.isPlaceholderVisible)
        let manager = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        manager.ensureLayout(for: container)
        let line = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = manager.location(forGlyphAt: 0)
        #expect(abs(placeholderOrigin.x - (editor.textContainerOrigin.x + line.minX + glyph.x)) <= 0.5)
        #expect(abs(placeholderOrigin.y - (editor.textContainerOrigin.y + line.minY + glyph.y)) <= 0.5)
    }

    @Test func actualRepresentableUpdateDoesNotReplaceAnInProgressNativeComposition() async throws {
        let bindings = EditorBindings()
        let fixture = HostedSurface(size: NSSize(width: 500, height: 90)) { _ in bindings.view(placeholder: "Original native placeholder") }
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try fixture.editor
        editor.setMarkedText("pin'yin", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(bindings.text.isEmpty && editor.hasMarkedText())
        // A real SwiftUI representable refresh with a different bound value must preserve IME ownership.
        bindings.text = "External binding update"
        fixture.host.rootView = bindings.view(placeholder: "Updated native placeholder")
        try await fixture.settle()
        let refreshed = try fixture.editor
        #expect(refreshed === editor, "Exercise updateNSView on the existing editor rather than building an unrelated test object")
        #expect(editor.placeholder == "Updated native placeholder", "Prove the actual representable update has run")
        #expect(editor.hasMarkedText() && editor.string == "pin'yin")
        #expect(!editor.isPlaceholderVisible)
        editor.insertText("拼音", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(!editor.hasMarkedText() && editor.string == "拼音" && bindings.text == "拼音")
        bindings.text = "Programmatic committed draft"
        fixture.host.rootView = bindings.view(placeholder: "Committed update placeholder")
        try await fixture.settle()
        #expect(editor.placeholder == "Committed update placeholder")
        #expect(editor.string == bindings.text, "Ordinary external updates still apply after composition commits")
    }

    @Test func changingRealComposerConversationDoesNotCarryOldCommittedOrMarkedInput() async throws {
        let fixture = HostedComposer(placeholder: placeholder)
        defer { fixture.close() }
        try await fixture.settle()
        let original = try fixture.editor
        original.insertText("Conversation A unsent draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        original.setMarkedText("qq'q", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(original.hasMarkedText())
        fixture.host.rootView = ComposerView(store: fixture.store, conversationID: "conversation-b", placeholder: placeholder)
        try await fixture.settle()
        let next = try fixture.editor
        let coordinator = try #require(next.delegate as? AttachmentTextEditor.Coordinator)
        #expect(next !== original)
        #expect(next.string.isEmpty && !next.hasMarkedText() && coordinator.parent.text.isEmpty)
        #expect(next.isPlaceholderVisible)
        next.insertText("Conversation B unsent draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await fixture.settle()
        #expect(coordinator.parent.text == "Conversation B unsent draft")
        fixture.host.rootView = ComposerView(store: fixture.store, conversationID: "composer-fixture", placeholder: placeholder)
        try await fixture.settle()
        let returned = try fixture.editor
        #expect(returned !== next)
        #expect(returned.string.isEmpty && !returned.hasMarkedText() && returned.isPlaceholderVisible)
        #expect(fixture.store.snapshot.messages.isEmpty && fixture.store.snapshot.runs.isEmpty)
    }
}
