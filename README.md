# 胶片机 · FilmShooter

An iOS film camera built on a **spectral film simulation engine**. Pick a film
stock, shoot, and every frame is developed and printed through a physical
model of the film's dye layers, the enlarger and the paper — grain, halation,
DIR couplers and all — instead of a LUT or a filter.

一款基于光谱胶片模拟引擎的 iOS 胶片相机：选胶卷、按快门，照片会经过胶片乳剂层、放大机与相纸的物理模型“冲洗”出来——颗粒、光晕、成色剂效应一应俱全，而不是简单的滤镜。

> **Unofficial.** This is an independent iOS port. It is not affiliated with or
> endorsed by SpektraLab.

## Features

- **Live film viewfinder** — the engine bakes a 3D colour table for the loaded
  stock; the Metal viewfinder applies it to the camera feed at 60 fps with a
  preview grain, and cross-fades when you change film.
- **25 stocks** — Kodak Portra 160/400/800 (+1/+2 push), Gold, UltraMax, Ektar,
  Fujifilm Pro 400H, X-Tra, C200, Vision3 50D/250D/200T/500T, CineStill 800T,
  Verita 200D, Velvia, Provia, Ektachrome, Kodachrome, Tri-X, HP5, T-Max, Acros.
- **Print papers** — Portra/Supra/Ultra/Premier Endura, Ektacolor Edge, Crystal
  Archive, Vision 2383/2393 print film, Ilford Multigrade for B&W.
- **Full development** of every frame in the background (RAW/ProRAW supported),
  saved to the app's contact sheet and to Photos.
- **Darkroom** — import any photo, or re-develop a frame with another film,
  paper, print exposure and enlarger filtration.
- **Film edge & date back** — print the frame on its own strip with rebate and
  edge print, or expose the date into the corner.

## Build

There is no need for a local Mac: GitHub Actions builds an **unsigned IPA**
(`.github/workflows/ios.yml`). Download it from the workflow artifacts or the
pre-release, then sign/install it with your own tool (AltStore, Sideloadly,
TrollStore, …).

Locally on a Mac with Xcode 26:

```bash
brew install xcodegen
scripts/build_engine_resources.sh   # iOS metallib (safe math) + engine resources
xcodegen generate
open FilmShooter.xcodeproj
```

## Layout

| | |
|---|---|
| `FilmShooter/` | the app: SwiftUI, AVFoundation, Metal viewfinder |
| `Engine/` | the C++20 / Metal spectral engine (from SpektraLab), its kernels and resources |
| `Licenses/` | licence texts shipped inside the app |

## Credits and licence

- Render engine and its C ABI: [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)
  by JamesQiu2005 — GPL-3.0-or-later. Three small iOS patches are marked
  `FilmShooter (iOS)` in `Engine/src`.
- Film process model, the 28 measured profiles and print LUTs:
  [spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato — CC BY-SA 4.0.
- B&W and CineStill profiles: SpektraLab product data (see `Engine/resources_product/NOTICE.md`).
- Windows port used as a second reference: [Film-Simulation](https://github.com/trouble123456/Film-Simulation) — GPL-3.0.
- metal-cpp — Apache-2.0.

This app is distributed under the **GPL-3.0-or-later** (see `LICENSE`); the
profiles and LUTs remain under CC BY-SA 4.0.
