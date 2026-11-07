import AppKit
import HannyeongCore

final class CorrectionTableRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    private var selectionBounds: NSRect {
        NSRect(x: bounds.minX, y: bounds.minY, width: visibleRect.width, height: bounds.height)
    }
    override func drawBackground(in dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath(roundedRect: selectionBounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: selectionBounds.insetBy(dx: 6.5, dy: 1.5), xRadius: 6, yRadius: 6)
        SettingsAppearance.accentNSColor.withAlphaComponent(0.1).setFill()
        shape.fill()
        SettingsAppearance.accentNSColor.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

final class CorrectionDetailsView: NSView {
    private let title = NSTextField(labelWithString: "선택한 교정")
    private let form = NSStackView()
    private let message = NSTextView()
    private let messageScroll = NSScrollView()
    private let entityForm = NSStackView()
    private let entityName = NSTextField(string: "")
    private let entityError = NSTextField(wrappingLabelWithString: "")
    var onEntitySave: ((String) -> Void)?
    var onEntityCancel: (() -> Void)?
    private var values: [NSTextField] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 0
        form.translatesAutoresizingMaskIntoConstraints = false
        addSubview(form)
        for name in ["입력 키", "선택 결과", "이전 결과", "기억 방식", "저장된 앞 문맥"] {
            let divider = NSBox()
            divider.boxType = .separator
            form.addArrangedSubview(divider)
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            let value = NSTextField(labelWithString: "")
            value.font = .systemFont(ofSize: 13)
            value.alignment = .right
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, NSView(), value])
            row.spacing = 12
            row.heightAnchor.constraint(equalToConstant: 32).isActive = true
            form.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
            divider.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
            values.append(value)
        }
        message.identifier = NSUserInterfaceItemIdentifier("correction-detail")
        message.isEditable = false
        message.isRichText = false
        message.drawsBackground = false
        message.font = .systemFont(ofSize: 13)
        message.textContainerInset = NSSize(width: 0, height: 6)
        message.autoresizingMask = [.width]
        message.textContainer?.widthTracksTextView = true
        messageScroll.documentView = message
        messageScroll.hasVerticalScroller = true
        messageScroll.drawsBackground = false
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageScroll)
        buildEntityForm()
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            form.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            form.leadingAnchor.constraint(equalTo: leadingAnchor),
            form.trailingAnchor.constraint(equalTo: trailingAnchor),
            form.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            messageScroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            messageScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageScroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("CorrectionDetailsView does not use a storyboard") }

    private func buildEntityForm() {
        entityName.placeholderString = "예: codex"
        entityName.setAccessibilityLabel("엔티티 이름")
        entityName.target = self
        entityName.action = #selector(saveEntity)
        let save = SettingsActionButton(title: "저장")
        save.target = self
        save.action = #selector(saveEntity)
        let cancel = SettingsActionButton(title: "취소")
        cancel.target = self
        cancel.action = #selector(cancelEntity)

        let controls = NSStackView(views: [entityName, save, cancel])
        controls.spacing = 8
        entityName.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let hint = NSTextField(wrappingLabelWithString: "예를 들어 codex를 저장하면 codex가, codex에서처럼 입력할 때 이름을 유지합니다.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        entityError.font = .systemFont(ofSize: 12)
        entityError.textColor = .systemRed
        entityForm.orientation = .vertical
        entityForm.alignment = .leading
        entityForm.spacing = 10
        for item in [controls, hint, entityError] {
            entityForm.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: entityForm.widthAnchor).isActive = true
        }
        entityForm.isHidden = true
        entityForm.translatesAutoresizingMaskIntoConstraints = false
        addSubview(entityForm)
        NSLayoutConstraint.activate([
            entityForm.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            entityForm.leadingAnchor.constraint(equalTo: leadingAnchor),
            entityForm.trailingAnchor.constraint(equalTo: trailingAnchor),
            entityForm.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    func showEntity(_ name: String?) {
        form.isHidden = true
        messageScroll.isHidden = true
        entityForm.isHidden = false
        title.stringValue = name == nil ? "엔티티 추가" : "엔티티 이름 수정"
        entityName.stringValue = name ?? ""
        entityError.isHidden = true
    }

    func focusEntityName() {
        window?.makeFirstResponder(entityName)
    }

    func showEntityError(_ message: String) {
        entityError.stringValue = message
        entityError.isHidden = false
    }

    @objc private func saveEntity() { onEntitySave?(entityName.stringValue) }

    @objc private func cancelEntity() { onEntityCancel?() }

    func show(_ entry: CorrectionExample) {
        entityForm.isHidden = true
        form.isHidden = false
        messageScroll.isHidden = true
        title.stringValue = "선택한 교정"
        let content = [entry.raw, entry.preferred, entry.rejected,
                       entry.scope == .always ? "항상" : "문맥과 함께",
                       entry.before.isEmpty ? "없음" : entry.before]
        for (field, text) in zip(values, content) {
            field.stringValue = text
            field.toolTip = text
        }
    }

    func showMessage(_ text: String, title: String = "선택한 교정") {
        self.title.stringValue = title
        entityForm.isHidden = true
        form.isHidden = true
        messageScroll.isHidden = false
        message.string = text
        message.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
