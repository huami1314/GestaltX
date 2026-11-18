# Clear Collections and Videos

Ports Clear Collections and Videos wallpapers from [Pocket Poster](https://github.com/leminlimez/Pocket-Poster) (GPL-3.0, leminlimez).

## Clear Collections

Tools → Customization → Wallpapers → **Clear Collections** (bottom section, red).

Equivalent to Pocket Poster's Reset Collections: it re-applies the current system language so PosterBoard rebuilds its collections. Use it when Apply fails because a file already exists, or a new wallpaper does not appear. Existing wallpapers are kept.

## Videos

Tools → Customization → Wallpapers → **Videos**.

- Pick up to 5 videos, 12 seconds each (Ignore 12-Second Limit raises it to 60 seconds)
- Each row shows a muted looping preview, the duration, and a Loop Back and Forth toggle
- **Create & Apply** builds one CollectionsPoster descriptor per video from the bundled `Resources/VideoCAML` template and applies the pack through GestaltX's existing worse_query pipeline
- **Save to Wallpaper List** only creates the pack; apply it later from Wallpaper Settings

`Resources/VideoCAML` is listed under `explicitFolders` in the project so its folder hierarchy is preserved in the app bundle.
