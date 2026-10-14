import AppKit
import StoneVPNCore

/// Щит у menubar: форма = стан, колір = тон, число = скільки тунелів підключено.
/// Монохромний режим — template-зображення (система сама фарбує під тему).
enum MenuIcon {
    static func image(tone: IconTone, count: Int, colored: Bool, showCount: Bool, label: String?) -> NSImage {
        let color: NSColor = switch tone {
        case .idle: .labelColor
        case .ok: .systemGreen
        case .busy: .systemOrange
        case .problem: .systemRed
        case .foreign: .systemPurple
        }
        let filled = tone != .idle
        let text = [showCount && count > 0 ? "\(count)" : nil, label].compactMap { $0 }.joined(separator: " ")
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colored ? color : NSColor.black]
        let textW = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: attrs).width) + 3
        let size = NSSize(width: 18 + textW, height: 18)

        let img = NSImage(size: size, flipped: true) { _ in
            let ink: NSColor = colored ? color : .black
            let s = 18.0 / 24.0
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 12 * s, y: 2.5 * s))
            p.line(to: NSPoint(x: 19.5 * s, y: 5.5 * s))
            p.line(to: NSPoint(x: 19.5 * s, y: 11.7 * s))
            p.curve(to: NSPoint(x: 12 * s, y: 21.5 * s), controlPoint1: NSPoint(x: 19.5 * s, y: 16.4 * s), controlPoint2: NSPoint(x: 16.3 * s, y: 19.7 * s))
            p.curve(to: NSPoint(x: 4.5 * s, y: 11.7 * s), controlPoint1: NSPoint(x: 7.7 * s, y: 19.7 * s), controlPoint2: NSPoint(x: 4.5 * s, y: 16.4 * s))
            p.line(to: NSPoint(x: 4.5 * s, y: 5.5 * s))
            p.close()
            p.lineWidth = 1.6
            p.lineJoinStyle = .round
            ink.setStroke()
            if filled {
                ink.setFill()
                p.fill()
            }
            p.stroke()

            // Вирізаний знак усередині: «!» = проблема, крапка = сторонній VPN.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.set()
            if tone == .problem {
                let bar = NSBezierPath(roundedRect: NSRect(x: 11 * s, y: 7.5 * s, width: 2 * s, height: 6 * s), xRadius: 1 * s, yRadius: 1 * s)
                bar.fill()
                NSBezierPath(ovalIn: NSRect(x: 10.9 * s, y: 15.2 * s, width: 2.2 * s, height: 2.2 * s)).fill()
            } else if tone == .foreign {
                NSBezierPath(ovalIn: NSRect(x: 9.6 * s, y: 9.1 * s, width: 4.8 * s, height: 4.8 * s)).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            if !text.isEmpty {
                (text as NSString).draw(at: NSPoint(x: 19, y: 1.5), withAttributes: attrs)
            }
            return true
        }
        img.isTemplate = !colored
        return img
    }
}
