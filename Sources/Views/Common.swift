import SwiftUI

/// Poster / logo with a placeholder; AsyncImage cancels when the cell leaves the screen.
struct Art: View {
    let url: String?
    var fit = false
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img): if fit { img.resizable().scaledToFit() } else { img.resizable().scaledToFill() }
            default: ZStack { Theme.surface; Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
    }
}

struct PosterCard: View {
    let title: String
    let poster: String?
    var progress: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Art(url: poster)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if let p = progress { GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * p, height: 4) }.frame(height: 4).padding(6) }
                }
            Text(title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
        }
    }
}

struct LoadingOrError: View {
    @EnvironmentObject var library: Library
    var body: some View {
        if library.loading { ProgressView("جارٍ التحميل…").padding() }
        else if let e = library.error {
            VStack(spacing: 12) {
                Text(e).multilineTextAlignment(.center)
                Button("إعادة المحاولة") { Task { await library.reload() } }.buttonStyle(.borderedProminent)
            }.padding()
        }
    }
}

/// Category chips (horizontal) used by Movies and Series.
struct Chips: View {
    let cats: [Category]
    @Binding var selected: String?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("الكل", nil)
                ForEach(cats) { chip($0.name, $0.id) }
            }.padding(.horizontal)
        }
    }
    private func chip(_ t: String, _ id: String?) -> some View {
        Button(t) { selected = id }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected == id ? Theme.accent : Theme.surface, in: Capsule())
            .foregroundStyle(selected == id ? Color.black : Color.white)
    }
}
