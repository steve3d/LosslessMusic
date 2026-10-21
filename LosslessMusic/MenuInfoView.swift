import AppKit

@MainActor
final class MenuInfoView: NSView {
    private let heading = NSTextField(labelWithString: String(localized: "Reading output device…"))
    private let format = NSTextField(labelWithString: String(localized: "Waiting for playback…"))
    private var lastPlayback: MusicPlayback?
    private var lastDeviceName: String?
    private var lastMessage: String?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 88))
        heading.frame = NSRect(x: 8, y: 59, width: 164, height: 16)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        format.frame = NSRect(x: 8, y: 14, width: 164, height: 35)
        format.font = .systemFont(ofSize: 28, weight: .medium)
        heading.alignment = .center
        format.alignment = .center
        format.lineBreakMode = .byWordWrapping
        format.maximumNumberOfLines = 2
        for label in [heading, format] { addSubview(label) }
    }

    required init?(coder: NSCoder) { fatalError("MenuInfoView is created programmatically") }

    func update(_ playback: MusicPlayback, deviceName: String?, message: String?) {
        guard lastPlayback != playback || lastDeviceName != deviceName || lastMessage != message else {
            return
        }
        lastPlayback = playback
        lastDeviceName = deviceName
        lastMessage = message
        MusicDiagnostics.log("MENU_RENDER", "state=\(playback.state); device=\(deviceName ?? "unknown"); format=\(MusicDiagnostics.describe(playback.format)); message=\(message ?? "none")")
        heading.stringValue = deviceName ?? String(localized: "Device name unavailable")
        heading.toolTip = heading.stringValue
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        if let value = playback.format {
            let text = NSMutableAttributedString(string: value.rateLabel,
                                                 attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .medium),
                                                              .foregroundColor: NSColor.labelColor])
            text.append(NSAttributedString(string: "  " + String(localized: "\(value.bitDepth)-bit", comment: "Source audio bit depth, such as 24-bit."),
                                           attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                        .foregroundColor: NSColor.secondaryLabelColor]))
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            format.attributedStringValue = text
        } else {
            let placeholder: String = switch playback.state {
            case .unknown: String(localized: "Waiting for playback…")
            case .playing: String(localized: "Waiting for audio format…")
            case .paused: String(localized: "Paused")
            case .stopped: String(localized: "Ready to play")
            }
            format.attributedStringValue = NSAttributedString(
                string: message ?? placeholder,
                attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .medium),
                             .foregroundColor: NSColor.secondaryLabelColor,
                             .paragraphStyle: paragraph])
        }
        format.toolTip = message ?? (playback.state == .paused ? String(localized: "Paused") : nil)
    }
}
