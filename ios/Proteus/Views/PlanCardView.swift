import SwiftUI
import ProteusKit

// MARK: - Plan card (v10 §10)

/// ExitPlanMode arrives as a permission request whose input is {plan}. Show the
/// plan as markdown and let the user approve (optionally switching to accept
/// edits) or keep planning with feedback.
struct PlanCardView: View {
    @EnvironmentObject private var app: AppModel
    let request: PermissionRequest

    @State private var feedback = ""
    @State private var acceptEdits = false

    private var plan: String {
        request.input["plan"]?.stringValue ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.blue)
                Text("Review the plan")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("ExitPlanMode")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                if plan.isEmpty {
                    Text("The plan is empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownText(text: plan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 260)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10)))

            TextField("Feedback (optional)", text: $feedback, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .font(.callout)

            Toggle("and accept edits", isOn: $acceptEdits)
                .font(.callout)

            HStack(spacing: 8) {
                Button("Keep planning") { keepPlanning() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Approve") {
                    app.approvePlan(request, acceptEdits: acceptEdits)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }

    private func keepPlanning() {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        app.replyPermission(
            request,
            allow: false,
            always: false,
            message: text.isEmpty ? "Keep planning." : text
        )
    }
}
