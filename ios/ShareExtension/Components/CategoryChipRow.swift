import SwiftUI

struct CategoryChipRow: View {
    let categories: [CategoryRef]
    let isLoading: Bool
    @Binding var selectedID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isLoading {
                    ForEach(0..<4, id: \.self) { _ in
                        skeletonChip
                    }
                } else {
                    ForEach(categories) { category in
                        chip(for: category)
                    }
                    addChip
                }
            }
        }
    }

    // MARK: - Subviews

    private func chip(for category: CategoryRef) -> some View {
        let isSelected = selectedID == category.id
        let isAI = category.confidence != nil

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                selectedID = isSelected ? nil : category.id
            }
        } label: {
            HStack(spacing: 4) {
                if isAI && isSelected {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(category.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier(ChipBackgroundModifier(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
    }

    private var addChip: some View {
        Button {
            // Deep-link to category creation in main app
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var skeletonChip: some View {
        Capsule()
            .fill(Color(.secondarySystemBackground))
            .frame(width: CGFloat.random(in: 60...100), height: 36)
    }
}

// MARK: - Chip background modifier

/// Selected chips use a solid accent color for contrast.
/// Unselected chips use Liquid Glass on iOS 26+, with a separator border on older iOS.
private struct ChipBackgroundModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
        } else {
            content
                .foregroundStyle(.primary)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
    }
}
