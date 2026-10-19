import SwiftUI

struct NativeProjectListView: View {
    @ObservedObject var model: BrowserModel
    let openProject: (ProjectItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.projects.isEmpty {
                    emptyState
                } else {
                    List(model.projects) { project in
                        Button {
                            model.selectProject(project)
                            openProject(project)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.orange)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .multilineTextAlignment(.leading)

                                    if model.selectedProject?.id == project.id {
                                        Text("目前專案")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("專案目錄")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.refreshNativeData()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                syncBanner
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在讀取 Brabio 專案…")
                .font(.system(size: 16, weight: .semibold))
            Text("首次登入後會自動同步專案目錄")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var syncBanner: some View {
        switch model.syncState {
        case .syncing:
            HStack(spacing: 9) {
                ProgressView()
                Text("正在同步 Brabio")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 8)

        case .failed(let message):
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
