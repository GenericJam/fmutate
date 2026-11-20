# FMutate privacy policy

FMutate collects no personal data. It has no accounts or sign-in, no advertising, and no analytics, tracking or
crash-reporting service of its own. The app sends no identifier or other information about you anywhere, except
what it shares on your Wi-Fi when you pair another app. This policy describes what FMutate itself does: an app you
pair gets full control of FMutate and can do more (Paired apps, below).

- **Network requests** only fetch things the app shows or plays: the firmware list, firmware packages and
  cartridges, and the firmwares' READMEs and pictures. They go to The Firmware Hub (thefirmwarehub.com), GitHub
  (github.com and its download hosts, e.g. raw.githubusercontent.com and release-assets.githubusercontent.com) and
  GitHub Pages (genericjam.github.io). To find those hosts the app asks the public DNS resolvers of Google
  (8.8.8.8) and Cloudflare (1.1.1.1). Like any web request, each of these services sees your IP address and the
  host or file asked for, under its own privacy policy.
- **On your device**: your layouts, saved patches, settings and downloaded firmwares are stored in the app's own
  storage on your phone. They leave it only in your device's own backups (e.g. iCloud Backup), if you use them, and
  through apps you pair (below).
- **Permissions**: Bluetooth (MIDI keyboards and controllers) and the motion sensors (motion controls you bind in
  the editor) are used on the device only; FMutate itself records or sends nothing from them. FMutate doesn't use
  the camera, microphone or photo library: iOS lists those permission texts because the app's framework contains
  code for them.
- **Pairing other apps** (Android; the iOS app doesn't pair yet): pairing (menu › Pair an app) uses only your
  Wi-Fi and the phone itself, never mobile data, and FMutate sends nothing about it to any server. While the Pair
  screen is open, FMutate announces itself to the devices on your Wi-Fi (mDNS, where the phone allows it) with your
  phone's model, the firmware playing, its network address and the fingerprint of this install's FMutate
  certificate (so the other app can check it reaches this phone), and waits for apps that want to pair. An app
  you allow then connects, from another phone over an encrypted connection or from the same phone without leaving
  the device. While an app on another phone is paired, FMutate listens for it on your Wi-Fi; only paired apps get
  in.
- **Paired apps** get full control of FMutate: they can do anything FMutate can, including reading your layouts
  and patches and using its permissions and network, and they are told your phone's model and the firmware
  playing. What a paired app does with that is up to it and its own privacy policy. For each paired app, FMutate
  keeps in its own storage on your phone the name, app id, node name and device name the app gave, when it
  paired, a secret (cookie) made for it and its certificate's fingerprint; FMutate's own certificate and key are
  kept there too. None of these go into device backups. To unpair, tap Disconnect next to the app in menu › I/O;
  the app has to pair again to connect. Uninstalling FMutate deletes them all.
- **TestFlight**: if you test FMutate through Apple's TestFlight, Apple shares with the developer what TestFlight
  collects under its own terms, such as crash reports, the feedback and screenshots you choose to send, your
  device model and OS version, install and session counts, and, if you were invited by email, your name and email.

Questions: genericjam@gmail.com
