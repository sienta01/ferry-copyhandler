import FerryCore
import SwiftUI

struct JobRow: View {
    @ObservedObject var job: Job
    let queue: TransferQueue
    let app: AppController
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.headline)
                        .font(.system(.body, design: .default).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if job.isStarted && !job.isDone && job.snapshot.phase != .scanning {
                        Text("\(Int(job.snapshot.fraction * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                progress
                Text(job.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
                    .lineLimit(2)
                if job.isStarted && !job.isDone && !job.snapshot.currentPath.isEmpty {
                    Text(job.snapshot.currentPath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private var icon: some View {
        let name: String
        let color: Color
        switch job.snapshot.phase {
        case .finished(.completed): name = "checkmark.circle.fill"; color = .green
        case .finished(.completedWithIssues): name = "exclamationmark.triangle.fill"; color = .orange
        case .finished(.failed): name = "xmark.octagon.fill"; color = .red
        case .finished(.cancelled): name = "stop.circle.fill"; color = .secondary
        default: name = job.kind == .copy ? "doc.on.doc.fill" : "arrow.right.doc.on.clipboard"; color = .accentColor
        }
        return Image(systemName: name)
            .font(.system(size: 22))
            .foregroundStyle(color)
            .frame(width: 28)
            .padding(.top, 2)
    }

    @ViewBuilder private var progress: some View {
        switch job.snapshot.phase {
        case .scanning:
            ProgressView().progressViewStyle(.linear)
        case .finished:
            EmptyView()
        default:
            ProgressView(value: job.snapshot.fraction).progressViewStyle(.linear)
        }
    }

    private var statusColor: Color {
        switch job.snapshot.phase {
        case .finished(.completedWithIssues): return .orange
        case .finished(.failed): return .red
        default: return job.pendingPrompt != nil ? .orange : .secondary
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if job.isDone {
                Button { app.reveal(job) } label: { Image(systemName: "magnifyingglass") }
                    .help("Show in Finder")
                if job.snapshot.failedItems > 0 {
                    Button { app.copyProblemReport(job) } label: { Image(systemName: "doc.on.clipboard") }
                        .help("Copy the list of problems")
                }
                Button { queue.remove(job) } label: { Image(systemName: "xmark") }
                    .help("Remove from the list")
            } else if !job.isStarted {
                Button { queue.startNow(job) } label: { Image(systemName: "play.fill") }
                    .help("Start now, alongside the current transfer")
                Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Cancel")
            } else {
                Button { job.isPaused ? job.resume() : job.pause() } label: {
                    Image(systemName: job.isPaused ? "play.fill" : "pause.fill")
                }
                .help(job.isPaused ? "Resume" : "Pause")
                Button { job.skipCurrent() } label: { Image(systemName: "forward.end.fill") }
                    .help("Skip the current file")
                    .disabled(job.snapshot.phase != .running)
                Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Stop")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .padding(.top, 2)
    }
}

/// Shows a job's pending question, if any, as a banner at the top of the window.
struct PromptBanner: View {
    @ObservedObject var job: Job

    var body: some View {
        if let pending = job.pendingPrompt {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                PromptView(job: job, pending: pending)
                    .id(pending.id) // fresh "do this for all" state per question
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
        }
    }
}

/// A question for a running job: conflicts, errors and low disk space.
struct PromptView: View {
    let job: Job
    let pending: PendingPrompt
    @StateObject private var choice = PromptChoice()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch pending.prompt {
            case .collision(let info): collision(info)
            case .error(let path, let message): error(path, message)
            case .lowSpace(let needed, let available): lowSpace(needed, available)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func answer(_ a: PromptAnswer) { pending.answer(PromptResponse(a, applyToAll: choice.applyToAll)) }

    @ViewBuilder private func collision(_ info: CollisionInfo) -> some View {
        let name = (info.destination as NSString).lastPathComponent
        let folder = ((info.destination as NSString).deletingLastPathComponent as NSString).lastPathComponent
        Text("“\(name)” already exists in “\(folder)”.").font(.callout.weight(.semibold))
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            GridRow {
                Text("New:").foregroundStyle(.secondary)
                Text(describe(info.sourceSize, info.sourceDate, dir: info.sourceIsDirectory, newer: info.sourceDate > info.destinationDate))
            }
            GridRow {
                Text("Existing:").foregroundStyle(.secondary)
                Text(describe(info.destinationSize, info.destinationDate, dir: info.destinationIsDirectory, newer: info.destinationDate > info.sourceDate))
            }
        }
        .font(.caption)
        .monospacedDigit()
        HStack {
            Button("Keep Both") { answer(.keepBoth) }
            Button("Skip") { answer(.skip) }
            Button("Replace") { answer(.replace) }
            Button("Replace if Newer") { answer(.replaceIfNewer) }
            Spacer()
            Toggle("Do this for all", isOn: $choice.applyToAll).toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }

    private func describe(_ size: Int64, _ date: Date, dir: Bool, newer: Bool) -> String {
        (dir ? "Folder" : Fmt.bytes(size)) + ", modified " + date.formatted(date: .abbreviated, time: .shortened)
            + (newer ? " (newer)" : "")
    }

    @ViewBuilder private func error(_ path: String, _ message: String) -> some View {
        Text("Couldn't \(job.kind == .copy ? "copy" : "move") “\((path as NSString).lastPathComponent)”")
            .font(.callout.weight(.semibold))
        Text(message).font(.caption)
        HStack {
            Button("Try Again") { answer(.retry) }
            Button("Skip") { answer(.skip) }
            Button("Stop") { answer(.cancel) }
            Spacer()
            Toggle("Skip all errors", isOn: $choice.applyToAll).toggleStyle(.checkbox)
        }
        .controlSize(.small)
    }

    @ViewBuilder private func lowSpace(_ needed: Int64, _ available: Int64) -> some View {
        Text("Not enough free space on “\(job.destinationName)”").font(.callout.weight(.semibold))
        Text("This needs \(Fmt.bytes(needed)) but only \(Fmt.bytes(available)) is free.").font(.caption)
        HStack {
            Button("\(job.kind.verb) Anyway") { answer(.proceed) }
            Button("Cancel") { answer(.cancel) }
        }
        .controlSize(.small)
    }
}

final class PromptChoice: ObservableObject {
    @Published var applyToAll = false
}
