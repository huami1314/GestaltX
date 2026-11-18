// SPDX-License-Identifier: GPL-3.0-only
// Video wallpapers ported from Pocket Poster by leminlimez (GPL-3.0):
// https://github.com/leminlimez/Pocket-Poster — VideoHandler.swift, PlayerView.swift,
// LoopingPlayerUIView.swift and Resources/VideoCAML. See Licenses/Pocket-Poster-GPL-3.0.txt.
// GestaltX changes: async AVFoundation loading, orientation via CGImagePropertyOrientation,
// frame-rate/size caps so packs stay inside CustomizationFiles limits, and output that feeds
// the existing CustomizationStore import/apply pipeline instead of Pocket Poster's symlink path.
import AVFoundation
import CoreImage
import CoreTransferable
import Darwin
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A picked video copied into GestaltX's own temporary storage.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = WallpaperVideos.pickedFolder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

struct WallpaperVideo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let duration: Double
    var autoReverses = false
}

enum WallpaperVideos {
    /// Pocket Poster's default limit (VideoHandler.MaxDurationSecs).
    static let maximumDuration = 12.0
    /// Used when "Ignore 12-Second Limit" is on; keeps frame count under CustomizationFiles.tree's 4000-file cap.
    static let extendedDuration = 60.0
    static let maximumVideos = 5
    static let maximumFrameRate = 30.0
    static let maximumPixelLength: CGFloat = 2796
    static let templateName = "VideoCAML"

    static var pickedFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GX-PickedVideos", isDirectory: true)
    }

    /// Hard cap so a bad duration (or Ignore Limit + a long clip) cannot explode memory or the 4000-file tree limit.
    static let maximumFrameCount = Int(extendedDuration * maximumFrameRate) + 60

    /// Prefers the asset duration; if it is indefinite, NaN, or non-positive, falls back to the video track time range.
    static func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        if let seconds = finitePositiveSeconds(try await asset.load(.duration)) {
            return seconds
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CustomizationFailure("The video could not be read.")
        }
        if let seconds = finitePositiveSeconds(try await track.load(.timeRange).duration) {
            return seconds
        }
        throw CustomizationFailure("The video could not be read.")
    }

    static func finitePositiveSeconds(_ time: CMTime) -> Double? {
        guard time.isNumeric else { return nil }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func template() throws -> URL {
        guard let url = Bundle.main.url(forResource: templateName, withExtension: nil),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw CustomizationFailure("The video wallpaper template is missing from this build.")
        }
        return url
    }

    /// Builds a CollectionsPoster descriptor at `<descriptors>/<UUID>` from the bundled
    /// VideoCAML template: one JPEG per frame plus a CAKeyframeAnimation over `contents`.
    static func makeDescriptor(from video: URL, autoReverses: Bool, in descriptors: URL,
                               progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        let fm = FileManager.default
        let descriptor = descriptors.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.copyItem(at: try template(), to: descriptor)
        let wallpaperDir = descriptor.appendingPathComponent("versions/1/contents/9183.Custom-810w-1080h@2x~ipad.wallpaper", isDirectory: true)
        let caDir = wallpaperDir.appendingPathComponent("9183.Custom_Background-810w-1080h@2x~ipad.ca", isDirectory: true)
        let assets = caDir.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CustomizationFailure("The video could not be read.")
        }
        let (naturalSize, transform, nominalRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await Self.duration(of: video)
        let orientation = Self.orientation(for: transform)
        var size = naturalSize.applying(transform)
        size = CGSize(width: abs(size.width), height: abs(size.height))
        let scale = min(1, maximumPixelLength / max(size.width, size.height, 1))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        let sourceRate = nominalRate > 0 ? Double(nominalRate) : maximumFrameRate
        let frameRate = min(sourceRate, maximumFrameRate)
        let expected = max(1, Int((duration * frameRate).rounded(.towardZero)))
        if expected > maximumFrameCount {
            throw CustomizationFailure("The video is too long to convert into a wallpaper.")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CustomizationFailure("The video could not be read.") }

        let context = CIContext(options: [.cacheIntermediates: false])
        let interval = 1.0 / frameRate
        var nextTime = -Double.infinity
        var values = ""
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            // Drop frames above the 30 fps cap (small tolerance for timestamp jitter).
            if time.isFinite, time + 0.001 < nextTime { continue }
            nextTime = (time.isFinite ? time : 0) + interval
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            if frames >= maximumFrameCount { break }
            try autoreleasepool {
                var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
                guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
                let name = "\(frames).jpg"
                try jpeg(cgImage).write(to: assets.appendingPathComponent(name), options: .atomic)
                values += "\t\t\t<CGImage src=\"assets/\(name)\"/>\n"
                frames += 1
            }
            progress(frames, expected)
        }
        if reader.status == .failed { throw reader.error ?? CustomizationFailure("The video could not be read.") }
        guard frames > 0 else { throw CustomizationFailure("The video could not be read.") }
        let animationDuration = Double(frames) / frameRate

        let caml = """
<?xml version="1.0" encoding="UTF-8"?>

<caml xmlns="http://www.apple.com/CoreAnimation/1.0">
<CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" hidden="0" name="_FLOATING" position="\(width / 2) \(height / 2)">
<sublayers>
<CATransformLayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" allowsHitTesting="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="Chip" position="\(width / 2) \(height / 2)">
<sublayers>
<CALayer allowsEdgeAntialiasing="1" allowsGroupOpacity="1" bounds="0 0 \(width) \(height)" contentsFormat="RGBA8" cornerCurve="circular" name="CALayer1" position="\(width / 2) \(height / 2)">
<contents type="CGImage" src="assets/0.jpg"/>
<animations>
<animation type="CAKeyframeAnimation" calculationMode="linear" keyPath="contents" beginTime="1e-100" duration="\(animationDuration)" removedOnCompletion="0" repeatCount="inf" repeatDuration="0" speed="1" timeOffset="0" autoreverses="\(autoReverses ? 1 : 0)">
<values>
\(values)        </values>
        </animation>
      </animations>
    </CALayer>
  </sublayers>
    </CATransformLayer>
  </sublayers>
  <states>
    <LKState name="Locked">
  <elements/>
    </LKState>
    <LKState name="Unlock">
  <elements/>
    </LKState>
    <LKState name="Sleep">
  <elements/>
    </LKState>
  </states>
  <stateTransitions>
    <LKStateTransition fromState="*" toState="Unlock">
  <elements/>
    </LKStateTransition>
    <LKStateTransition fromState="Unlock" toState="*">
  <elements/>
    </LKStateTransition>
    <LKStateTransition fromState="*" toState="Locked">
  <elements/>
    </LKStateTransition>
    <LKStateTransition fromState="Locked" toState="*">
  <elements/>
    </LKStateTransition>
    <LKStateTransition fromState="*" toState="Sleep">
  <elements/>
    </LKStateTransition>
    <LKStateTransition fromState="Sleep" toState="*">
  <elements/>
    </LKStateTransition>
  </stateTransitions>
</CALayer>
</caml>

"""
        try Data(caml.utf8).write(to: caDir.appendingPathComponent("main.caml"), options: .atomic)
        try Data(indexXML(width: width, height: height).utf8).write(to: caDir.appendingPathComponent("index.xml"), options: .atomic)
    }

    private static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        switch (degrees + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CustomizationFailure("The video could not be read.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CustomizationFailure("The video could not be read.") }
        return data as Data
    }

    private static func indexXML(width: Int, height: Int) -> String {
        """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>assetManifest</key>
    <string>assetManifest.caml</string>
    <key>documentHeight</key>
    <real>\(height)</real>
    <key>documentResizesToView</key>
    <true/>
    <key>documentWidth</key>
    <real>\(width)</real>
    <key>dynamicGuidesEnabled</key>
    <true/>
    <key>geometryFlipped</key>
    <false/>
    <key>guidesEnabled</key>
    <true/>
    <key>interactiveMouseEventsEnabled</key>
    <true/>
    <key>interactiveShowsCursor</key>
    <true/>
    <key>interactiveTouchEventsEnabled</key>
    <false/>
    <key>loopEnd</key>
    <real>0.0</real>
    <key>loopStart</key>
    <real>0.0</real>
    <key>loopingEnabled</key>
    <false/>
    <key>multitouchDisablesMouse</key>
    <false/>
    <key>multitouchEnabled</key>
    <false/>
    <key>presentationMouseEventsEnabled</key>
    <true/>
    <key>presentationShowsCursor</key>
    <true/>
    <key>presentationTouchEventsEnabled</key>
    <false/>
    <key>rootDocument</key>
    <string>main.caml</string>
    <key>savesWindowFrame</key>
    <false/>
    <key>scalesToFitInPlayer</key>
    <true/>
    <key>showsTouches</key>
    <true/>
    <key>snappingEnabled</key>
    <true/>
    <key>timelineMarkers</key>
    <string>[(null)]</string>
    <key>touchesColor</key>
    <string>1 1 0 0.8</string>
    <key>unitsInPixelsInPlayer</key>
    <true/>
</dict>
</plist>

"""
    }
}

/// Clear Collections — Pocket Poster's "Reset Collections". Re-applying the current system
/// language through Settings' IPSettingsUtilities makes PosterBoard rebuild its collections,
/// which fixes applies that fail because a descriptor folder already exists.
enum PosterCollections {
    static func currentLanguage() -> String? {
        UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? Locale.preferredLanguages.first
    }
    static func reset(language: String) -> Bool {
        if objc_getClass("IPSettingsUtilities") == nil {
            // Normally already loaded through UIKit; load the framework that hosts it if not.
            _ = dlopen("/System/Library/PrivateFrameworks/InternationalSupport.framework/InternationalSupport", RTLD_NOW)
        }
        guard let cls = objc_getClass("IPSettingsUtilities") as? NSObject else { return false }
        let selector = NSSelectorFromString("setLanguage:")
        guard cls.responds(to: selector) else { return false }
        _ = cls.perform(selector, with: language)
        return true
    }
}

/// Pocket Poster's looping preview player.
final class LoopingPlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private let player = AVQueuePlayer()
    init(videoURL: URL) {
        super.init(frame: .zero)
        player.isMuted = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: videoURL))
        player.play()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); playerLayer.frame = bounds }
    deinit { stop() }
    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.replaceCurrentItem(with: nil)
        player.removeAllItems()
        playerLayer.player = nil
    }
}

struct LoopingVideoPlayer: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> LoopingPlayerUIView { LoopingPlayerUIView(videoURL: url) }
    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {}
    static func dismantleUIView(_ uiView: LoopingPlayerUIView, coordinator: ()) { uiView.stop() }
}
