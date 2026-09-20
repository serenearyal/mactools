import SwiftUI

/// The first-run card at the top of the Overview.
///
/// It is a card like the four below it, not a sheet and not a wizard: every
/// one of these grants is optional, Vent works without them, and a modal that
/// demands four trips to System Settings before the app will show a number
/// would be a lie about what it needs.
struct SetupChecklistCard: View {
    let checklist: SetupChecklist

    var body: some View {
        Card(title: "Setup", symbolName: "checklist", fills: false) {
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Layout.gutter) {
                ForEach(checklist.steps) { step in
                    StepRow(step: step) { checklist.perform($0) }
                }
            }

            Divider()

            HStack(spacing: Layout.gutter) {
                Text("They refresh by themselves when you come back from System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Layout.gutter)
                Button(checklist.isComplete ? "Done" : "Dismiss") {
                    checklist.dismiss()
                }
                .controlSize(.small)
                .help("Hides this card. Settings brings it back.")
            }
        }
    }

    private var headline: String {
        checklist.isComplete
            ? "Everything Vent asks for is granted."
            : "\(checklist.remaining) of \(checklist.steps.count) still open. Vent runs without them; each one unlocks one feature."
    }
}

private struct StepRow: View {
    let step: SetupStep
    let perform: (SetupStep.Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.gutter) {
            // Fixed width: the two symbols differ in width, and without it
            // every row would start its title at another x.
            Image(systemName: step.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(step.isDone ? Color.green : Color.secondary)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                Text(step.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Layout.gutter)
            if let title = step.actionTitle, let action = step.action {
                Button(title) { perform(action) }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }
}
