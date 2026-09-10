import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationItem?

    var body: some View {
        VStack(spacing: 0) {
            accountCard
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            List(selection: $selection) {
                Section {
                    ForEach(NavigationItem.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)

            Spacer()
        }
        .frame(minWidth: 200, idealWidth: 220)
        .background(.clear)
    }

    private var accountCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .frame(width: 40, height: 40)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("未登录")
                    .font(.headline)
                Text("点击导入 Cookie")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

#Preview {
    SidebarView(selection: .constant(.home))
}
