import SwiftUI
import ProteusKit

// MARK: - Question card (v10 §10)

/// AskUserQuestion arrives as a normal permission request. This card shows the
/// questions the tool asked, collects one answer per question and replies with
/// `answers` mapped by question text (the SDK's `updatedInput` contract).
struct QuestionCardView: View {
    @EnvironmentObject private var app: AppModel
    let request: PermissionRequest

    private let questions: [QuestionSpec]
    @State private var selections: [Set<String>]
    @State private var otherText: [String]

    init(request: PermissionRequest) {
        self.request = request
        let parsed = QuestionSpec.parse(request.input)
        questions = parsed
        _selections = State(initialValue: Array(repeating: [], count: parsed.count))
        _otherText = State(initialValue: Array(repeating: "", count: parsed.count))
    }

    private var canSubmit: Bool {
        !questions.isEmpty && questions.indices.allSatisfy { !answerText(for: $0).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(questions) { question in
                        block(for: question)
                    }
                }
            }
            .frame(maxHeight: 360)

            actions
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(.blue)
            Text("Question")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(answeredCount)/\(questions.count) answered")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var answeredCount: Int {
        questions.indices.filter { !answerText(for: $0).isEmpty }.count
    }

    private func block(for question: QuestionSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(question.id + 1)")
                    .font(.caption2.weight(.bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                if let chip = question.header, !chip.isEmpty {
                    Text(chip)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                Spacer()
                Text(question.multiSelect ? "Select all that apply" : "Pick one")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(question.options) { option in
                optionRow(question, option)
            }

            otherRow(question)

            previews(for: question)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func optionRow(_ question: QuestionSpec, _ option: QuestionOption) -> some View {
        let selected = selections[question.id].contains(option.label)
        return Button {
            select(question, option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: indicator(question, selected: selected))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.callout)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func otherRow(_ question: QuestionSpec) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Other…", text: otherBinding(question.id))
                .textFieldStyle(.plain)
                .font(.callout)
                .submitLabel(.done)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
    }

    private func previews(for question: QuestionSpec) -> some View {
        let shown = question.options.filter {
            selections[question.id].contains($0.label)
                && !($0.preview ?? "").isEmpty
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown) { option in
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(option.preview ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Skip") { skip() }
                .buttonStyle(.bordered)
            Spacer()
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
        }
    }

    private func indicator(_ question: QuestionSpec, selected: Bool) -> String {
        if question.multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private func select(_ question: QuestionSpec, _ option: QuestionOption) {
        if question.multiSelect {
            if selections[question.id].contains(option.label) {
                selections[question.id].remove(option.label)
            } else {
                selections[question.id].insert(option.label)
            }
        } else {
            selections[question.id] = [option.label]
            // Typing an Other answer and then picking an option replaces it.
            otherText[question.id] = ""
        }
    }

    private func otherBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { otherText[index] },
            set: { value in
                otherText[index] = value
                if !questions[index].multiSelect {
                    // Other takes over: a single-select answer is one string.
                    selections[index] = []
                }
            }
        )
    }

    private func answerText(for index: Int) -> String {
        let question = questions[index]
        let other = otherText[index].trimmingCharacters(in: .whitespacesAndNewlines)
        if question.multiSelect {
            var labels = question.options
                .filter { selections[index].contains($0.label) }
                .map(\.label)
            if !other.isEmpty { labels.append(other) }
            return labels.joined(separator: ", ")
        }
        if !other.isEmpty { return other }
        return question.options.first { selections[index].contains($0.label) }?.label ?? ""
    }

    private func submit() {
        guard canSubmit else { return }
        var answers: [String: String] = [:]
        for question in questions {
            answers[question.question] = answerText(for: question.id)
        }
        app.replyPermission(request, allow: true, always: false, answers: answers)
    }

    private func skip() {
        app.replyPermission(
            request,
            allow: false,
            always: false,
            message: "The user did not answer; continue with your best judgement."
        )
    }
}

// MARK: - Parsing

struct QuestionOption: Identifiable {
    let id: Int
    let label: String
    let description: String?
    let preview: String?
}

struct QuestionSpec: Identifiable {
    let id: Int
    let question: String
    let header: String?
    let multiSelect: Bool
    let options: [QuestionOption]

    static func parse(_ input: JSONValue) -> [QuestionSpec] {
        guard let raw = input["questions"]?.arrayValue else { return [] }
        return raw.enumerated().compactMap { index, value in
            guard let text = value["question"]?.stringValue, !text.isEmpty else { return nil }
            let options = value["options"]?.arrayValue?.enumerated().compactMap { optionIndex, option -> QuestionOption? in
                guard let label = option["label"]?.stringValue else { return nil }
                return QuestionOption(
                    id: optionIndex,
                    label: label,
                    description: option["description"]?.stringValue,
                    preview: option["preview"]?.stringValue
                )
            } ?? []
            return QuestionSpec(
                id: index,
                question: text,
                header: value["header"]?.stringValue,
                multiSelect: value["multiSelect"]?.boolValue ?? false,
                options: options
            )
        }
    }
}
