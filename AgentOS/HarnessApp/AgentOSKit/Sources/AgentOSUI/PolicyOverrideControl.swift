import AgentOSCore
import AppKit
import SwiftUI

/// Previews an allowed override and copies it only on an explicit click; never edits config.
@MainActor
public final class PolicyOverrideControl: NSView {
    private let setting: EffectiveSetting
    private let pasteboard: NSPasteboard
    private let popup = NSPopUpButton()
    private let text = NSTextView()
    private let preview = NSStackView()
    private let error = NSTextField(wrappingLabelWithString: "")
    var didSelect: (() -> Void)?

    public init(setting: EffectiveSetting, pasteboard: NSPasteboard) {
        self.setting = setting
        self.pasteboard = pasteboard
        super.init(frame: .zero)

        popup.addItem(withTitle: setting.overrideActionTitle ?? "Override in repo config…")
        for choice in setting.overrides { popup.addItem(withTitle: choice.value) }
        popup.isEnabled = !setting.overrides.isEmpty
        popup.target = self
        popup.action = #selector(selectOverride)

        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.drawsBackground = false
        text.heightAnchor.constraint(equalToConstant: 65).isActive = true
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyOverride))
        error.textColor = .systemRed
        error.isHidden = true
        preview.orientation = .vertical
        preview.alignment = .leading
        preview.addArrangedSubview(text)
        preview.addArrangedSubview(copy)
        preview.addArrangedSubview(error)
        preview.isHidden = true

        let stack = NSStackView(views: [popup, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            text.widthAnchor.constraint(equalTo: preview.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectOverride() {
        let index = popup.indexOfSelectedItem - 1
        guard setting.overrides.indices.contains(index) else {
            preview.isHidden = true
            return
        }
        text.string = setting.overrides[index].json
        preview.isHidden = false
        error.isHidden = true
        didSelect?()
    }

    @objc private func copyOverride() {
        pasteboard.clearContents()
        if pasteboard.setString(text.string, forType: .string) {
            error.isHidden = true
        } else {
            error.stringValue = "Couldn't copy the fragment. Try Copy again."
            error.isHidden = false
        }
    }
}

struct PolicyOverrideView: NSViewRepresentable {
    let setting: EffectiveSetting
    @Binding var expanded: Bool

    func makeNSView(context: Context) -> PolicyOverrideControl {
        let control = PolicyOverrideControl(setting: setting, pasteboard: .general)
        control.didSelect = { expanded = true }
        return control
    }

    func updateNSView(_ nsView: PolicyOverrideControl, context: Context) {}
}
