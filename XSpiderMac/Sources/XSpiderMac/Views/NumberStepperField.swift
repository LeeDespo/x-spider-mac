import SwiftUI

/// 「− 数字 +」数字步进控件：数字右对齐贴着按钮，点击数字可切换为输入框直接键入。
/// 替代系统 Stepper（其数字与 +/- 分离、无法直接输入）。
struct NumberStepperField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 0) {
                // − 按钮
                Button {
                    value = max(range.lowerBound, value - 1)
                } label: {
                    Text("−")
                        .font(.body.weight(.medium))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(value > range.lowerBound ? .primary : .tertiary)
                .disabled(value <= range.lowerBound)

                Divider()
                    .frame(height: 16)

                // 数字：默认只读展示，点击进入输入态
                Group {
                    if isEditing {
                        TextField("", text: $editText)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .frame(width: 44)
                            .font(.body.monospacedDigit())
                            .focused($fieldFocused)
                            .onSubmit(commitEdit)
                    } else {
                        Text("\(value)")
                            .font(.body.monospacedDigit())
                            .frame(width: 44)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editText = "\(value)"
                                isEditing = true
                                fieldFocused = true
                            }
                    }
                }

                Divider()
                    .frame(height: 16)

                // + 按钮
                Button {
                    value = min(range.upperBound, value + 1)
                } label: {
                    Text("+")
                        .font(.body.weight(.medium))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(value < range.upperBound ? .primary : .tertiary)
                .disabled(value >= range.upperBound)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            if !focused && isEditing { commitEdit() }
        }
    }

    private func commitEdit() {
        defer { isEditing = false }
        guard let n = Int(editText.trimmingCharacters(in: .whitespaces)) else { return }
        value = min(range.upperBound, max(range.lowerBound, n))
    }
}

#Preview {
    Form {
        NumberStepperField(title: "同时下载文件数", value: .constant(5), range: 1...20)
        NumberStepperField(title: "单文件连接数", value: .constant(8), range: 1...16)
    }
    .formStyle(.grouped)
    .frame(width: 480)
}
