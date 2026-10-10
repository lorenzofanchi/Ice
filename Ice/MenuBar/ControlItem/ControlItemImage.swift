//
//  ControlItemImage.swift
//  Ice
//

import Cocoa

/// A Codable image for a control item.
enum ControlItemImage: Codable, Hashable {
    /// An image created from drawing code built into the app.
    case builtin(_ name: ImageBuiltinName)
    /// A system symbol image.
    case symbol(_ name: String)
    /// An image in an asset catalog.
    case catalog(_ name: String)
    /// An image stored as data.
    case data(_ data: Data)

    /// A Cocoa representation of this image.
    @MainActor
    func nsImage(for appState: AppState) -> NSImage? {
        switch self {
        case .builtin(let name):
            return switch name {
            case .chevronLarge: StaticBuiltins.Chevron.large
            case .chevronSmall: StaticBuiltins.Chevron.small
            case .doubleChevronLarge: StaticBuiltins.Chevron.doubleLarge
            case .doubleChevronSmall: StaticBuiltins.Chevron.doubleSmall
            case .lineLarge: StaticBuiltins.Line.large
            case .lineSmall: StaticBuiltins.Line.small
            case .dotLarge: StaticBuiltins.Dot.large
            case .dotSmall: StaticBuiltins.Dot.small
            }
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        case .catalog(let name):
            guard let originalImage = NSImage(named: name) else {
                return nil
            }
            let originalWidth = originalImage.size.width
            let originalHeight = originalImage.size.height
            let ratio = max(originalWidth / 25, originalHeight / 17)
            let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
            return originalImage.resized(to: newSize)
        case .data(let data):
            let image = NSImage(data: data)
            image?.isTemplate = appState.settings.general.customIceIconIsTemplate
            return image
        }
    }
}

extension ControlItemImage {
    /// A name for an image that is created from drawing code in the app.
    enum ImageBuiltinName: Codable, Hashable {
        /// A large chevron.
        case chevronLarge
        /// A small chevron.
        case chevronSmall
        /// A large double chevron.
        case doubleChevronLarge
        /// A small double chevron.
        case doubleChevronSmall
        /// A large vertical line.
        case lineLarge
        /// A small vertical line.
        case lineSmall
        /// A large dot.
        case dotLarge
        /// A small dot.
        case dotSmall
    }
}

extension ControlItemImage {
    /// A namespace for static builtin images.
    ///
    /// - Note: We use the static properties `large` and `small` to avoid repeatedly
    ///   executing code every time ``nsImage(for:)`` is called.
    private enum StaticBuiltins {
        /// A namespace for static builtin chevron images.
        enum Chevron {
            /// Creates an image of the given number of chevrons, each with
            /// the given size and line width.
            private static func chevron(size: CGSize, lineWidth: CGFloat, count: Int = 1) -> NSImage {
                let spacing = size.width / 2
                let imageSize = CGSize(width: size.width + spacing * CGFloat(count - 1), height: size.height)
                let image = NSImage(size: imageSize, flipped: false) { _ in
                    for index in 0..<count {
                        let bounds = CGRect(origin: CGPoint(x: spacing * CGFloat(index), y: 0), size: size)
                        let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                        let path = NSBezierPath()
                        path.move(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.maxY))
                        path.line(to: CGPoint(x: (insetBounds.minX + insetBounds.midX) / 2, y: insetBounds.midY))
                        path.line(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.minY))
                        path.lineWidth = lineWidth
                        path.lineCapStyle = .butt
                        NSColor.black.setStroke()
                        path.stroke()
                    }
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A large chevron.
            static let large = chevron(size: CGSize(width: 12, height: 12), lineWidth: 2)

            /// A small chevron.
            static let small = chevron(size: CGSize(width: 9, height: 9), lineWidth: 2)

            /// A large double chevron.
            static let doubleLarge = chevron(size: CGSize(width: 12, height: 12), lineWidth: 2, count: 2)

            /// A small double chevron.
            static let doubleSmall = chevron(size: CGSize(width: 9, height: 9), lineWidth: 2, count: 2)
        }

        /// A namespace for static builtin line images.
        enum Line {
            /// Creates a vertical line image with the given height.
            private static func line(height: CGFloat) -> NSImage {
                let image = NSImage(size: CGSize(width: 2, height: height), flipped: false) { bounds in
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A large vertical line.
            static let large = line(height: 14)

            /// A small vertical line.
            static let small = line(height: 10)
        }

        /// A namespace for static builtin dot images.
        enum Dot {
            /// Creates a dot image with the given diameter.
            private static func dot(diameter: CGFloat) -> NSImage {
                let image = NSImage(size: CGSize(width: diameter, height: diameter), flipped: false) { bounds in
                    NSColor.black.setFill()
                    NSBezierPath(ovalIn: bounds).fill()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A large dot.
            static let large = dot(diameter: 6)

            /// A small dot.
            static let small = dot(diameter: 4)
        }
    }
}
