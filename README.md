<p align="center">
  <img src="Assets/Meteocat.png" width="128" height="128" alt="Meteocat app icon">
</p>

<h1 align="center">Meteocat</h1>

<p align="center">
  A native weather radar viewer for Catalonia.<br>
  Built for macOS with SwiftUI and AppKit.
</p>

<p align="center">
  <strong>macOS 14+</strong> &nbsp; · &nbsp; <strong>Light & Dark</strong> &nbsp; · &nbsp; <strong>21 languages</strong>
</p>

<p align="center">
  <a href="#features">Features</a> &nbsp; · &nbsp;
  <a href="#build-and-run">Build & Run</a> &nbsp; · &nbsp;
  <a href="#data-and-attribution">Data & Attribution</a>
</p>

---

Meteocat brings the rainfall radar from the **Servei Meteorològic de Catalunya** to your Mac. Play through observations and forecasts, explore the map, and keep the viewer within reach from the Dock, menu bar, or a global keyboard shortcut.

## Features

- **Radar playback.** A chronological timeline of observations and forecasts, with smooth transitions and adjustable playback speed.
- **An interactive map.** Zoom, pan, and choose which cities appear. Add your own locations or mark a point on the map.
- **Native macOS windows.** Resize the viewer, use full screen, and restore its saved position and size.
- **Your preferred appearance.** Light, Dark, or Automatic, which follows macOS. Automatic is the default.
- **Quick access.** Choose Dock and menu bar visibility and configure a global show/hide shortcut.
- **21 languages.** Switch languages instantly in Settings or follow your system preference.

Settings always opens at General. Fixed keyboard shortcuts are listed under **Help → Keyboard Shortcuts**; source credits are available under **About Meteocat → Sources**.

## Build and run

The app runs on **macOS 14 or later**. Building requires a recent Xcode toolchain with the **macOS 26 SDK or later**, including the availability-gated Liquid Glass APIs. The package declares Swift tools 5.9 and has no remote Swift Package Manager dependencies.

```sh
swift build --product Meteocat
swift run Meteocat
```

Normal launches use live weather data. To run entirely offline with the bundled recorded data:

```sh
swift run Meteocat --fixture
```

You can also supply a compatible capture directory:

```sh
swift run Meteocat --fixture /path/to/capture
```

It must contain `active.json`, `snapshot-info.json`, and the tile images referenced by the manifest. Recorded mode uses the capture's original timestamp; it does not represent current weather.

### Package a macOS app

```sh
bash Scripts/package-app.sh
```

This creates **`Artifacts/Meteocat.app`**. The destination must not already exist. To choose a different destination:

```sh
bash Scripts/package-app.sh /path/to/Meteocat.app
```

The script builds in Release mode, verifies resources after relocating the app away from its build directory, checks all localizations and the property list, and applies an ad hoc signature. It does not launch or notarize the app.

## Keyboard shortcuts

With the radar viewer focused:

| Action | Shortcut |
| --- | --- |
| Play or pause | Space |
| Previous or next frame | ← / → |
| Show or hide cities | L |
| Refresh data | ⌘R |
| Increase / decrease / reset viewer size | ⌘+ / ⌘− / ⌘0 |
| Open Settings | ⌘, |

The global shortcut is editable in **Settings → General**.

## Development

```sh
swift test
python3 Scripts/verify-localizations.py
```

Tests use recorded fixtures and injected HTTP clients; they make no live weather requests. To check a packaged app's translations and location permission resources:

```sh
python3 Scripts/verify-localizations.py --app /path/to/Meteocat.app
```

Native window interaction, accessibility, and live weather behavior also require testing in the running app.

| Directory | Purpose |
| --- | --- |
| `Sources/MeteocatApp/` | AppKit windows, SwiftUI views, map interaction, and playback |
| `Sources/MeteocatCore/` | Metadata, raster images, projection, cache, and settings |
| `Sources/FixtureImport/` | Local fixture import, auditing, and resource verification |
| `Tests/` | Core and app behavior tests |
| `Assets/` | App icon and README image |
| `Scripts/` | Packaging, localization checks, and geography preparation |

See [the architecture notes](Design/architecture.md) for the technical contracts. Compiled apps and local development artifacts are excluded from Git; recorded test fixtures and their provenance are retained.

## Languages

Catalan, Aranese, Spanish, Basque, Galician, English, French, German, Italian, Portuguese, Dutch, Romanian, Arabic, Standard Moroccan Tamazight, Urdu, Simplified Chinese, Ukrainian, Russian, Polish, Punjabi, and Bengali.

Choose a language in **Settings → General → Language**. The change applies immediately to app text and dates, with Catalan as the fallback. Settings follows the language's writing direction; the radar keeps its geographic layout. Dates use the Gregorian calendar and the Europe/Madrid time zone, while stored frame timestamps remain UTC.

Translations still benefit from review by native speakers, particularly Tamazight.

## Data and attribution

Radar data comes from [Meteocat](https://www.meteo.cat). Map boundaries come from [ICGC](https://www.icgc.cat) under CC BY 4.0, geographic context from [Natural Earth](https://www.naturalearthdata.com), municipality data from Idescat, and terrain from [Mapzen Terrain Tiles](https://registry.opendata.aws/terrain-tiles/).

The app's **Sources** window includes the full terrain attribution. Source manifests in [`Sources/MeteocatCore/Resources/Geography/`](Sources/MeteocatCore/Resources/Geography/) record origins, hashes, and attribution. Keep these with the data. Bundled radar fixtures do not imply permission to redistribute the source data.

Settings and the radar cache are stored locally at:

```text
~/Library/Application Support/cat.marc.meteocat-native/
```

This historical directory is retained for compatibility. The current app bundle identifier is `cat.mguellsegarra.meteocat`. Location lookup runs only when requested; saved coordinates stay on your Mac and are not sent to the radar service.
