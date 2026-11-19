import AppKit
import FerryCore
import SwiftUI

/// File list of the selected job. Backed by NSTableView, which asks only for visible rows,
/// so a job with a million files costs no more to display than one with ten.
struct FilePane: View {
    let job: Job?
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Text("Files").font(.callout.weight(.medium))
                    if let job {
                        FileCountLabel(job: job)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            if expanded {
                Divider()
                FileTable(job: job)
                    .frame(minHeight: 150, maxHeight: .infinity)
            }
        }
    }
}

private struct FileCountLabel: View {
    @ObservedObject var job: Job

    var body: some View {
        let s = job.snapshot
        let problems = s.failedItems > 0 ? " — \(plural(s.failedItems, "problem"))" : ""
        Text("\(Fmt.count(s.finishedItems)) of \(plural(s.totalItems, "item")) done" + problems)
            .font(.caption)
            .foregroundStyle(s.failedItems > 0 ? Color.orange : Color.secondary)
            .monospacedDigit()
    }
}

struct FileTable: NSViewRepresentable {
    let job: Job?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        // Widths are managed by Coordinator.fitColumns(): Size and Status keep their width and
        // Name / Source / Destination share the rest, so every column stays in view.
        table.columnAutoresizingStyle = .noColumnAutoresizing

        func column(_ id: String, _ title: String, width: CGFloat, min: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = min
            c.resizingMask = [.autoresizingMask, .userResizingMask]
            return c
        }
        table.addTableColumn(column("name", "Name", width: 220, min: 100))
        let size = column("size", "Size", width: 70, min: 56)
        size.headerCell.alignment = .right
        table.addTableColumn(size)
        table.addTableColumn(column("note", "Status", width: 120, min: 70))
        table.addTableColumn(column("source", "Source", width: 230, min: 90))
        table.addTableColumn(column("destination", "Destination", width: 230, min: 90))

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true // only shows if you widen columns past the window
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.watchScrolling(of: scroll)
        context.coordinator.setJob(job)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.setJob(job)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private weak var job: Job?
        private var rowCount = 0
        private var timer: Timer?
        /// Keep the file in flight in view. Turns off when you scroll away by hand and back on
        /// when you scroll the active file into view again (or pick another transfer).
        private var following = true
        private var activeRow = -1
        private var scrollingByCode = false
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private static let flexibleColumns: Set<String> = ["name", "source", "destination"]

        deinit {
            [boundsObserver, frameObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver)
        }

        func setJob(_ newJob: Job?) {
            guard newJob !== job || timer == nil && newJob?.isDone == false else { return }
            let switched = newJob !== job
            job = newJob
            rowCount = newJob?.itemCount ?? 0
            table?.reloadData()
            if switched {
                following = true
                activeRow = -1
            }
            timer?.invalidate()
            timer = nil
            guard let newJob, !newJob.isDone else { return }
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// Any scroll we didn't make ourselves (wheel, trackpad, scroller, keyboard) is the user's.
        func watchScrolling(of scrollView: NSScrollView) {
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                guard let self, !self.scrollingByCode else { return }
                self.following = self.activeRow >= 0 && self.isVisible(self.activeRow)
            }
            clip.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.fitColumns() }
        }

        /// Stretches or shrinks the Name, Source and Destination columns (keeping their
        /// proportions) so the whole table fits the visible width.
        private func fitColumns() {
            guard let table, let clip = table.enclosingScrollView?.contentView, clip.bounds.width > 0 else { return }
            let columns = table.tableColumns
            let flexible = columns.filter { Self.flexibleColumns.contains($0.identifier.rawValue) }
            let fixed = columns.filter { !Self.flexibleColumns.contains($0.identifier.rawValue) }
                .reduce(CGFloat(0)) { $0 + $1.width }
            let spacing = table.intercellSpacing.width * CGFloat(columns.count)
            let current = flexible.reduce(CGFloat(0)) { $0 + $1.width }
            let target = max(flexible.reduce(CGFloat(0)) { $0 + $1.minWidth }, clip.bounds.width - fixed - spacing)
            guard current > 0, abs(target - current) >= 1 else { return }
            let scale = target / current
            for column in flexible { column.width = max(column.minWidth, (column.width * scale).rounded(.down)) }
        }

        private func tick() {
            guard let table, let job else { stop(); return }
            let count = job.itemCount
            if count != rowCount {
                rowCount = count
                table.noteNumberOfRowsChanged()
            }
            activeRow = job.currentStats().currentIndex
            if following && activeRow >= 0 && activeRow < rowCount { keepInView(activeRow) }
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                 columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }
            if job.isDone { stop() } // one last refresh, then idle
        }

        private func isVisible(_ row: Int) -> Bool {
            guard let table else { return false }
            return NSLocationInRange(row, table.rows(in: table.visibleRect))
        }

        /// Scrolls only when the active row leaves the upper part of the list, then places it so
        /// the next few files are visible below it.
        private func keepInView(_ row: Int) {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            let first = visible.location
            let last = visible.location + visible.length - 1
            let lookahead = max(2, visible.length / 2)
            guard row <= first || row > last - lookahead / 2 else { return }
            scrollingByCode = true
            table.scrollRowToVisible(min(rowCount - 1, row + lookahead))
            table.scrollRowToVisible(row)
            scrollingByCode = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let item = job?.row(row) else { return nil }
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? Cell) ?? Cell(id: id, withImage: id.rawValue == "name")
            switch id.rawValue {
            case "name":
                cell.toolTip = nil
                cell.text.stringValue = item.path
                cell.text.textColor = item.status == .pending ? .secondaryLabelColor : .labelColor
                cell.icon?.image = Cell.statusImage(item)
                cell.icon?.contentTintColor = Cell.statusColor(item.status)
            case "size":
                cell.text.stringValue = item.kind == .directory ? "—" : Fmt.bytes(item.size)
                cell.text.alignment = .right
                cell.text.textColor = .secondaryLabelColor
            case "source", "destination":
                let path = id.rawValue == "source" ? item.source : item.destination
                cell.text.stringValue = (path as NSString).abbreviatingWithTildeInPath
                cell.text.textColor = .secondaryLabelColor
                cell.toolTip = path
            default:
                cell.text.stringValue = item.message ?? Cell.statusWord(item.status)
                cell.text.textColor = item.status == .failed ? .systemOrange : .secondaryLabelColor
                cell.toolTip = item.message
            }
            return cell
        }
    }

    final class Cell: NSTableCellView {
        let text = NSTextField(labelWithString: "")
        let icon: NSImageView?

        init(id: NSUserInterfaceItemIdentifier, withImage: Bool) {
            icon = withImage ? NSImageView() : nil
            super.init(frame: .zero)
            identifier = id
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
            text.translatesAutoresizingMaskIntoConstraints = false
            addSubview(text)
            textField = text
            if let icon {
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
                addSubview(icon)
                imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        private static var imageCache: [String: NSImage] = [:]

        static func statusImage(_ row: Job.Row) -> NSImage? {
            let name: String
            switch row.status {
            case .done: name = "checkmark.circle.fill"
            case .failed: name = "exclamationmark.triangle.fill"
            case .skipped: name = "minus.circle"
            case .active: name = "arrow.right.circle.fill"
            case .pending: name = row.kind == .directory ? "folder" : "circle"
            }
            if let cached = imageCache[name] { return cached }
            let image = NSImage(systemSymbolName: name, accessibilityDescription: statusWord(row.status))
            imageCache[name] = image
            return image
        }

        static func statusColor(_ status: ItemStatus) -> NSColor {
            switch status {
            case .done: return .systemGreen
            case .failed: return .systemOrange
            case .active: return .controlAccentColor
            case .skipped, .pending: return .tertiaryLabelColor
            }
        }

        static func statusWord(_ status: ItemStatus) -> String {
            switch status {
            case .pending: return "Waiting"
            case .active: return "In progress…"
            case .done: return "Done"
            case .skipped: return "Skipped"
            case .failed: return "Failed"
            }
        }
    }
}
