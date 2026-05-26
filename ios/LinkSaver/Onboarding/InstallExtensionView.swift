import SwiftUI

struct InstallExtensionView: View {
    @Binding var isDone: Bool

    private let steps: [(String, String)] = [
        ("square.and.arrow.up", "Tap the Share button in Safari or any app"),
        ("ellipsis.circle", "Scroll down and tap 'More'"),
        ("checkmark.circle.fill", "Enable 'LinkSaver' and tap Done")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    Text("Enable the Share Extension")
                        .font(.title2.bold())
                    Text("Follow these steps to add LinkSaver to your share sheet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.12))
                                    .frame(width: 44, height: 44)
                                Image(systemName: step.0)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(step.1)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
                .padding(20)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 28)

            Spacer()

            Button {
                isDone = true
            } label: {
                Text("Done, I've enabled it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
    }
}
