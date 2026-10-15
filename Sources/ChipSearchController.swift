import Cocoa

/// Sheet that searches minipro's chip database (`minipro -L <text>`) and returns the chosen name.
final class ChipSearchController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var results: [String] = []
    private var parent: NSWindow?
    private let onDone: (String?) -> Void
    private var searchToken = 0
    private var keepAlive: ChipSearchController?

    init(initialQuery: String, onDone: @escaping (String?) -> Void) {
        self.onDone = onDone
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init()
        build()
        // Search on the base part number, without the @package suffix.
        field.stringValue = initialQuery.components(separatedBy: "@").first ?? ""
    }

    private func build() {
        guard let content = panel.contentView else { return }
        field.placeholderString = "Part number, e.g. 27C256"
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(search(_:))

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Chip (minipro name)"
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose(_:))
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let help = NSTextField(wrappingLabelWithString: "Pick the exact package too (e.g. @DIP28). Double-click to choose.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Choose", target: self, action: #selector(choose(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [countLabel, NSView(), cancel, ok])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [field, help, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for v in [field, help, scroll, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    func present(on window: NSWindow) {
        parent = window
        keepAlive = self
        window.beginSheet(panel, completionHandler: nil)
        _ = panel.makeFirstResponder(field)
        if !field.stringValue.isEmpty { search(nil) }
    }

    @objc private func search(_ sender: Any?) {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { results = []; table.reloadData(); countLabel.stringValue = "Type at least 2 characters"; return }
        searchToken += 1
        let token = searchToken
        countLabel.stringValue = "Searching…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Minipro.shared.runSync(["-q", Minipro.shared.programmerType, "-L", query])
            let names = r.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasSuffix(":") }
            DispatchQueue.main.async {
                guard token == self.searchToken else { return }
                self.results = names
                self.table.reloadData()
                self.countLabel.stringValue = names.isEmpty ? "No matches" : "\(names.count) matches"
                if !names.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            }
        }
    }

    @objc private func choose(_ sender: Any?) {
        let row = table.selectedRow
        finish(row >= 0 && row < results.count ? results[row] : nil)
    }

    @objc private func cancel(_ sender: Any?) { finish(nil) }

    private func finish(_ name: String?) {
        parent?.endSheet(panel)
        panel.orderOut(nil)
        onDone(name)
        keepAlive = nil
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.font = NSFont.userFixedPitchFont(ofSize: 12)
            return t
        }()
        cell.stringValue = results[row]
        return cell
    }
}
