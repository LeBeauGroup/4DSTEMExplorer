import SwiftUI

struct ScanImageView: View {
    @ObservedObject var viewModel: DataViewModel

    var body: some View {
        Group {
            if let img = viewModel.scanImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("No image")
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color.black.opacity(0.05))
    }
}

#Preview {
    let vm = DataViewModel()
    // For preview, optionally assign a placeholder image
    vm.scanImage = NSImage(size: NSSize(width: 100, height: 100))
    return ScanImageView(viewModel: vm)
}
