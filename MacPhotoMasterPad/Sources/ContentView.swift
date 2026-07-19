import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("MacPhotoMaster for iPad")
                .font(.title2)
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
