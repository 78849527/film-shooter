# 胶片机 · FilmShooter

## ⬇️ [点这里下载 IPA（最新版）](https://github.com/xuys2025/film-shooter/releases/latest/download/FilmShooter-unsigned.ipa)

> 直链：`https://github.com/xuys2025/film-shooter/releases/latest/download/FilmShooter-unsigned.ipa`
>
> iPhone 上用 Safari 点上面的链接 →「下载」→ 文件存到「文件 → 下载项」→ 长按 IPA →「共享」→ 选 AltStore / SideStore / TrollStore 安装。
> 未签名，需自行签名安装；要求 iOS 18+。每次更新代码都会自动重新编译，这个链接永远指向最新版。

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

## 安装（未签名 IPA）

1. 打开 [Releases → latest](https://github.com/xuys2025/film-shooter/releases/tag/latest)，下载 `FilmShooter-unsigned.ipa`
   （每次推送到 `main` 都会由 GitHub Actions 自动重新构建）。
2. 用你自己的签名工具安装：
   - **AltStore / SideStore**：在 My Apps 里点 “+” 选择 IPA（免费 Apple ID 签名 7 天有效）；
   - **Sideloadly**：电脑连接手机，拖入 IPA，登录 Apple ID 后 Start；
   - **TrollStore**（支持的系统版本）：直接用 TrollStore 打开 IPA 安装，永久有效；
   - 有开发者证书也可以用 `zsign`/`ios-app-signer` 重签。
3. 需要 iOS 18 及以上，iPhone XS / XR 及更新机型。首次打开会请求相机权限；冲洗好的照片会自动存入相册（可在设置里关闭）。

### 使用小贴士
- 取景器里**左右滑动**切换胶卷，或在下方胶卷罐轮播里滑动选择；点中间的胶卷罐打开**胶片库**（带实时预览，可收藏常用胶卷）。
- 点 **冲印** 调整相纸、亮度、色温/色调、颗粒、光晕、底片尺寸（135/120），以及**胶片边框**和**日期印**。
- 焦段按钮可点按切换，也可**在按钮上左右拖动**像原生相机一样连续变焦；音量键 / 相机控制按钮可以按快门。
- 底片册里可以**导入照片冲洗**，或对已拍照片**重新冲洗**换一款胶卷。

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
