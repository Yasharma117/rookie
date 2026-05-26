import SwiftUI

struct ReminderToggle: View {
    @Binding var reminderDate: Date?
    let noteText: String

    @State private var isOn: Bool = false
    @State private var showDatePicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bell.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text("Remind me")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Toggle("", isOn: $isOn.animation(.spring(response: 0.3, dampingFraction: 0.75)))
                    .labelsHidden()
                    .tint(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if isOn {
                Divider().padding(.horizontal, 16)
                DatePicker(
                    "",
                    selection: Binding(
                        get: { reminderDate ?? inferredDate(from: noteText) ?? defaultReminderDate },
                        set: { reminderDate = $0 }
                    ),
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    if reminderDate == nil {
                        reminderDate = inferredDate(from: noteText) ?? defaultReminderDate
                    }
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipped()
        .onChange(of: isOn) { _, on in
            if !on { reminderDate = nil }
        }
    }

    private var defaultReminderDate: Date {
        Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    }

    private func inferredDate(from text: String) -> Date? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.date
    }
}
