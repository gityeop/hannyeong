import AppKit
import HannyeongCore

@MainActor
final class CorrectionsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row: Equatable {
        case correction(CorrectionExample)
        case entity(String)

        var correction: CorrectionExample? {
            if case .correction(let entry) = self { return entry }
            return nil
        }

        var searchFields: [String] {
            switch self {
            case .correction(let entry): [entry.raw, entry.preferred, entry.rejected, entry.before]
            case .entity(let name): [name, "엔티티"]
            }
        }
    }

    private let store: CorrectionStore
    private let entities: RegisteredEntitySettings
    private let localClient: LocalDecisionClient?
    private let searchSurface = SettingsSearchSurface()
    private var search: NSTextField { searchSurface.field }
    private let count = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let detail = CorrectionDetailsView()
    private let addEntityButton = SettingsActionButton(title: "교정 추가")
    private let deleteButton = SettingsActionButton(title: "선택한 교정 삭제…", destructive: true)
    private var isChanging = false
    private var addingEntity = false
    private var entries: [Row] = []
    private var visible: [Row] = []

    init(store: CorrectionStore? = nil, localClient: LocalDecisionClient? = nil,
         entities: RegisteredEntitySettings = .init()) {
        self.store = store ?? .shared
        self.entities = entities
        self.localClient = localClient
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("CorrectionsViewController does not use a storyboard")
    }

    override func loadView() {
        view = NSView()
        buildContents()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = table.enclosingScrollView!.contentSize.width
        let columnWidth = width / CGFloat(table.tableColumns.count)
        for column in table.tableColumns where abs(column.width - columnWidth) > 0.5 {
            column.width = columnWidth
        }
        if abs(table.frame.width - width) > 0.5 { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
    }

    private func buildContents() {
        let listCard = SettingsCardSurface()
        let detailCard = SettingsCardSurface()
        let title = NSTextField(labelWithString: "저장된 교정")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        search.placeholderString = "입력·결과·문맥 검색"
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("correction-search")
        searchSurface.onClear = { [weak self] in self?.filter() }
        count.font = .systemFont(ofSize: 13)
        count.textColor = .secondaryLabelColor
        count.identifier = NSUserInterfaceItemIdentifier("correction-count")
        let refresh = SettingsActionButton(title: "새로고침")
        refresh.target = self
        refresh.action = #selector(reload)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelection(_:))
        deleteButton.isEnabled = false
        addEntityButton.target = self
        addEntityButton.action = #selector(addEntity)
        detail.onEntitySave = { [weak self] name in self?.saveEntity(name) }
        detail.onEntityCancel = { [weak self] in self?.showSelection() }
        let header = NSStackView(views: [title, count, NSView(), refresh, addEntityButton, deleteButton])
        header.orientation = .horizontal
        header.spacing = 12

        table.identifier = NSUserInterfaceItemIdentifier("correction-table")
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.backgroundColor = .textBackgroundColor
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("raw", "입력 키", 150.0), ("preferred", "선택 결과", 180.0),
                                    ("rejected", "이전 결과", 180.0), ("scope", "기억 방식", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.headerCell.font = .systemFont(ofSize: 13, weight: .medium)
            table.addTableColumn(column)
        }
        table.headerView?.frame.size.height = 30
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.borderType = .noBorder
        list.backgroundColor = .textBackgroundColor
        list.documentView = table
        list.wantsLayer = true
        list.layer?.cornerRadius = 8
        list.layer?.masksToBounds = true

        let hint = NSTextField(wrappingLabelWithString: "⌘클릭: 개별 선택 · ⇧클릭: 범위 선택\n문맥과 함께: 저장 당시 문맥을 기억 · 항상: 같은 입력에 항상 적용")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        for child in [listCard, detailCard, hint] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        for child in [header, searchSurface, list] {
            child.translatesAutoresizingMaskIntoConstraints = false
            listCard.addSubview(child)
        }
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailCard.addSubview(detail)
        NSLayoutConstraint.activate([
            listCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listCard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listCard.topAnchor.constraint(equalTo: view.topAnchor),
            listCard.bottomAnchor.constraint(equalTo: detailCard.topAnchor, constant: -18),
            detailCard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailCard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailCard.heightAnchor.constraint(equalToConstant: 238),
            detailCard.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -18),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.topAnchor.constraint(equalTo: listCard.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -22),
            header.heightAnchor.constraint(equalToConstant: 30),
            searchSurface.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            searchSurface.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 22),
            searchSurface.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -22),
            searchSurface.heightAnchor.constraint(equalToConstant: 32),
            list.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 14),
            list.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 22),
            list.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -22),
            list.bottomAnchor.constraint(equalTo: listCard.bottomAnchor, constant: -18),
            detail.topAnchor.constraint(equalTo: detailCard.topAnchor, constant: 18),
            detail.leadingAnchor.constraint(equalTo: detailCard.leadingAnchor, constant: 22),
            detail.trailingAnchor.constraint(equalTo: detailCard.trailingAnchor, constant: -22),
            detail.bottomAnchor.constraint(equalTo: detailCard.bottomAnchor, constant: -14)
        ])
    }

    @objc func reload() {
        do {
            entries = entities.names.map(Row.entity) + (try store.load().entries.reversed().map(Row.correction))
            filter()
        } catch {
            AppSupport.shared.reportConfigurationError(error)
            entries = []
            visible = []
            table.reloadData()
            deleteButton.isEnabled = false
            count.stringValue = "불러오기 실패"
            count.textColor = .systemRed
            detail.showMessage("저장된 교정을 불러오지 못했습니다. 새로고침해 주세요.")
        }
    }

    func controlTextDidChange(_ notification: Notification) { searchSurface.updateClearButton(); filter() }
    func controlTextDidBeginEditing(_ notification: Notification) { searchSurface.setEditing(true) }
    func controlTextDidEndEditing(_ notification: Notification) { searchSurface.setEditing(false) }

    private func filter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = query.isEmpty ? entries : entries.filter { entry in
            entry.searchFields.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        count.stringValue = query.isEmpty ? "\(entries.count)개" : "\(visible.count) / \(entries.count)개"
        count.textColor = .secondaryLabelColor
        table.reloadData()
        view.needsLayout = true
        if !visible.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        showSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CorrectionTableRowView()
        view.backgroundColor = NSColor.labelColor.withAlphaComponent(row % 2 == 1 ? 0.035 : 0)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visible[row]
        let column = tableColumn?.identifier.rawValue
        if case .entity(let name) = item {
            switch column {
            case "raw": return textCell(name)
            case "scope": return textCell("엔티티", color: .secondaryLabelColor)
            default: return nil
            }
        }
        guard case .correction(let entry) = item else { return nil }
        let value: String
        switch column {
        case "raw": value = entry.raw
        case "preferred": value = entry.preferred
        case "rejected": value = entry.rejected
        case "scope":
            let title = entry.scope == .always ? "항상" : "문맥과 함께"
            let next = entry.scope == .always ? "문맥과 함께" : "항상"
            let button = SettingsActionButton(title: title)
            button.tag = row
            button.target = self
            button.action = #selector(toggleScope(_:))
            button.isEnabled = !isChanging
            button.focusRingType = .none
            button.toolTip = "클릭하면 ‘\(next)’으로 바뀝니다."
            button.setAccessibilityLabel("기억 방식: \(title)")
            button.setAccessibilityValue(title)
            let cell = NSView()
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                button.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])
            return cell
        default: return nil
        }
        return textCell(value)
    }

    private func textCell(_ value: String, color: NSColor = .labelColor) -> NSView {
        let cell = NSView()
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13)
        label.textColor = color
        (label.cell as! NSTextFieldCell).backgroundStyle = .normal
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    private var selectedRows: [Row] {
        table.selectedRowIndexes.filter { visible.indices.contains($0) }.map { visible[$0] }
    }

    private var selectedEntity: String? {
        let rows = selectedRows
        guard rows.count == 1, case .entity(let name) = rows[0] else { return nil }
        return name
    }

    private func showSelection() {
        addingEntity = false
        let rows = selectedRows
        let selected = rows.compactMap(\.correction)
        addEntityButton.isEnabled = !isChanging
        if let name = selectedEntity {
            deleteButton.isEnabled = !isChanging
            deleteButton.title = "선택한 엔티티 삭제…"
            detail.showEntity(name)
            return
        }
        deleteButton.isEnabled = !selected.isEmpty && selected.count == rows.count && !isChanging
        deleteButton.title = selected.count > 1 ? "선택한 \(selected.count)개 삭제…" : "선택한 교정 삭제…"
        if rows.count > 1, rows.count != selected.count {
            detail.showMessage("엔티티 이름을 수정하거나 삭제하려면 하나만 선택해 주세요.", title: "선택한 항목")
            return
        }
        guard let entry = selected.first else {
            let message: String
            if entries.isEmpty { message = "아직 저장된 교정이 없습니다." }
            else if visible.isEmpty { message = "검색 결과가 없습니다." }
            else { message = "목록에서 교정 또는 엔티티를 선택해 주세요." }
            detail.showMessage(message)
            return
        }
        if selected.count > 1 {
            detail.showMessage(selected.map {
                "\($0.raw) → \($0.preferred) · \($0.scope == .always ? "항상" : "문맥과 함께")"
            }.joined(separator: "\n"), title: "\(selected.count)개 교정 선택")
            return
        }
        detail.show(entry)
    }

    @objc private func addEntity() {
        guard !isChanging else { return }
        table.deselectAll(nil)
        addingEntity = true
        deleteButton.isEnabled = false
        detail.showEntity(nil)
        detail.focusEntityName()
    }

    private func saveEntity(_ input: String) {
        let original = selectedEntity
        guard !isChanging, addingEntity || original != nil else { return }
        do {
            let name = try entities.save(input, replacing: original)
            reload()
            if !visible.contains(.entity(name)) {
                search.stringValue = ""
                searchSurface.updateClearButton()
                filter()
            }
            if let row = visible.firstIndex(of: .entity(name)) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
                showSelection()
            }
        } catch {
            detail.showEntityError(error.localizedDescription)
        }
    }

    @objc private func toggleScope(_ sender: NSButton) {
        guard let entry = visible[sender.tag].correction else { return }
        let scope: CorrectionScope = entry.scope == .context ? .always : .context
        table.selectRowIndexes(IndexSet(integer: sender.tag), byExtendingSelection: false)
        isChanging = true
        table.reloadData()
        showSelection()
        Task { @MainActor in
            do {
                let local = try localClient ?? LocalModelService.client()
                let updated = try await store.changeScope(of: entry, to: scope, local: local)
                isChanging = false
                reload()
                if let row = visible.firstIndex(of: .correction(updated)) {
                    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                showSelection()
            } catch {
                AppSupport.shared.reportConfigurationError(error)
                isChanging = false
                table.reloadData()
                showSelection()
                detail.showMessage("기억 방식을 변경하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.")
            }
        }
    }

    @objc private func deleteSelection(_ sender: NSButton) {
        guard let window = view.window else { return }
        if let name = selectedEntity {
            deleteEntity(name, in: window)
            return
        }
        let rows = selectedRows
        let selected = rows.compactMap(\.correction)
        guard !selected.isEmpty, selected.count == rows.count else { return }
        let alert = NSAlert()
        alert.messageText = "선택한 교정 \(selected.count)개를 삭제할까요?"
        let preview = selected.prefix(5).map { "\($0.raw) → \($0.preferred)" }.joined(separator: "\n")
        let remainder = selected.count > 5 ? "\n외 \(selected.count - 5)개" : ""
        alert.informativeText = preview + remainder + "\n선택한 기록과 개인 모델의 해당 보정값을 함께 삭제합니다."
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.isChanging = true
            self.deleteButton.isEnabled = false
            self.table.reloadData()
            Task { @MainActor in
                do {
                    let local = try self.localClient ?? LocalModelService.client()
                    _ = try await local.forget(selected)
                    try self.store.remove(selected)
                    self.isChanging = false
                    self.reload()
                } catch {
                    AppSupport.shared.reportConfigurationError(error)
                    self.isChanging = false
                    self.table.reloadData()
                    self.showSelection()
                    self.detail.showMessage("교정을 삭제하지 못했습니다. 새로고침한 뒤 다시 시도해 주세요.")
                }
            }
        }
    }

    private func deleteEntity(_ name: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "‘\(name)’ 엔티티를 삭제할까요?"
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.entities.remove(name)
                self.reload()
            } catch {
                self.detail.showEntityError(error.localizedDescription)
            }
        }
    }

}
