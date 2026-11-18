// SPDX-License-Identifier: GPL-3.0-only
//
// Dialer Themer logic ported from Erosion (jailbreakdotparty / lunginspector),
// GNU GPL v3. Adapted to GestaltX container resolution (resolveDataContainer /
// acquirePath / worse_query) and ZIPFoundation via CustomizationArchive.
// Original keypad theme import matching: TelephonyUI-8/9/10 folders, key tokens
// via split("-")[1], --mask = light / --white = dark.
import Combine
import Foundation
import UIKit

enum DialerKeyID: String, CaseIterable, Identifiable {
    case one, two, three, four, five, six, seven, eight, nine, star, zero, pound
    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .six: return "6"
        case .seven: return "7"
        case .eight: return "8"
        case .nine: return "9"
        case .star: return "*"
        case .zero: return "0"
        case .pound: return "#"
        }
    }

    func fileNames(prefix: String) -> [String] {
        let suffixes = ["--mask.png", "--white.png", "-hi-mask.png", "-hi-white.png",
                        "--white-bold.png", "--mask-bold.png"]
        let key: String
        switch self {
        case .one: key = "-1-"
        case .two: key = "-2-A B C"
        case .three: key = "-3-D E F"
        case .four: key = "-4-G H I"
        case .five: key = "-5-J K L"
        case .six: key = "-6-M N O"
        case .seven: key = "-7-P Q R S"
        case .eight: key = "-8-T U V"
        case .nine: key = "-9-W X Y Z"
        case .star: key = "-*-"
        case .zero: key = "-0-+"
        case .pound: key = "-#-"
        }
        return suffixes.map { prefix + key + $0 }
    }

    func accentedFileName(prefix: String) -> String {
        let names = fileNames(prefix: prefix)
        switch UIScreen.main.traitCollection.userInterfaceStyle {
        case .dark: return names[1] // --white.png
        default: return names[0]    // --mask.png
        }
    }
}

enum DialerKeySize: Int, CaseIterable, Identifiable {
    case defSize, small, medium, large, custom
    var id: Int { rawValue }
    var float: CGFloat {
        switch self {
        case .small: return 150
        case .medium: return 205
        case .large: return 225
        default: return 0
        }
    }
    var label: String {
        switch self {
        case .defSize: return "Default"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .custom: return "Custom"
        }
    }
}

enum DialerKeySizeLimits {
    static let min = CGFloat(50)
    static let max = CGFloat(2500)
}

struct DialerKeyItem: Identifiable, Equatable {
    let id = UUID()
    var keyID: DialerKeyID
    var imgData = Data()
    var ogImgData = Data()
}

enum DialerThemerMsg {
    static let resetWarn = "Restore the Phone dialer keys to their original look? You'll lose both what you're currently editing and what you've already set inside of the Phone app."
    static let applyComp = "For changes to take effect, open the Phone app and change the appearance until your custom keys show up. You can also restart your device. Do NOT force kill the Phone app!"
    static let phoneBundle = "com.apple.mobilephone"
    static let telephonyFolder = "Library/Caches/TelephonyUI-10"
    static let containerDefaultsKey = "GestaltX.dialer.mpContainerPath"
}

@MainActor
final class DialerThemerModel: ObservableObject {
    @Published var keys: [DialerKeyItem] = DialerKeyID.allCases.map { DialerKeyItem(keyID: $0) }
    @Published var isReady = false
    @Published var isBusy = false
    @Published var status: String?
    @Published var message: String?
    @Published private(set) var containerPath = ""

    private let fm = FileManager.default
    private var activeLease: Int64 = -1

    func shutdown() {
        releaseLease()
    }

    func prepare() async {
        guard !isReady else { return }
        isBusy = true
        status = L("Locating Phone container…")
        defer { isBusy = false }
        #if targetEnvironment(simulator)
        message = L("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
        status = nil
        return
        #else
        let path = await Task.detached(priority: .userInitiated) { () -> String? in
            if let cached = UserDefaults.standard.string(forKey: DialerThemerMsg.containerDefaultsKey),
               !cached.isEmpty,
               let verified = GXCustomizationAccess.applicationContainer(for: DialerThemerMsg.phoneBundle, hint: cached) {
                return verified
            }
            return GXCustomizationAccess.resolveDataContainer(for: DialerThemerMsg.phoneBundle)
        }.value
        guard let path else {
            message = L("The Phone app container could not be located. Try again after the device is unlocked.")
            status = nil
            return
        }
        UserDefaults.standard.set(path, forKey: DialerThemerMsg.containerDefaultsKey)
        containerPath = path
        guard acquire(path) else {
            message = L("The Phone app container could not be opened for writing.")
            status = nil
            return
        }
        loadCurrentKeys(saveOriginal: true)
        isReady = true
        status = nil
        log("Dialer Themer: ready at \(path)")
        #endif
    }

    @discardableResult
    private func acquire(_ path: String) -> Bool {
        releaseLease()
        #if os(iOS) && !targetEnvironment(simulator)
        let lease = GXCustomizationAccess.acquirePath(path)
        guard lease >= 0 else { return false }
        activeLease = lease
        return true
        #else
        return false
        #endif
    }

    private func releaseLease() {
        #if os(iOS) && !targetEnvironment(simulator)
        if activeLease >= 0 {
            worse_query_release(activeLease)
            activeLease = -1
        }
        #endif
    }

    private func telephonyURL() -> URL {
        URL(fileURLWithPath: containerPath, isDirectory: true)
            .appendingPathComponent(DialerThemerMsg.telephonyFolder, isDirectory: true)
    }

    /// Device-specific filename prefix used by TelephonyUI-10 (e.g. "other" or a hash).
    func filePrefix() -> String {
        let dir = telephonyURL()
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
              let first = urls.first else { return "other" }
        let parts = first.lastPathComponent.split(separator: "-").map(String.init)
        return parts.first ?? "other"
    }

    func update(key: DialerKeyID, data: Data, original: Data? = nil) {
        guard let index = keys.firstIndex(where: { $0.keyID == key }) else { return }
        keys[index].imgData = data
        if let original { keys[index].ogImgData = original }
    }

    func clearKeys() {
        for i in keys.indices {
            keys[i].imgData = Data()
            keys[i].ogImgData = Data()
        }
    }

    func loadCurrentKeys(size: DialerKeySize = .defSize, custom: CGSize? = nil, saveOriginal: Bool = false) {
        let dir = telephonyURL()
        let prefix = filePrefix()
        for key in DialerKeyID.allCases {
            let url = dir.appendingPathComponent(key.accentedFileName(prefix: prefix))
            guard let data = try? Data(contentsOf: url) else { continue }
            let resized = resize(data, size: size, custom: custom, isDefault: size == .defSize)
            update(key: key, data: resized, original: saveOriginal ? resized : nil)
        }
    }

    func changeSize(_ size: DialerKeySize, customWidth: Int = 0, customHeight: Int = 0) {
        let custom = size == .custom ? CGSize(width: customWidth, height: customHeight) : nil
        for item in keys {
            let resized = resize(item.ogImgData, size: size, custom: custom, isDefault: size == .defSize)
            update(key: item.keyID, data: resized)
        }
    }

    func maskIntoCircle(size: DialerKeySize = .defSize, customWidth: Int = 0, customHeight: Int = 0) {
        let custom = size == .custom ? CGSize(width: customWidth, height: customHeight) : nil
        for item in keys {
            let resized = resize(item.ogImgData, size: size, custom: custom, isDefault: size == .defSize, circle: true)
            update(key: item.keyID, data: resized)
        }
    }

    @discardableResult
    func apply() -> Bool {
        guard acquire(containerPath) else {
            message = L("The Phone app container could not be opened for writing.")
            return false
        }
        let dir = telephonyURL()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let prefix = filePrefix()
        var failed = 0
        for item in keys where !item.imgData.isEmpty {
            for name in item.keyID.fileNames(prefix: prefix) {
                let url = dir.appendingPathComponent(name)
                do { try item.imgData.write(to: url, options: .atomic) }
                catch {
                    log("Dialer Themer: write failed \(name): \(error.localizedDescription)")
                    failed += 1
                }
            }
        }
        if failed == 0 {
            message = DialerThemerMsg.applyComp
            log("Dialer Themer: applied keypad theme")
            return true
        }
        message = L("Some dialer keys could not be written. Try again.")
        return false
    }

    @discardableResult
    func reset() -> Bool {
        guard acquire(containerPath) else {
            message = L("The Phone app container could not be opened for writing.")
            return false
        }
        let dir = telephonyURL()
        do {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in files { try fm.removeItem(at: file) }
            clearKeys()
            loadCurrentKeys(saveOriginal: true)
            message = DialerThemerMsg.applyComp
            log("Dialer Themer: reset TelephonyUI-10 cache")
            return true
        } catch {
            log("Dialer Themer: reset failed: \(error.localizedDescription)")
            message = L("Failed to reset dialer keys.")
            return false
        }
    }

    @discardableResult
    func importTheme(from fileURL: URL) -> Bool {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let temp = fm.temporaryDirectory
                .appendingPathComponent("DialerTheme_\(UUID().uuidString)", isDirectory: true)
            try CustomizationArchive.extract(fileURL, into: temp)
            defer { try? fm.removeItem(at: temp) }

            let telephonyNames: Set<String> = ["TelephonyUI-8", "TelephonyUI-9", "TelephonyUI-10"]
            func firstTelephonyUI(in directory: URL) -> URL? {
                let kids = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                if let match = kids.first(where: { telephonyNames.contains($0.lastPathComponent) }) {
                    return match
                }
                for kid in kids {
                    guard (try? kid.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    if let nested = firstTelephonyUI(in: kid) { return nested }
                }
                return nil
            }

            var themeRoot = temp
            let top = try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            if let match = top.first(where: { telephonyNames.contains($0.lastPathComponent) }) {
                themeRoot = match
            } else if let nested = firstTelephonyUI(in: temp) {
                themeRoot = nested
            } else if top.count == 1, (try? top[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Single wrapper folder with PNGs directly inside (no TelephonyUI-* name).
                themeRoot = top[0]
            }

            let appearanceWanted = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "white" : "mask"
            let files = try fm.contentsOfDirectory(at: themeRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var replaced = 0
            for file in files where file.pathExtension.lowercased() == "png" {
                let split = file.lastPathComponent.split(separator: "-").map(String.init)
                guard split.count >= 2 else { continue }
                let keyNum = split[1]
                let apprName: String = {
                    if split.indices.contains(3) {
                        let appearance = split[3].split(separator: ".")[0]
                        if appearance == appearanceWanted { return split[3] }
                    }
                    if split.indices.contains(2) {
                        let appearance = split[2].split(separator: ".")[0]
                        if appearance == appearanceWanted { return split[2] }
                    }
                    return ""
                }()
                guard !apprName.isEmpty else { continue }
                guard let id = DialerKeyID.allCases.first(where: {
                    $0.fileNames(prefix: "x").contains { $0.contains(keyNum) && $0.contains(apprName) }
                }) else { continue }
                let data = try Data(contentsOf: file)
                update(key: id, data: data, original: data)
                replaced += 1
            }
            guard replaced > 0 else {
                message = L("The zip was opened, but no dialer keys were found.")
                return false
            }
            log("Dialer Themer: imported \(replaced) keys from \(fileURL.lastPathComponent)")
            message = L("Imported dialer theme.")
            return true
        } catch {
            log("Dialer Themer: import failed: \(error.localizedDescription)")
            message = L("Failed to import dialer theme.")
            return false
        }
    }

    func openPhone() {
        #if os(iOS) && !targetEnvironment(simulator)
        if GXCustomizationAccess.openApplication(DialerThemerMsg.phoneBundle) { return }
        #endif
        if let url = URL(string: "tel://") {
            UIApplication.shared.open(url)
        }
    }

    func resize(_ data: Data, size: DialerKeySize, custom: CGSize? = nil, isDefault: Bool = false, circle: Bool = false) -> Data {
        guard let image = UIImage(data: data) else { return data }
        var width = isDefault ? image.size.width : (custom?.width ?? size.float)
        var height = isDefault ? image.size.height : (custom?.height ?? size.float)
        width = min(max(width, DialerKeySizeLimits.min), DialerKeySizeLimits.max)
        height = min(max(height, DialerKeySizeLimits.min), DialerKeySizeLimits.max)
        let resized = image.gxDialerResized(to: CGSize(width: width, height: height), circle: circle)
        return resized.pngData() ?? data
    }

    private func log(_ text: String) {
        NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil,
                                        userInfo: ["message": text])
    }
}

private extension UIImage {
    func gxDialerResized(to size: CGSize, scale: CGFloat = 1.0, circle: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            if circle {
                ctx.addEllipse(in: CGRect(origin: .zero, size: size))
                ctx.clip()
                let fillScale = max(size.width / self.size.width, size.height / self.size.height)
                let drawSize = CGSize(width: self.size.width * fillScale, height: self.size.height * fillScale)
                let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
                draw(in: CGRect(origin: origin, size: drawSize))
            } else {
                draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
