# Fuji Cookbook docs

These documents aren't all the same kind of thing, so each row says which kind it is.

| Kind | What it means for a reader |
|---|---|
| **Reference** | Describes the app as it is. If it disagrees with the code, the doc is wrong. |
| **Policy** | Text that reaches users, published outside the repository. |

| Doc | Kind | Covers |
|---|---|---|
| [recipe-json-format.md](recipe-json-format.md) | Reference | The `.fujirecipe` file format: envelope, recipe, settings payload, chapters. People already hold exported files in this shape, so it's a compatibility contract. |
| [recipe-text-import.md](recipe-text-import.md) | Reference | Import from Text: the line shapes, key spellings and value forms the reader accepts, and where text it can't place goes. |
| [fuji-recipe-ptp-protocol.md](fuji-recipe-ptp-protocol.md) | Reference | How the app uses the Fujifilm PTP vendor protocol: the push and restore sequences, what the app writes and withholds, what it says about each refusal, and how the Kitchen drives the `0xD185` RAW-conversion profile. The protocol itself is recorded once, in the published [Fujifilm PTP reference](https://github.com/zgrimz/fujifilm-ptp-reference), which this document links to for every fact. |
| [supported-cameras.md](supported-cameras.md) | Reference | Which bodies the app reads, writes and develops on, how firmly each one is known, and the Fujifilm manuals and toning sources behind what the protocol record leaves out. |
| [camera-identification.md](camera-identification.md) | Reference | How a USB product name resolves to a camera model, the confidence tiers, and how each tier and the connect's slot read decide whether the app writes. |
| [camera-compatibility-report.md](camera-compatibility-report.md) | Reference | The Camera Compatibility Report a user can share: every field, what is deliberately in it and what isn't, how the serial hash is formed, and how to read a new body's report against the bodies the protocol record knows best. |
| [rebranding-a-fork.md](rebranding-a-fork.md) | Reference | The identifiers, names, artwork and addresses to change before distributing a fork as an app. |
| [cloudkit-schema.md](cloudkit-schema.md) | Reference | Initializing the shipping CloudKit container's schema from a Debug build and deploying it to Production. |
| [recipe-compare-engine.md](recipe-compare-engine.md) | Reference | Compare Settings: the setting-by-setting comparison of two recipes, its rows, statuses and applicability rules, and what isn't built. |
| [privacy-policy.md](privacy-policy.md) | Policy | The source of the app's published privacy policy. |

[`sample-recipes.fujirecipe`](sample-recipes.fujirecipe) is a small example file in the format above;
open it on a device or in the Simulator to import three recipes.
