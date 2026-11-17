# **Fuji Cookbook Privacy Policy**

**Effective date:** October 20, 2026

**Version 2.0**

Fuji Cookbook is an iOS app for organizing and importing Fujifilm recipes, testing them on your own RAW files, and pushing your favorites straight to your camera. The app is listed on the App Store as “The Fuji Cookbook” and appears on your device as “Fuji Cookbook”; this policy calls it Fuji Cookbook throughout.

The app is published by Grove House Studio LLC, a New York limited liability company ("Grove House Studio," "we," or "us"). This policy explains how information is handled when you use Fuji Cookbook and when you contact us about it.

## **1\. What this policy covers**

This policy covers Fuji Cookbook as we distribute it through the App Store and TestFlight, and your communications with us about the app.

It does **not** cover:

* **Builds made from the source code.** Fuji Cookbook's source code is published under an open-source license. Anyone who builds or distributes a version from that source, modified or not, is responsible for how that version handles information. Messages and reports you send us are covered by this policy whichever build you use.  
* **Other companies' services.** Apple (the App Store, iCloud, Photos, Files, backups, and TestFlight), the AI provider you configure, and any app, service, or person you send information to each handle it under their own terms. We note below where they come in.  
* **Anything else we do.** Grove House Studio also does work that has nothing to do with this app and does not involve information from it. This policy is about Fuji Cookbook only.

## **2\. The short version**

* **Your library stays on your device.** There is no account to create, and we run no server that receives your recipes or photos. The app itself contains no advertising, tracking, analytics, or crash-reporting service. Apple's own crash reporting and TestFlight analytics are separate services (Section 10).  
* **Information leaves your device only when you initiate it:** by turning on AI features, which send images to the AI provider you set; turning on iCloud sync, which copies your library to your own iCloud account; or saving or sharing files and reports yourself. Whoever receives it—the AI provider, Apple, or the app or person you share with—handles it under their own terms.  
* **We receive only the information you choose to send us,** or that Apple makes available to us as a developer under your Apple settings.  
* **We do not sell personal information** or share it for targeted advertising.

## **3\. Information on your device**

The app stores its information on your device. This includes:

* **Your library:** recipes (names, notes, tags, camera settings, and any credit to the recipe's creator), chapters, sample photos you add, and photos the app develops with your camera, along with the details saved with them.  
* **Settings and preferences,** including the cameras you have marked as yours.  
* **Diagnostic information:** app logs, a report of the most recent camera connection, Camera Test records, recovery copies of your camera's original settings, and screenshots waiting to be scanned. Logs are designed to record operational details—outcomes, errors, camera models, and technical identifiers—rather than recipe contents, file names, or photo metadata.  
* **Credentials,** in the iOS Keychain: AI API keys you enter, and a random value the app uses to code camera serial numbers (Section 9).

Like other iOS apps, the app's local data can be included in device and iCloud backups under your Apple settings, and some of its working files may be visible in the Files app. Keychain items use a device-only protection setting intended to keep them from syncing through iCloud Keychain or transferring through a backup restore. They can remain on the device after you delete the app (Section 11).

## **4\. Permissions the app asks for**

* **Camera.** iOS uses its Camera permission for external cameras connected over USB. The app asks for it so it can communicate with your Fujifilm camera. It does not use your device's built-in camera or microphone.  
* **Photos.** The app asks for permission to add photos to your photo library: the developed and edited photos you choose to save. When you pick a photo, the iOS picker gives the app only the photos you select. The picker shares only the JPEG of a photo you shot as RAW+JPEG, so if you choose to develop the RAW of such a photo, the app asks for access to your photos. You can give it access to only the photos you select (Limited Access) or to all of them (Full Access). It uses the photos you share, such as their thumbnails and dates, to show them for choosing, and reads the RAW file only of those you choose to develop, which it sends only to your camera (Section 5). You can change this permission at any time in Settings.

The app requests no other permissions. It does not use location, contacts, or Bluetooth. When iCloud sync is turned on, background activity is limited to receiving silent CloudKit notifications to fetch library updates from your iCloud account.

## **5\. Your camera**

When you connect a Fujifilm camera and choose to connect to it, the app communicates with it directly over USB, only while it is connected. The app reads what the camera reports about itself (model, firmware, serial number, and capabilities) and the recipes stored in its custom slots. It writes to those slots when you push a recipe, and it sends a RAW file to the camera and retrieves the result when you develop one.

The app does not import the photos already on your camera's memory card. During development it reads the camera's file list only to find the file it just created, retrieves that file, and removes it from the camera.

The camera's serial number is not stored, logged, or shared in readable form. The app keeps only a coded version, described in Section 9\.

## **6\. Optional AI features**

AI features are off by default. They work with your own account and API key with an AI provider, currently Anthropic or OpenAI. To use them, you turn them on in Settings, confirm the in-app disclosure, and enter your API key.

**What is sent.** Recipe scanning sends the screenshot you select, with instructions for reading the recipe, directly from your device to your provider. The app re-encodes the image first and does not copy the original file's metadata, such as EXIF or location, into it. Anything visible in the image is visible to the AI provider.

Setting up or refreshing AI features also contacts your provider to list the models available to your account. Those requests carry your API key but no images or library content. Like any internet request, these requests carry standard connection information such as your IP address.

**Where scanning happens.** In the app, and from other apps through the share extension, which uses the provider settings and key stored in Fuji Cookbook. If a scan from the share extension cannot complete, you can save the screenshot for later. Saved screenshots stay on your device; once AI features are configured, the app retries them automatically when you open or return to it. Saved screenshots are removed automatically after about a month (sooner if many are waiting), and you can clear them at any time with Clear Diagnostics.

**Your AI provider, account, and API key.** You obtain your own API key, enter into your own agreement with the provider, and use the provider through your own account. The provider handles your requests under the terms, data-handling policies, retention practices, model-training settings, and rate limits that apply to that account. Grove House Studio does not act as the provider's customer for your requests and does not engage the provider to process them on our behalf. We do not receive the images you scan, the provider's responses, or your API key.

Review the provider's current API information before scanning:

* [Anthropic: API and data retention](https://platform.claude.com/docs/en/manage-claude/api-and-data-retention)  
* [OpenAI: API data controls](https://developers.openai.com/api/docs/guides/your-data)

If a link no longer resolves, consult the provider's current privacy policy and API documentation. Only scan images you are comfortable sending to your provider.

**Your keys.** API keys are stored in the iOS Keychain with a device-only protection setting. Each key is sent only to the provider it belongs to. Turning AI features off stops new requests but keeps your keys and model choices. You can delete your stored keys from the device at any time in Settings → Delete API Keys. Neither undoes requests already made; to revoke a key completely, also revoke it in your provider account.

If we add AI features that send different information, we will describe them here and in the app before they become available.

## **7\. Optional iCloud sync and Apple backups**

iCloud sync is off by default. If you turn it on, the app uses Apple's CloudKit service to sync your library (recipes, chapters, sample photos, and developed photos, with the details and metadata saved with them) through your own iCloud account. This information is kept in your private iCloud database. We cannot access, retrieve, or delete it. The change takes effect when you restart the app.

API keys, AI settings, and the app's diagnostic information are not part of sync.

Turning sync off stops this device from syncing. It does not delete what is already in iCloud or on another device. To delete the app's data from iCloud, use Apple's iCloud storage management.

When iCloud sync is enabled, the app uses silent CloudKit notifications to briefly wake in the background and fetch library updates from your iCloud account. These notifications require no notification permissions, display no alerts, and send no data to Grove House Studio.

Apple's device and iCloud backups are separate from sync. They may include the app's local data, including diagnostics, under your Apple settings, even when sync is off. Apple's terms govern both sync and backups.

## **8\. Files you save, export, or share**

Exports and shares are copies you create and place yourself. The app does not send them anywhere.

* **Recipe exports** contain the recipes and chapters you choose and sample photos if you include them.  
* **Camera backups** contain your camera's custom-slot settings and details identifying the camera.  
* **Developed and framed photos** can be saved to Photos or shared.  
* **Share cards** place a recipe's name, settings, and credit on a photo you pick.

**Photo metadata.** Photos can carry information beyond the image, such as camera settings, captions, and location. Photos the app saves or shares may keep metadata from their source. A photo developed by your camera keeps what the camera embedded, which can include the location where the photo was taken. A Frame & Fit photo made from a single original can carry that original's metadata. The share sheet or the destination may alter or remove metadata. Check a photo's metadata before sharing it if it may contain something you do not want to disclose.

## **9\. Reports and messages you send us**

The app never sends reports or logs on its own. You can share a problem report, Camera Test results, feedback, or diagnostic output through the iOS share sheet or by copying text. You see the report before you share it, and you choose where it goes: to us by email, to a public issue on the app's open-source project if our contributor guidance points you there, or anywhere else. Anything you post publicly is public. The app may keep a local note of whether a share completed; that does not tell us anything.

**What a report can contain,** depending on the report:

* App and device information: version and build, distribution channel, iOS version, device model, sync status (including error details if sync failed), and summary counts for your library.  
* Camera information: model, firmware, technical identifiers, a coded serial number, and what the camera reports about itself.  
* Your camera's custom-slot names and settings, and the results of reading, writing, or restoring them.  
* Technical details of RAW development and other camera checks. These do not include the photos or their file names.  
* Communication traces, errors, connection problems, and the status of iOS permissions.  
* Your answers and notes from a Camera Test.  
* Recent app logs.

Send Feedback attaches only your message and basic app and device details.

Reports are not designed to include your photos or recipe library. Slot names, notes, and anything else you typed appear as you wrote them. Camera details come from the report saved the last time you connected, so they can appear even when no camera is plugged in. Review a report before sharing it.

**Coded serial numbers.** Reports represent your camera's serial number as a shortened hash keyed to a random value created on your device. That value stays on your device and is not included in reports, logs, or exports, so the hash cannot be checked against a serial number without it. The same camera produces the same hash on the same device and a different hash on another device.

The hash is pseudonymous rather than anonymous: it lets us recognize reports about the same camera from the same device, which is all we use it for.

**What we do with what you send.** When you email us, we receive your email address, your message, and any attachments. We use them to respond, investigate problems, keep the app secure and reliable, and recognize recurring defects. With your permission, we may also publish a report you send us, or an edited version of it, in the app's public open-source project so that other users benefit from it; anything published stays in the project's public history. Our mailbox is operated for us by a third-party email provider.

## **10\. Information from Apple**

Fuji Cookbook has no analytics or crash-reporting service of its own. Apple may separately make crash reports and aggregated usage information available to developers under your Apple settings. The app does not send this; Apple generates it through its own services. You can manage it in iOS Settings → Privacy & Security → Analytics & Improvements.

If you use a TestFlight build, Apple may also make beta information available to us through App Store Connect, such as your invitation email address, feedback and screenshots you submit, crash reports, and app, build, and device details.

We use Apple-provided information only to investigate problems, respond to feedback, and improve the app. Apple holds it under its own terms and retention practices. If we save a separate copy, Section 12 applies.

## **11\. Your controls**

* **AI features switch.** Off stops all AI requests, including those from the share extension and saved screenshots. Keys and model choices are kept.  
* **Delete API Keys.** Removes stored provider keys and model choices from the device.  
* **Clear Diagnostics.** Removes logs, saved screenshots, Camera Test records, and the recovery copies of your camera's original settings. The app offers to export recovery copies first. It keeps a small amount of camera information the app needs, such as what it wrote to your camera's slots, so it can notice if a slot has since changed. It does not touch your library and cannot recall reports you have already shared.  
* **iCloud Sync switch.** Off stops syncing from this device after a restart. Section 7 explains how to delete iCloud data.  
* **Deleting content.** Removes it from your library, and from iCloud if sync is on.  
* **Deleting the app.** Removes its local data. Keychain items, meaning API keys and the serial-coding value, can survive deletion. Use Delete API Keys before you delete the app, or reinstall it to do so. There is no in-app control for the serial-coding value; it never leaves your device and does not identify you or your camera on its own.

## **12\. Retention**

We keep support messages and reports you send us for as long as needed to handle your request, maintain the app, and recognize recurring problems, and no longer than three years from receipt. If we save a copy of an Apple crash report or TestFlight feedback, we keep it no longer than one year. We may keep particular information longer where the law requires it or where it is reasonably needed to establish, exercise, or defend a legal claim. Residual copies may remain for a time in our service providers' routine backups.

You can ask us to delete information sooner (Section 13). Information you control (your library, diagnostics, keys, iCloud data, and your provider's records) is managed through the controls in Section 11, Apple's settings, and your provider account.

## **13\. Your rights**

Contacting us is voluntary. You do not need to give us personal information to use the app.

Depending on where you live, you may have the right to access, correct, delete, or receive a copy of your personal information; to restrict or object to its processing; to withdraw consent; and to complain to a data protection authority (for example, your local authority in the EEA or the Information Commissioner's Office in the UK). We will not treat you differently for exercising a right.

To make a request, email [fujicookbook@grovehouse.xyz](mailto:fujicookbook@grovehouse.xyz), preferably from the address you used to contact us. We may ask for information reasonably needed to verify the request, and an authorized agent may act for you where the law allows. We can act on information we hold: support correspondence and copies of reports or Apple information we have saved. We cannot reach your device, your private iCloud database, or your AI provider's records.

We respond within the time the applicable law requires. If we deny a request, we will explain why and, where the law provides an appeal, how to appeal. We do not use personal information for automated decisions that have legal or similarly significant effects on you.

**Where the GDPR or UK GDPR applies,** Grove House Studio is the controller of the personal information it processes itself: support correspondence, reports you send us, and Apple developer information we access. We rely on performance of a contract or steps taken at your request (to provide support you asked for); our legitimate interests in responding to you, administering beta testing, diagnosing problems, and keeping the app secure and reliable, which we consider proportionate because the information is limited and reaches us only through you or your Apple settings; and compliance with legal obligations. AI requests and iCloud sync are transfers you direct through your own accounts with the provider and Apple. We do not receive or process that information.

## **14\. Legal disclosures, security, and international processing**

We may disclose information we hold if required by law or legal process, or if we reasonably believe disclosure is necessary to investigate suspected fraud, enforce our terms, or protect the rights, property, or safety of Grove House Studio, our users, or the public. Where permitted and practical, we will tell you about a legal demand for your information unless we believe notice would create a risk of harm. This does not extend to information we cannot access.

The app's own network requests—to your AI provider, and to iCloud through Apple's frameworks—are designed to use encrypted (HTTPS) connections. API keys use the device-only Keychain setting described above. Everything else relies on your device's security and iOS data protection. No method of storage or transmission is perfectly secure, and we cannot guarantee the security of your device or of any service you send information to. Links in the app open in your browser, where the website's own terms apply.

Grove House Studio is in the United States. Information you send us may be processed in the United States by us and our service providers. Apple's and your AI provider's processing locations depend on their services and your accounts. Your AI requests and iCloud library do not pass through us.

## **15\. Children**

Fuji Cookbook is a photography tool and is not directed to children under 13\. We do not knowingly collect personal information from children under 13, or under a higher age where the law sets one. If you believe a child has sent us personal information, contact us so we can delete it.

## **16\. Changes to this policy**

This policy describes the app as of its effective date. Features may be added, changed, or removed over time. When a change affects how the app handles information, we will update this policy, change its effective date and version, and note material changes in the app's release notes. Where a change requires your permission, we will ask before the new practice takes effect.

## **17\. Contact**

Grove House Studio LLC  
[fujicookbook@grovehouse.xyz](mailto:fujicookbook@grovehouse.xyz)

The current version of this policy is published at [https\://fujicookbook.grovehouse.xyz/app-privacy](https://fujicookbook.grovehouse.xyz/app-privacy/).
