import AppKit
import SwiftUI
import Vision

/// Renders views to images and reads their text, for UI tests and UI evidence. Windows stay hidden and the screen
/// is never captured. Images are drawn onto opaque white: views draw on a transparent background, and text
/// recognition reads nothing from black text on transparent pixels.
@MainActor
public enum RenderedUI {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// `view` in light mode at `size`.
    public static func image<Content: View>(of view: Content, size: CGSize) throws -> CGImage {
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light))
        hosting.frame = CGRect(origin: .zero, size: size)
        return try image(of: hosting)
    }

    /// An AppKit view as it is now, e.g. an `NSHostingView` a test keeps to capture again after a change.
    public static func image(of view: NSView) throws -> CGImage {
        _ = NSApplication.shared
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            throw Failure(description: "The view has no size to render: \(view.bounds.size)")
        }
        var window: NSWindow?
        if view.window == nil {
            let hidden = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            hidden.isReleasedWhenClosed = false
            hidden.appearance = NSAppearance(named: .aqua)
            hidden.contentView = view
            window = hidden
        }
        defer {
            window?.contentView = nil
            window?.close()
        }
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure(description: "No bitmap for a view of size \(view.bounds.size)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let drawn = bitmap.cgImage else { throw Failure(description: "The view drew no image") }
        return try onWhite(drawn)
    }

    /// The text recognised in `image`, one entry per line, top to bottom.
    public static func text(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// The text `view` shows at `size`, one line per recognised line.
    public static func text<Content: View>(of view: Content, size: CGSize) throws -> String {
        try text(in: image(of: view, size: size)).joined(separator: "\n")
    }

    /// Whether recognised `text` shows `expected`. Ignores case and whitespace: recognition sometimes drops or
    /// adds a space, for example reading a picker value "All kinds" as "Allkinds".
    public static func shows(_ expected: String, in text: String) -> Bool {
        func squeezed(_ string: String) -> String { string.filter { !$0.isWhitespace }.lowercased() }
        return squeezed(text).contains(squeezed(expected))
    }

    /// PNG data to write as UI evidence or a snapshot.
    public static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "Couldn't encode the image as PNG")
        }
        return data
    }

    private static func onWhite(_ image: CGImage) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "No drawing context for \(image.width)×\(image.height)")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let opaque = context.makeImage() else { throw Failure(description: "Couldn't draw onto white") }
        return opaque
    }
}
