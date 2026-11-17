<p align="center">
  <img src="docs/images/wordmark.png" width="480" alt="Fuji Cookbook">
</p>

# Fuji Cookbook

A digital cookbook for your Fujifilm camera. Collect film-simulation recipes from anywhere, test
them on your own RAW files, and push them to your camera's custom slots. Free and open source, for
iPhone and iPad, with no account, ads or subscription.

<a href="https://apps.apple.com/app/apple-store/id6809646545?pt=127663689&ct=github_readme&mt=8"><img src="https://toolbox.marketingtools.apple.com/api/v2/badges/download-on-the-app-store/black/en-us" width="168" alt="Download on the App Store"></a>

[Website](https://fujicookbook.grovehouse.xyz) · [Privacy policy](docs/privacy-policy.md) ·
[Issues](https://github.com/zgrimz/fuji-cookbook/issues) ·
[Protocol reference](https://github.com/zgrimz/fujifilm-ptp-reference) ·
[Tip jar](https://ko-fi.com/zgrimshaw)

[![CI](https://github.com/zgrimz/fuji-cookbook/actions/workflows/ci.yml/badge.svg)](https://github.com/zgrimz/fuji-cookbook/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/zgrimz/fuji-cookbook)](LICENSE)

## Features

- **Find recipes anywhere.** Type one in, paste one from a blog or forum post
  ([how text is read](docs/recipe-text-import.md)), import a [`.fujirecipe`](docs/recipe-json-format.md)
  file, read one out of a SOOC JPEG, or pull what's already in your camera's custom slots.
- **Keep a library.** Group recipes into **Chapters** for a trip or a mood, favorite and search
  them, and see which cameras run each one as written. Works offline, with optional iCloud sync.
- **Push to your camera.** Send a recipe, or a whole chapter, to the custom slots you choose.
  Nothing changes on the camera until you confirm, every write is read back, and **Undo Last Push**
  puts back what was there.
- **Test Kitchen.** Pick up to three recipes and your own RAF files. Your camera does the
  developing over USB, as X RAW Studio does, so you compare the JPEGs it would have made, side by
  side or with a slider.
- **Frame & Fit.** Borders, grids and social crops, no camera needed. Share cards put a recipe's
  name and settings on one of your photos.
- **Optional AI scanning.** Off by default. With your own Anthropic or OpenAI API key, share a
  recipe screenshot to the app and it reads the settings into a new recipe for you to review.

<p>
  <img src="docs/images/recipes-light.webp" width="200" alt="Recipe library">
  <img src="docs/images/detail-light.webp" width="200" alt="A recipe's settings">
  <img src="docs/images/camera-light.webp" width="200" alt="A connected camera's custom slots">
  <img src="docs/images/kitchen-ab.webp" width="200" alt="Test Kitchen, A/B slider">
</p>

## Download

- **iPhone and iPad:** [The Fuji Cookbook on the App Store](https://apps.apple.com/app/apple-store/id6809646545?pt=127663689&ct=github_readme&mt=8),
  published by Grove House Studio LLC.
- **From source:** see [Building from source](#building-from-source).

Requires iOS 17 or later. Camera features need a supported body in **USB RAW CONV./BACKUP RESTORE**
mode and a USB data cable (USB-C to USB-C, or Apple's Lightning to USB Camera Adapter).

## Supported cameras

Fuji Cookbook writes recipes to any Fujifilm camera whose custom slots answer over USB, including
one that isn't on any list, and connects to the rest read-only. A camera the table below doesn't
vouch for earns writing at connect: its slot selector answers, every slot it accepts selects and
reads back, and the selector goes back where it was. A camera that isn't in the table is identified
by the product name, serial number and firmware it reports over USB, and isn't written to without
all three.

Until a push has been read back on a camera in the session, its card says **Read & Write · not yet
tested**, and its first push is staged: one setting is written and read back before the rest, so a
push to a camera that doesn't take writes as expected stops after that setting and puts the original
back. The first clean push clears the note until the camera next connects. The X-T50, GFX100S and
X-M5 start without it.

| How firmly writing is known | Cameras |
| --- | --- |
| Verified end to end on hardware | X-T50 |
| An owner's own write pass through the app | GFX100S, X-M5 |
| Published and community reports | X-T5, X-H2, X100VI, X-S20, X-E5, X100V, X-S10, X-T30 II, GFX100RF |
| Only by sharing a processor and protocol with a tested body | X-H2S, X-T4, X-E4, X-T30 III, GFX100, GFX 50S II |
| Not yet: written to once its slots answer at connect | GFX 50S, GFX 50R, GFX100 II, GFX100S II, and any camera not in this table |
| Not yet, and its slots aren't expected to answer; the app asks anyway | X-Pro2, X-T2, X100F, X-E3, X-H1, and the X-Trans I and II bodies |
| Read-only on a recorded failure | X-Pro3, X-T3, X-T30, X-T20 |

The last four aren't kept read-only out of caution: the protocol record holds a USB observation of
each one's custom slots failing, and the app says so when you connect one. A camera moves up the
table when someone shares its compatibility report from the app; the Camera Test (**Help improve
camera support**, at the end of the Camera tab) walks you through one.

Developing RAW files in the Test Kitchen is a separate capability with its own list: every X-Trans
III, IV and V body, the four read-only ones included, and the GFX100S. A camera that isn't on the
list doesn't get it. [docs/supported-cameras.md](docs/supported-cameras.md) has the full table; the
evidence behind it is in the protocol record's
[camera chapter](https://github.com/zgrimz/fujifilm-ptp-reference/blob/main/docs/07-cameras.md#summary).

## Before you connect a camera

The camera protocol is reverse-engineered, not published by Fujifilm, so you use the app at your
own risk, as the [license](LICENSE) says. Fujifilm has said that connecting software it hasn't
licensed to a camera voids the camera's limited warranty
([Fuji X Weekly, June 2026](https://fujixweekly.com/2026/06/08/your-cameras-warranty-might-be-voided/)).

## Privacy

Fuji Cookbook has no account and no server, and sends nothing on its own: no analytics, crash
reporting or tracking.

- Your recipes and photos stay on your device. iCloud sync, off by default, keeps your library in
  your own private iCloud database.
- AI scanning is off by default. A screenshot you scan goes straight from your device to the
  provider you chose, re-encoded without metadata such as location. Your API key stays in the
  Keychain.
- The app talks only to a Fujifilm camera connected over USB, never your device's own camera or
  microphone.
- Reports leave the device only when you share them.

The full [privacy policy](docs/privacy-policy.md), published at
[fujicookbook.grovehouse.xyz/app-privacy](https://fujicookbook.grovehouse.xyz/app-privacy/),
covers the App Store and TestFlight builds; a build made from source is the builder's responsibility.

## Building from source

### Requirements

- Xcode 26 or later; the code uses the iOS 26 SDK behind availability checks.
- No third-party dependencies, and no Apple developer account for the Simulator.

### Steps

```sh
git clone https://github.com/zgrimz/fuji-cookbook.git
cd fuji-cookbook
cp Config/Local.example.xcconfig Config/Local.xcconfig
open FujiCookbook.xcodeproj
```

Run the **FujiCookbook** scheme on any iOS Simulator. For a camera there, turn on **Settings ▸
Diagnostics ▸ Show Diagnostic Tools** and use **Connect Demo Camera**, which runs the real encoding
and safe-write code in memory.

### Configuration

Signing and identifiers live in [`Config/Base.xcconfig`](Config/Base.xcconfig); the git-ignored
`Config/Local.xcconfig` overrides it. For a device build, set `DEVELOPMENT_TEAM` there, and
`APP_IDENTIFIER_BASE` to a bundle-id prefix you own; your team must be able to provision the
**iCloud** and **App Groups** capabilities. Don't set the team in Xcode's Signing & Capabilities
pane, which writes it into the project file. To distribute a fork under your own name, see
[docs/rebranding-a-fork.md](docs/rebranding-a-fork.md).

### Tests

The tests need no hardware. Boot a Simulator, then:

```sh
xcodebuild test -scheme FujiCookbook -destination 'platform=iOS Simulator,name=iPhone 17' -collect-test-diagnostics never
```

Keep `-collect-test-diagnostics never`, or a failing run spends ten minutes on diagnostics before
it reports. Leave code signing on: with `CODE_SIGNING_ALLOWED=NO` the test host has no App Group
entitlement and crashes at launch, before any test runs.

### CloudKit schema maintenance

Initializing and deploying the shipping container's schema, for maintainers, is in
[docs/cloudkit-schema.md](docs/cloudkit-schema.md).

## Project structure

SwiftUI and SwiftData, in three targets: the app in `FujiCookbook/`, the Share Extension in
`ShareExtension/`, and `FujiCookbookTests/`. `Shared/` is compiled into both the app and the
extension, `Config/` holds signing settings, and `docs/` holds the reference docs, indexed
in [docs/README.md](docs/README.md), including
[how the app uses the camera protocol](docs/fuji-recipe-ptp-protocol.md). The Ideas recommender
in the app is unreleased, behind `FeatureFlags.ideasEnabled`.

## Contributing

Bug reports, camera reports and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
first, and open an issue to discuss anything larger than a small fix before starting it. A Camera
Test report (**Help improve camera support**, at the end of the Camera tab) from a body nobody here
owns is often worth more than code.

## Community and support

Report bugs and share camera reports in [GitHub Issues](https://github.com/zgrimz/fuji-cookbook/issues).
For support with the App Store build, or to send a report privately, email
fujicookbook@grovehouse.xyz.

Fuji Cookbook is built in spare time and will stay free. If it's been useful, please
consider [buying me a coffee](https://ko-fi.com/zgrimshaw).

## Security

Please report vulnerabilities privately. See [SECURITY.md](SECURITY.md).

## Credits

Fuji Cookbook is created and maintained by [Zachary Grimshaw](https://github.com/zgrimz). Its
camera support and its reading of recipes from photos are built on the
[Fujifilm PTP reference](https://github.com/zgrimz/fujifilm-ptp-reference)
([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)), which consolidates other people's
reverse engineering, most directly [FilmKit](https://github.com/eggricesoy/filmkit),
[rawji](https://github.com/pinpox/rawji), [libfuji](https://github.com/petabyt/libfuji),
[libgphoto2](https://github.com/gphoto/libgphoto2) and
[ExifTool](https://exiftool.org/TagNames/FujiFilm.html)'s Fujifilm MakerNote documentation, and
credits every other source in its
[SOURCES.md](https://github.com/zgrimz/fujifilm-ptp-reference/blob/HEAD/SOURCES.md). No code from
these projects is included and no third-party libraries are linked; the app's own credits are under
**Settings ▸ About ▸ Acknowledgments**.

## License

Source code, documentation and sample recipe data are copyright Zachary Grimshaw and released under
the [Apache License, Version 2.0](LICENSE); keep the [NOTICE](NOTICE) file with any distribution
and mark the files you changed, as the license requires. The Fuji Cookbook name, icon and artwork,
the Lua de Mel sample photos and the photos in this README's screenshots are not covered: Grove
House Studio LLC uses the name, icon, artwork and sample photos on the App Store with permission,
and [TRADEMARKS.md](TRADEMARKS.md) has the terms for everyone else. "Based on Fuji Cookbook", with a link back here, is appreciated.

> Fuji Cookbook is an independent app, not affiliated with, endorsed by, or sponsored by FUJIFILM
> Corporation. FUJIFILM and the camera model names used here are trademarks of their respective
> owners.
