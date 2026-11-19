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

    /// A recognised line of text.
    public struct Line: Sendable {
        public let text: String
        /// Normalised to the whole image, with the origin at the bottom left, like Vision's boxes.
        public let box: CGRect

        /// Whether `other` covers most of this line or this line most of `other`: the same text read twice.
        func overlaps(_ other: Line) -> Bool {
            let shared = box.intersection(other.box)
            guard !shared.isNull else { return false }
            let smaller = min(box.width * box.height, other.box.width * other.box.height)
            return shared.width * shared.height > 0.5 * smaller
        }
    }

    /// The text recognised in `image`, one entry per line, in the order of `lines(in:)`.
    public static func text(in image: CGImage) throws -> [String] {
        try lines(in: image).map(\.text)
    }

    /// The lines recognised in `image`, top to bottom, then any lines only a second reading found.
    /// Since macOS 27.2 accurate recognition skips text unpredictably: most small text in a large, mostly empty
    /// image (for example every value in a detail grid), and now and then a short word. So this reads the part of
    /// `image` that isn't blank, which finds nearly everything, and then the whole image for words the first
    /// reading skipped.
    public static func lines(in image: CGImage) throws -> [Line] {
        let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let content = inkRect(of: image, margin: 16), content != whole else { return try read(image, area: whole) }
        var lines = try read(image, area: content)
        for line in try read(image, area: whole) where !lines.contains(where: { $0.overlaps(line) }) {
            lines.append(line)
        }
        return lines
    }

    private static func read(_ image: CGImage, area: CGRect) throws -> [Line] {
        guard let cropped = image.cropping(to: area) else { throw Failure(description: "Couldn't crop to \(area)") }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cropped).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox
            return Line(text: text, box: CGRect(
                x: (area.minX + box.minX * area.width) / width,
                y: (height - area.maxY + box.minY * area.height) / height,
                width: box.width * area.width / width,
                height: box.height * area.height / height))
        }
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

    /// The part of `image` that isn't (nearly) white, plus `margin`, in pixels from the top left; nil when blank.
    /// Also finds marks text recognition skips, such as a lone "–": since macOS 27.2 it no longer reads one.
    public static func inkRect(of image: CGImage, margin: Int = 0) -> CGRect? {
        let width = image.width, height = image.height
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: whole)
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width {
                let i = row + x * 4
                if pixels[i] < 245 || pixels[i + 1] < 245 || pixels[i + 2] < 245 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + 1 + 2 * margin,
                      height: maxY - minY + 1 + 2 * margin).intersection(whole)
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
