import Combine
import SwiftUI
import VesaliusCore

/// Hands a Vesalius finding to Claude Code or Codex: review the prompt, run, watch, see the result.
struct AgentSheet: View {
    let workspace: Workspace
    let request: AgentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var agent: AgentKind = .claude
    @State private var mode: AgentSession.Mode = .edit
    @State private var prompt = ""
    @State private var session: AgentSession?
    private let availability = AgentAvailability.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                AgentConsole(workspace: workspace, session: session) { dismiss() }
            } else {
                compose
            }
        }
        .frame(width: 720, height: 600)
        .onAppear {
            prompt = request.prompt
            mode = request.suggestedMode
            if !availability.isInstalled(.claude), availability.isInstalled(.codex) { agent = .codex }
        }
        .accessibilityIdentifier("agent-sheet")
    }

    private var compose: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Improve with an agent").font(Theme.Font.title)
                Text(request.title).font(Theme.Font.body).foregroundStyle(Theme.Colors.text2).lineLimit(2)
            }
            HStack(spacing: Theme.Space.l) {
                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Picker("Mode", selection: $mode) {
                    ForEach(AgentSession.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            Text(mode.detail).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)

            if availability.resolved && !availability.isInstalled(agent) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Label("\(agent.displayName) is not installed or not on your shell's PATH.", systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Colors.warning)
                    CopyableCode(text: agent.installHint)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Prompt").font(Theme.Font.label).foregroundStyle(Theme.Colors.text3).textCase(.uppercase)
                TextEditor(text: $prompt)
                    .font(Theme.Font.mono)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.s)
                    .background(Theme.Colors.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityIdentifier("agent-prompt")
                Text("Written from Vesalius's evidence. Edit it freely. The agent runs on this Mac in \(workspace.root.lastPathComponent) with the Vesalius index attached as an MCP server.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Colors.text3)
            }

            HStack {
                Button("Open in Terminal") {
                    AgentSession.openInTerminal(agent: agent, root: workspace.root, prompt: prompt)
                    dismiss()
                }
                .disabled(availability.resolved && !availability.isInstalled(agent))
                .help("Start an interactive \(agent.displayName) session in Terminal with this prompt")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run \(agent.displayName)") { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (availability.resolved && !availability.isInstalled(agent)))
                    .accessibilityIdentifier("agent-run")
            }
        }
        .padding(Theme.Space.xl)
    }

    private func run() {
        let session = AgentSession(agent: agent, root: workspace.root, mode: mode, prompt: prompt)
        session.healthBefore = workspace.overview?.health.score
        self.session = session
        let workspace = self.workspace
        session.start {
            workspace.reindex(initial: false)
        }
    }
}

/// Live transcript of an agent run.
struct AgentConsole: View {
    let workspace: Workspace
    let session: AgentSession
    let close: () -> Void
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(session.events) { event in
                            EventRow(event: event).id(event.id)
                        }
                    }
                    .padding(Theme.Space.l)
                }
                .onChange(of: session.events.count) {
                    if let last = session.events.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .accessibilityIdentifier("agent-transcript")
            if !session.isRunning {
                Divider()
                summary
            }
        }
        .onReceive(timer) { now = $0 }
        .onChange(of: workspace.generation) {
            if !session.isRunning { session.healthAfter = workspace.overview?.health.score }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.agent.displayName).font(Theme.Font.section)
                Text(statusText).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).monospacedDigit()
            }
            Spacer()
            if session.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { session.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("agent-done")
            }
        }
        .padding(Theme.Space.l)
    }

    private var statusText: String {
        let elapsed = Int((session.finishedAt ?? now).timeIntervalSince(session.startedAt ?? now))
        let time = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        switch session.status {
        case .idle: return "Preparing"
        case .running: return "\(session.mode == .plan ? "Planning" : "Working") · \(time)"
        case .finished: return "Finished in \(time)"
        case .stopped: return "Stopped after \(time)"
        case .failed(let message): return message
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.xl) {
                MetricView(label: "Files changed", value: session.changedFiles.count.grouped)
                if let before = session.healthBefore {
                    MetricView(label: "Health", value: session.healthAfter.map { "\(before) → \($0)" } ?? "\(before) → …", detail: session.healthAfter == nil ? "re-analysing" : nil)
                }
            }
            if !session.changedFiles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(session.changedFiles, id: \.self) { path in
                            Button {
                                workspace.open(path: path)
                            } label: {
                                Tag(text: path, systemImage: "doc")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.l)
    }
}

private struct EventRow: View {
    let event: AgentSession.Event

    var body: some View {
        switch event.kind {
        case .message:
            Text(event.text).font(Theme.Font.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: icon).foregroundStyle(Theme.Colors.text3).frame(width: 14)
                Text(event.text).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2)
                if let detail = event.detail {
                    Text(detail).font(Theme.Font.monoSmall).foregroundStyle(Theme.Colors.text3).lineLimit(1).truncationMode(.middle)
                }
            }
        case .result:
            Text(event.text)
                .font(Theme.Font.body)
                .textSelection(.enabled)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        case .error:
            Label(event.text, systemImage: "exclamationmark.triangle").font(Theme.Font.small).foregroundStyle(Theme.Colors.warning)
        case .info:
            Text(event.text).font(Theme.Font.caption).foregroundStyle(Theme.Colors.text3)
        }
    }

    private var icon: String {
        let name = event.text.lowercased()
        if name.hasPrefix("vesalius") { return "point.3.connected.trianglepath.dotted" }
        if name.contains("edit") || name.contains("write") { return "pencil" }
        if name.contains("read") { return "doc.text" }
        if name.contains("bash") || name.contains("run") { return "terminal" }
        if name.contains("grep") || name.contains("glob") { return "magnifyingglass" }
        return "wrench.and.screwdriver"
    }
}
