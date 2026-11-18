// SPDX-License-Identifier: GPL-3.0-only
// Videos screen ported from Pocket Poster's VideoView by leminlimez (GPL-3.0):
// https://github.com/leminlimez/Pocket-Poster. See Licenses/Pocket-Poster-GPL-3.0.txt.
import PhotosUI
import SwiftUI

struct WallpaperVideosView: View {
    @ObservedObject var model: CustomizationModel
    @AppStorage("GestaltX.Wallpapers.ignoreVideoDurationLimit") private var ignoreDurationLimit = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var loading = false
    @State private var confirmApply = false
    @State private var presentationOwner = UUID()

    private var remaining: Int { max(0, WallpaperVideos.maximumVideos - model.videos.count) }
    private var limit: Int { Int(ignoreDurationLimit ? WallpaperVideos.extendedDuration : WallpaperVideos.maximumDuration) }

    var body: some View {
        List {
            Section {
                Text(L("Pick short videos to turn into a live wallpaper. Each video becomes one wallpaper in a new pack, added to the wallpaper gallery without replacing your existing wallpapers."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($model.videos) { $video in
                    HStack(spacing: 14) {
                        LoopingVideoPlayer(url: video.url)
                            .frame(width: 70, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 8) {
                            Label(String(format: L("%.1f s"), video.duration), systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle(isOn: $video.autoReverses) {
                                Label(L("Loop Back and Forth"), systemImage: "arrow.left.arrow.right")
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 5)
                }
                .onDelete { model.removeVideos(at: $0) }

                if remaining > 0 {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: remaining, matching: .videos, photoLibrary: .shared()) {
                        Label(L("Choose Videos"), systemImage: "video.badge.plus")
                    }
                    .disabled(loading)
                }
                if loading {
                    HStack { ProgressView(); Text(L("Importing…")).foregroundStyle(.secondary) }
                }
            } header: {
                Text(String(format: L("Videos (%d/%d)"), model.videos.count, WallpaperVideos.maximumVideos))
            } footer: {
                Text(String(format: L("Up to %d videos, %d seconds or less each. Swipe a video to remove it."), WallpaperVideos.maximumVideos, limit))
            }

            Section {
                Toggle(L("Ignore 12-Second Limit"), isOn: $ignoreDurationLimit)
            } footer: {
                Text(String(format: L("Allows videos up to %d seconds. Longer videos create much larger wallpapers and may fail to load in PosterBoard."), Int(WallpaperVideos.extendedDuration)))
            }

            Section {
                Button { confirmApply = true } label: {
                    Label(L("Create & Apply"), systemImage: "checkmark.circle.fill")
                }
                .disabled(model.videos.isEmpty || model.busy || loading)
                Button { Task { await model.createVideoWallpaper(apply: false) } } label: {
                    Label(L("Save to Wallpaper List"), systemImage: "tray.and.arrow.down")
                }
                .disabled(model.videos.isEmpty || model.busy || loading)
            } footer: {
                if let progress = model.videoProgress {
                    Text(progress)
                } else {
                    Text(L("Videos are converted into frame-by-frame wallpapers (up to 30 fps). If a wallpaper does not appear, use Clear Collections in Wallpaper Settings."))
                }
            }
        }
        .navigationTitle(L("Videos"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.busy)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if model.busy || loading { ProgressView() } } }
        .onAppear { model.videosScreenOpen = true }
        .onDisappear {
            model.videosScreenOpen = false
            model.setPresenting(false, owner: presentationOwner)
        }
        .onChange(of: confirmApply || model.message != nil, initial: true) { _, presenting in
            model.setPresenting(presenting, owner: presentationOwner)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await load(items) }
        }
        .alert(L("Apply these changes?"), isPresented: $confirmApply) {
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Apply")) { Task { await model.createVideoWallpaper(apply: true) } }
        } message: { Text(L("This adds new wallpapers without replacing your existing ones.")) }
        .alert(L("GestaltX"), isPresented: Binding(get: { model.message != nil && model.videosScreenOpen }, set: { if !$0 { model.message = nil } })) {
            Button(L("OK"), role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        loading = true; defer { loading = false }
        var problems: [String] = []
        for item in items {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    problems.append(L("The video could not be read.")); continue
                }
                if let problem = await model.addVideo(movie.url, ignoreLimit: ignoreDurationLimit) { problems.append(problem) }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty {
            model.message = L("Failed to Import Video") + "\n\n" + Array(Set(problems)).joined(separator: "\n")
        }
    }
}
