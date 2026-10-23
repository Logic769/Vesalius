import AppKit
import RepositoryIndex
import SwiftUI
import VesaliusCore

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            intro
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            recents
                .frame(width: 360)
                .frame(maxHeight: .infinity)
                .background(Theme.Colors.inset)
        }
        .background(Theme.Colors.base)
        .navigationTitle("Vesalius")
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Vesalius")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text1)
                Text("Understand the anatomy of your codebase.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.Colors.text2)
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                feature(SidebarSection.map.systemImage, SidebarSection.map.tint, "System map", "Explore modules, files and symbols as a clustered dependency graph.")
                feature(SidebarSection.health.systemImage, SidebarSection.health.tint, "Health diagnosis", "Find cycles, hubs, oversized files and unused code, with the evidence.")
                feature(SidebarSection.search.systemImage, SidebarSection.search.tint, "Ask the codebase", "Natural-language questions answered from a persistent local index.")
                feature("terminal.fill", Theme.Hue.gray, "Agent ready", "The same index powers the `vesalius` CLI and MCP server for coding agents.")
            }
            HStack(spacing: Theme.Space.m) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open Repository…", systemImage: "folder")
                        .padding(.horizontal, Theme.Space.s)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o")
                .accessibilityIdentifier("open-repository")
                Text("or drop a folder here")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.text3)
            }
            if let error = model.openError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Colors.warning)
            }
            Spacer().frame(height: Theme.Space.s)
            Label("Everything runs on this Mac. Your source code is never uploaded.", systemImage: "lock")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Colors.text3)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(Theme.Space.xxl)
    }

    /// Each feature wears the tile of the section that delivers it, so the colours are learned here.
    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            IconTile(systemImage: symbol, color: color, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.rowTitle).foregroundStyle(Theme.Colors.text1)
                Text(detail).font(Theme.Font.small).foregroundStyle(Theme.Colors.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Repositories")
                .font(Theme.Font.section)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.s)
            let others = model.otherIndexedRepositories
            if model.recents.isEmpty && others.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Repositories", systemImage: "clock")
                } description: {
                    Text("Repositories you open appear here.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.recents) { recent in
                        RecentRow(name: recent.name, path: recent.path, date: recent.lastOpened, exists: recent.exists) {
                            model.open(recent.url)
                        }
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
                                .disabled(!recent.exists)
                            Button("Remove from Recents") { model.removeRecent(recent) }
                        }
                    }
                    if !others.isEmpty {
                        Section("Indexed from the command line") {
                            ForEach(others) { record in
                                RecentRow(name: record.name, path: record.path, date: record.lastIndexedAt, exists: true) {
                                    model.open(URL(fileURLWithPath: record.path))
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("recent-repositories")
            }
        }
    }
}

private struct RecentRow: View {
    let name: String
    let path: String
    let date: Date?
    let exists: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: exists ? "folder.fill" : "questionmark.folder")
                    .font(.system(size: 16))
                    .foregroundStyle(exists ? Theme.Hue.blue : Theme.Colors.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.Font.rowTitle).foregroundStyle(exists ? Theme.Colors.text1 : Theme.Colors.text3)
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Colors.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let date {
                    Text(date, format: .relative(presentation: .named))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Colors.text3)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help(exists ? path : "This folder no longer exists. It may have been moved or deleted.")
    }
}
