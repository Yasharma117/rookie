import SwiftUI

struct SheetActions: View {
    @ObservedObject var viewModel: ShareViewModel

    var body: some View {
        VStack(spacing: 10) {
            primaryButton
            cancelButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.state {
        case .saved:
            savedConfirmation
        case .offline:
            if #available(iOS 26.0, *) {
                Button(action: viewModel.saveOffline) {
                    Label("Save Offline", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.glass)
                .tint(.orange)
            } else {
                Button(action: viewModel.saveOffline) {
                    Label("Save Offline", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        case .authExpired:
            if #available(iOS 26.0, *) {
                Button(action: viewModel.openMainApp) {
                    Label("Open LinkSaver", systemImage: "arrow.up.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.glass)
                .tint(.accentColor)
            } else {
                Button(action: viewModel.openMainApp) {
                    Label("Open LinkSaver", systemImage: "arrow.up.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        case .duplicate:
            if #available(iOS 26.0, *) {
                Button(action: viewModel.commitSave) {
                    Label("Update Note", systemImage: "pencil")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.glass)
                .tint(.accentColor)
                .opacity(viewModel.noteText.isEmpty ? 0.5 : 1)
                .disabled(viewModel.noteText.isEmpty)
            } else {
                Button(action: viewModel.commitSave) {
                    Label("Update Note", systemImage: "pencil")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .opacity(viewModel.noteText.isEmpty ? 0.5 : 1)
                .disabled(viewModel.noteText.isEmpty)
            }
        default:
            if #available(iOS 26.0, *) {
                Button(action: viewModel.commitSave) {
                    Group {
                        if viewModel.state.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text("Saving…")
                            }
                        } else {
                            Text("Save")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.glass)
                .tint(viewModel.state.canSave ? .accentColor : Color.accentColor.opacity(0.5))
                .disabled(!viewModel.state.canSave)
            } else {
                Button(action: viewModel.commitSave) {
                    Group {
                        if viewModel.state.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text("Saving…")
                            }
                        } else {
                            Text("Save")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(
                        viewModel.state.canSave ? Color.accentColor : Color.accentColor.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.state.canSave)
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel", action: viewModel.cancel)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private var savedConfirmation: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Saved!")
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassyBackground(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
