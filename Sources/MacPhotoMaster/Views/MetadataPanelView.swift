import SwiftUI

/// Editable metadata fields + AI/GPS/save/process actions. See docs/SPEC.md §2-7.
///
/// Read-only for now: `ExifToolClient`'s write path (spec §3) doesn't exist yet, so there's
/// nowhere for an edit to go. Fields display what `NativeMetadataReader` read for the current
/// selection; editing/Save/AI/rename/process actions come once the write path is built.
struct MetadataPanelView: View {
    let asset: PhotoAsset?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
                .padding([.top, .horizontal])

            if let asset {
                Form {
                    LabeledContent("Title", value: asset.title)
                    LabeledContent("Description", value: asset.descriptionText)
                    LabeledContent("Keywords", value: asset.keywords.joined(separator: ", "))
                    LabeledContent("Camera", value: asset.cameraModel)
                    LabeledContent("Lens", value: asset.lensModel)
                    LabeledContent("Aperture", value: asset.aperture)
                    LabeledContent("Shutter", value: asset.shutterSpeed)
                    LabeledContent("Focal length", value: asset.focalLength)
                    LabeledContent("ISO", value: asset.iso)
                    if let capturedAt = asset.capturedAt {
                        LabeledContent("Captured", value: capturedAt.formatted())
                    }
                    if let latitude = asset.gpsLatitude, let longitude = asset.gpsLongitude {
                        LabeledContent("GPS", value: "\(latitude), \(longitude)")
                    }
                }
                .formStyle(.grouped)
            } else {
                Spacer()
                Text("Select a photo to see its metadata.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}

#Preview {
    MetadataPanelView(asset: nil)
}
