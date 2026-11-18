// SPDX-License-Identifier: GPL-3.0-only
//
// Dialer Themer UI ported from Erosion (jailbreakdotparty / lunginspector), GPL v3.
// Wired into GestaltX Tools → Customization. Import zip / apply / reset / preview.
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct DialerThemerView: View {
    @StateObject private var model = DialerThemerModel()
    @State private var size: DialerKeySize = .defSize
    @State private var customWidth = 200
    @State private var customHeight = 200
    @State private var showCustomSize = false
    @State private var showImporter = false
    @State private var askReset = false
    @State private var askOpenPhone = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        Group {
            if !model.isReady {
                ContentUnavailableView {
                    Label(L("Dialer Themer"), systemImage: "circle.grid.3x3")
                } description: {
                    Text(model.status ?? L("Locating Phone container…"))
                } actions: {
                    if model.isBusy { ProgressView() }
                }
            } else {
                readyBody
            }
        }
        .navigationTitle(L("Dialer Themer"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { model.maskIntoCircle(size: size, customWidth: customWidth, customHeight: customHeight) } label: {
                        Label(L("Mask Keys"), systemImage: "circle")
                    }
                    Button {
                        size = .defSize
                        model.loadCurrentKeys()
                    } label: {
                        Label(L("Get Current Keys"), systemImage: "externaldrive")
                    }
                    Button { model.openPhone() } label: {
                        Label(L("Open Phone"), systemImage: "arrow.up.right.square")
                    }
                    Divider()
                    Button {
                        size = .defSize
                        model.clearKeys()
                    } label: {
                        Label(L("Clear Keys"), systemImage: "xmark")
                    }
                    Button(role: .destructive) { askReset = true } label: {
                        Label(L("Restore Original"), systemImage: "arrow.uturn.backward")
                    }
                } label: {
                    Label(L("Menu"), systemImage: "ellipsis.circle")
                }
                .disabled(!model.isReady || model.isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(L("Import")) { showImporter = true }
                    .disabled(!model.isReady || model.isBusy)
            }
        }
        .task { await model.prepare() }
        .onDisappear { model.shutdown() }
        .sheet(isPresented: $showImporter) {
            CustomizationFilePicker(allowedTypes: [.zip, .data]) { result in
                showImporter = false
                switch result {
                case .success(let url):
                    _ = model.importTheme(from: url)
                case .failure(let error):
                    model.message = error.localizedDescription
                }
            }
            .ignoresSafeArea()
        }
        .alert(L("Custom key size"), isPresented: $showCustomSize) {
            TextField(L("Width"), value: $customWidth, format: .number)
                .keyboardType(.numberPad)
            TextField(L("Height"), value: $customHeight, format: .number)
                .keyboardType(.numberPad)
            Button(L("Cancel"), role: .cancel) { size = .defSize }
            Button(L("Set")) {
                model.changeSize(.custom, customWidth: customWidth, customHeight: customHeight)
            }
        } message: {
            Text(L("Enter width and height in points (50–2500)."))
        }
        .alert(L("Restore Original"), isPresented: $askReset) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Restore"), role: .destructive) {
                if model.reset() { askOpenPhone = true }
            }
        } message: {
            Text(DialerThemerMsg.resetWarn)
        }
        .alert(L("GestaltX"), isPresented: Binding(
            get: { model.message != nil && !askOpenPhone },
            set: { if !$0 {
                if model.message == DialerThemerMsg.applyComp { askOpenPhone = true }
                model.message = nil
            } }
        )) {
            Button(L("OK"), role: .cancel) {
                if model.message == DialerThemerMsg.applyComp { askOpenPhone = true }
                model.message = nil
            }
        } message: {
            Text(model.message ?? "")
        }
        .alert(L("Open Phone?"), isPresented: $askOpenPhone) {
            Button(L("Not Now"), role: .cancel) {}
            Button(L("Open Phone")) { model.openPhone() }
        } message: {
            Text(DialerThemerMsg.applyComp)
        }
    }

    private var readyBody: some View {
        List {
            Section {
                Picker(L("Key Size"), selection: $size) {
                    ForEach(DialerKeySize.allCases) { option in
                        Text(option.label + (option == .custom ? " (\(customWidth)×\(customHeight))" : ""))
                            .tag(option)
                    }
                }
                .onChange(of: size) { _, newSize in
                    if newSize == .custom {
                        showCustomSize = true
                    } else {
                        model.changeSize(newSize)
                    }
                }
            } footer: {
                Text(L("Import a TelephonyUI theme zip, preview the 12 keys, then apply. Only the dial pad keys can be themed — not the green call button."))
            }

            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach($model.keys) { $item in
                        DialerKeyCell(item: $item, size: size, customWidth: customWidth, customHeight: customHeight, model: model)
                    }
                }
                .padding(.vertical, 8)
            }

            Section {
                Button {
                    if model.apply() { /* alert via message */ }
                } label: {
                    Label(L("Apply Dialer Theme"), systemImage: "checkmark.circle.fill")
                }
                .disabled(model.keys.allSatisfy(\.imgData.isEmpty) || model.isBusy)

                Button { model.openPhone() } label: {
                    Label(L("Open Phone"), systemImage: "phone")
                }
            }
        }
    }
}

private struct DialerKeyCell: View {
    @Binding var item: DialerKeyItem
    let size: DialerKeySize
    let customWidth: Int
    let customHeight: Int
    @ObservedObject var model: DialerThemerModel
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: 78, height: 78)
                if let image = UIImage(data: item.imgData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                        Text(item.keyID.displayLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let resized: Data = {
                    switch size {
                    case .defSize:
                        return model.resize(data, size: size, isDefault: true)
                    case .custom:
                        return model.resize(data, size: size, custom: CGSize(width: customWidth, height: customHeight))
                    default:
                        return model.resize(data, size: size)
                    }
                }()
                await MainActor.run {
                    model.update(key: self.item.keyID, data: resized, original: resized)
                    photoItem = nil
                }
            }
        }
    }
}
