import SwiftUI

/// Help for physically connecting a camera: what the connection needs, the camera settings the app depends on,
/// the connection steps, and common failures. The same text applies to every supported body.
struct ConnectionGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Fuji Cookbook reads and writes your camera’s custom settings over a USB cable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Before You Start") {
                    guideRow("A compatible Fujifilm camera", nil, systemImage: "camera")
                    guideRow("A USB-C data cable", nil, systemImage: "cable.connector")
                    guideRow("A Lightning to USB adapter",
                             "Only if your iPhone has a Lightning port (iPhone 14 or earlier). If you need an adapter, [this one](https://www.amazon.com/dp/B0BQJ1CF62) has been tested and works with the app.",
                             systemImage: "bolt.horizontal")
                }

                Section("Set Up Your Camera") {
                    guideRow("C Dial",
                             "If your camera has a film simulation dial (X-T50, X-M5, X-E5, or X-T30 III), turn the dial to C. In any other position, the dial sets the film simulation and overrides the recipe that the app sends.",
                             step: 1)
                    guideRow("USB Connection Mode",
                             "Select Network/USB Setting > Connection Mode > USB RAW CONV./BACKUP RESTORE. On older models, this setting is at Connection Settings > USB Mode. In this mode, the app can read and write your custom settings.",
                             step: 2)
                    guideRow("USB Power Mode",
                             "Select Network/USB Setting > USB Power Supply/Comm Setting > POWER SUPPLY OFF/COMM ON. This setting stops the camera from drawing power from your iPhone or iPad. If the camera draws power, iOS might end the connection to protect its battery.",
                             step: 3)
                    guideRow("Auto Update Custom Settings",
                             "In the image quality menu, set AUTO UPDATE CUSTOM SETTING to DISABLE. With this setting, menu changes you make while you shoot don’t overwrite your saved recipes.",
                             step: 4)
                }

                Section("Connect Your Camera") {
                    guideRow("Open the Camera tab", "In Fuji Cookbook, tap the Camera tab.", step: 1)
                    guideRow("Turn on your camera", nil, step: 2)
                    guideRow("Connect the cable to your iPhone or iPad",
                             "If your device has a Lightning port, connect the cable through the adapter.",
                             step: 3)
                    guideRow("Connect the other end to the camera’s USB port",
                             "The camera’s screen goes black or shows a PC or USB icon.",
                             step: 4)
                    guideRow("Tap Connect Camera (USB)",
                             "The app finds the camera and shows your custom setting slots and their recipes.",
                             step: 5)
                }

                Section("If It Doesn’t Connect") {
                    troubleshootRow("Nothing detected", "The cable may be charge-only, or an adapter may be unpowered/non-Apple. Swap to a known data cable.")
                    troubleshootRow("Detected but errors", "The camera is probably in the wrong USB mode. Check USB Connection Mode under Set Up Your Camera and reconnect.")
                    troubleshootRow("Permission prompt", "Allow both Camera and Files and Folders access when iOS asks. Both permissions are needed to communicate with the camera.")
                }

                Section {
                    Label("Camera Test backs up your settings before checking grain or writing a recipe. You choose the slot for the test recipe.",
                          systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
            .navigationTitle("Connection Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func guideRow(_ title: String, _ detail: LocalizedStringKey?, systemImage: String) -> some View {
        Label {
            rowText(title, detail)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.tint)
        }
    }

    private func guideRow(_ title: String, _ detail: LocalizedStringKey?, step: Int) -> some View {
        guideRow(title, detail, systemImage: "\(step).circle")
    }

    private func rowText(_ title: String, _ detail: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func troubleshootRow(_ title: String, _ detail: LocalizedStringKey) -> some View {
        rowText(title, detail)
    }
}
