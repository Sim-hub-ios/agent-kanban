import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardAttachmentReadResult {
    var handled: Bool
    var urls: [URL] = []
    var errors: [String] = []
}

/// Reads a supplied pasteboard only in response to Paste; tests use isolated named pasteboards.
@MainActor
enum ClipboardAttachmentReader {
    static let maximumFileSize = 25 * 1024 * 1024
    static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"), (.tiff, "tiff"), (.init(UTType.jpeg.identifier), "jpg"), (.init(UTType.heic.identifier), "heic")
    ]
    static var attachmentTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .init("NSFilenamesPboardType")] + imageTypes.map(\.0)
    }
    static var draftDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AgentKanban/DraftAttachments", isDirectory: true)
    }

    static func read(from pasteboard: NSPasteboard, existingURLs: [URL] = [], directory: URL = draftDirectory) -> ClipboardAttachmentReadResult {
        if (pasteboard.pasteboardItems ?? []).contains(where: { $0.types.contains(.fileURL) }) {
            let fileURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !fileURLs.isEmpty else {
                return ClipboardAttachmentReadResult(handled: true, errors: ["无法读取剪贴板中的文件，请重新复制后粘贴。"])
            }
            return files(fileURLs, existingURLs: existingURLs)
        }
        if let filenames = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String], !filenames.isEmpty {
            return files(filenames.map { URL(fileURLWithPath: $0) }, existingURLs: existingURLs)
        }

        var result = ClipboardAttachmentReadResult(handled: false)
        var seen = Set(existingURLs.map(canonicalURL))
        for item in pasteboard.pasteboardItems ?? [] {
            guard let (type, suffix) = imageTypes.first(where: { item.types.contains($0.0) }) else { continue }
            result.handled = true
            guard let data = item.data(forType: type) else {
                result.errors.append("无法读取剪贴板中的图片，请重新复制后粘贴。")
                continue
            }
            do {
                let url = try saveImage(data, suffix: suffix, directory: directory)
                if seen.insert(canonicalURL(url)).inserted { result.urls.append(url) }
            } catch { result.errors.append(error.localizedDescription) }
        }
        return result
    }

    static func files(_ urls: [URL], existingURLs: [URL] = []) -> ClipboardAttachmentReadResult {
        var result = ClipboardAttachmentReadResult(handled: !urls.isEmpty)
        var seen = Set(existingURLs.map(canonicalURL))
        for url in urls {
            do {
                let validated = try validateFile(url)
                if seen.insert(validated).inserted { result.urls.append(validated) }
            } catch { result.errors.append(error.localizedDescription) }
        }
        return result
    }

    private static func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    private static func validateFile(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw ClipboardAttachmentError("仅支持粘贴本机文件。") }
        let canonical = canonicalURL(url)
        let values: URLResourceValues
        do { values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) }
        catch { throw ClipboardAttachmentError("无法读取“\(url.lastPathComponent)”，请确认文件仍然存在。") }
        guard values.isDirectory != true else { throw ClipboardAttachmentError("不支持添加文件夹，请选择其中的文件。") }
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: canonical.path) else {
            throw ClipboardAttachmentError("无法读取“\(url.lastPathComponent)”，请检查文件权限。")
        }
        guard (values.fileSize ?? 0) <= maximumFileSize else { throw ClipboardAttachmentError("“\(url.lastPathComponent)”超过 25 MB，请使用更小的附件。") }
        return canonical
    }

    private static func saveImage(_ data: Data, suffix: String, directory: URL) throws -> URL {
        guard data.count <= maximumFileSize else { throw ClipboardAttachmentError("剪贴板图片超过 25 MB，请使用更小的图片。") }
        guard let bitmap = NSBitmapImageRep(data: data) else { throw ClipboardAttachmentError("无法识别剪贴板中的图片，请重新复制后粘贴。") }
        // Screenshots commonly provide TIFF; use PNG so every supported executor can read them.
        let storedData: Data
        let storedSuffix: String
        if suffix == "tiff" || suffix == "heic" {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw ClipboardAttachmentError("无法保存剪贴板图片，请重新复制后粘贴。")
            }
            storedData = png; storedSuffix = "png"
        } else { storedData = data; storedSuffix = suffix }
        guard storedData.count <= maximumFileSize else { throw ClipboardAttachmentError("图片转换后超过 25 MB，请使用更小的图片。") }
        let digest = SHA256.hash(data: storedData).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("粘贴图片-\(digest.prefix(16)).\(storedSuffix)")
        if !FileManager.default.fileExists(atPath: url.path) { try storedData.write(to: url, options: .atomic) }
        return canonicalURL(url)
    }
}

private struct ClipboardAttachmentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Native plain-text editing keeps Return, selection, undo, and input methods intact.
/// Paste intercepts local files and images; regular text remains NSTextView's responsibility.
struct AttachmentTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var attachments: [URL]
    let accessibilityLabel: String
    var isFocused: FocusState<Bool>.Binding? = nil
    var onError: ((String) -> Void)? = nil
    var textContainerInset: NSSize = NSSize(width: 0, height: 4)
    var placeholder: String = ""
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AttachmentEditorView {
        let view = AttachmentEditorView()
        view.editor.textContainerInset = textContainerInset
        view.editor.placeholder = placeholder
        view.editor.placeholderColor = NSColor(KanbanTheme.muted)
        view.editor.delegate = context.coordinator
        view.editor.string = text
        view.editor.setAccessibilityLabel(accessibilityLabel)
        view.editor.onPasteAttachments = { [weak coordinator = context.coordinator, weak view] pasteboard in
            guard let coordinator, let view else { return false }
            let result = ClipboardAttachmentReader.read(from: pasteboard, existingURLs: coordinator.parent.attachments)
            guard result.handled else { return false }
            coordinator.parent.attachments.append(contentsOf: result.urls)
            view.showError(result.errors.isEmpty ? nil : result.errors.joined(separator: "\n"))
            if !result.errors.isEmpty { coordinator.parent.onError?(result.errors.joined(separator: "\n")) }
            return true
        }
        return view
    }

    func updateNSView(_ view: AttachmentEditorView, context: Context) {
        context.coordinator.parent = self
        if view.editor.textContainerInset != textContainerInset {
            view.editor.textContainerInset = textContainerInset
            view.editor.needsDisplay = true
        }
        if view.editor.string != text && !view.editor.hasMarkedText() {
            let selection = view.editor.selectedRange()
            view.editor.string = text
            let location = min(selection.location, (text as NSString).length)
            view.editor.setSelectedRange(NSRange(location: location, length: 0))
            view.editor.needsDisplay = true
        }
        view.editor.isEditable = isEnabled
        view.editor.placeholder = placeholder
        view.editor.placeholderColor = NSColor(KanbanTheme.muted)
        view.editor.textColor = NSColor(KanbanTheme.ink)
        view.editor.insertionPointColor = NSColor(KanbanTheme.blue)
        view.editor.setAccessibilityLabel(accessibilityLabel)
        if isFocused?.wrappedValue == true, let window = view.window, window.firstResponder !== view.editor {
            window.makeFirstResponder(view.editor)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AttachmentTextEditor
        init(_ parent: AttachmentTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
        func textDidBeginEditing(_ notification: Notification) { parent.isFocused?.wrappedValue = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused?.wrappedValue = false }
    }
}

@MainActor
final class AttachmentPasteTextView: NSTextView {
    var placeholder: String = "" {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }
    var placeholderColor: NSColor = .placeholderTextColor {
        didSet { if placeholderColor != oldValue { needsDisplay = true } }
    }
    private let placeholderLayoutManager = NSLayoutManager()
    private let placeholderContainer = NSTextContainer(size: .zero)
    private lazy var placeholderStorage: NSTextStorage = {
        let storage = NSTextStorage()
        storage.addLayoutManager(placeholderLayoutManager)
        placeholderLayoutManager.addTextContainer(placeholderContainer)
        return storage
    }()

    // Marked text is visible before NSTextView publishes a committed binding change.
    // Keep the placeholder out of the document, undo stack, and input-method state.
    var isPlaceholderVisible: Bool { !placeholder.isEmpty && string.isEmpty && !hasMarkedText() }

    private func placeholderGlyphRange() -> NSRange {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: typingAttributes[.font] as? NSFont ?? font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: placeholderColor,
            .paragraphStyle: typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? defaultParagraphStyle ?? NSParagraphStyle.default
        ]
        let content = NSAttributedString(string: placeholder, attributes: attributes)
        if !placeholderStorage.isEqual(to: content) { placeholderStorage.setAttributedString(content) }
        // Match the editor's actual container, including wrapping and line-fragment padding.
        placeholderContainer.size = NSSize(width: textContainer?.size.width ?? bounds.width, height: .greatestFiniteMagnitude)
        placeholderContainer.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        return placeholderLayoutManager.glyphRange(for: placeholderContainer)
    }

    var placeholderFirstGlyphOrigin: NSPoint? {
        guard placeholderGlyphRange().length > 0 else { return nil }
        let line = placeholderLayoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = placeholderLayoutManager.location(forGlyphAt: 0)
        let origin = textContainerOrigin
        return NSPoint(x: origin.x + line.minX + glyph.x, y: origin.y + line.minY + glyph.y)
    }
    var placeholderFirstBaseline: CGFloat? { placeholderFirstGlyphOrigin?.y }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isPlaceholderVisible {
            placeholderLayoutManager.drawGlyphs(forGlyphRange: placeholderGlyphRange(), at: textContainerOrigin)
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    var onPasteAttachments: ((NSPasteboard) -> Bool)?
    // An injected board lets command-routing tests avoid the user's system clipboard.
    var pasteboardProvider: () -> NSPasteboard = { .general }

    // AppKit validates Paste before calling paste(_:). Plain-text defaults exclude image types.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        let native = super.readablePasteboardTypes
        return native + ClipboardAttachmentReader.attachmentTypes.filter { !native.contains($0) }
    }

    private func canPaste() -> Bool {
        isEditable && pasteboardProvider().availableType(from: readablePasteboardTypes) != nil
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) { return canPaste() }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return canPaste() }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if onPasteAttachments?(pasteboardProvider()) == true { return }
        super.paste(sender)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard isEditable else { return false }
        if ClipboardAttachmentReader.attachmentTypes.contains(type), onPasteAttachments?(pasteboard) == true { return true }
        return super.readSelection(from: pasteboard, type: type)
    }
}

@MainActor
final class AttachmentEditorView: NSView {
    let editor = AttachmentPasteTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var errorHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13)
        editor.textColor = NSColor(KanbanTheme.ink)
        editor.insertionPointColor = NSColor(KanbanTheme.blue)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        scrollView.documentView = editor
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = NSColor(KanbanTheme.danger)
        errorLabel.isHidden = true
        addSubview(scrollView); addSubview(errorLabel)
        errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: errorLabel.topAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            errorHeight
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showError(_ error: String?) {
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        errorHeight.isActive = error == nil
        if let error { errorLabel.setAccessibilityLabel(error) }
    }
}

struct AttachmentPreviewList: View {
    let urls: [URL]
    var onRemove: ((URL) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: 8) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            HStack(spacing: 8) {
                                AttachmentThumbnail(url: url).frame(width: 38, height: 38)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(fileSize(url)).font(.system(size: 10)).foregroundStyle(KanbanTheme.muted)
                                }.frame(maxWidth: 190, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help("打开预览 \(url.lastPathComponent)")
                            .accessibilityLabel("打开附件 \(url.lastPathComponent)")
                        if let onRemove {
                            Button { onRemove(url) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                    .frame(width: 22, height: 22).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(KanbanTheme.muted)
                                .help("移除附件").accessibilityLabel("移除附件 \(url.lastPathComponent)")
                        }
                    }.padding(8).background(KanbanTheme.hover, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(KanbanTheme.line, lineWidth: 0.75))
                }
            }
        }.scrollIndicators(.hidden)
    }

    private func fileSize(_ url: URL) -> String {
        let count = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private struct AttachmentThumbnail: View {
    let url: URL
    var body: some View {
        Group {
            if let image = thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(4)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private var thumbnail: NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 96
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
