import SwiftUI

struct HomeView: View {
    @State private var screenName: String = ""

    var body: some View {
        VStack(spacing: 16) {
            searchBar
                .padding(.horizontal)
                .padding(.top, 24)

            if screenName.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mediaGridPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Home")
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("输入 X 用户 screen_name", text: $screenName)
            Button("Fetch") { }
                .buttonStyle(.glassProminent)
        }
        .padding(12)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("输入用户 screen_name 开始浏览")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var mediaGridPlaceholder: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200))], spacing: 12) {
                ForEach(0..<12, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.15))
                        .aspectRatio(1, contentMode: .fit)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }
            .padding()
        }
    }
}

#Preview {
    HomeView()
}
