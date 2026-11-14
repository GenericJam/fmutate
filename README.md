# FMutate updates (GitHub Pages)

This branch is served by GitHub Pages at <https://genericjam.github.io/fmutate/>. It holds FMutate's
over-the-air Elixir code updates, nothing else; the app itself is released as APKs on the repository's
[Releases](https://github.com/GenericJam/fmutate/releases).

`ota/` is written by `tools/release.exs` on the `master` branch (docs/decisions/2026-11-13-updates.md):

    ota/manifests/com.genericjam.fmutate/<track>-<versionCode>.json   signed manifest per build
    ota/beam/<sha256>                                                 the BEAM files manifests name

A build only reads its own channel (`production-<versionCode>`), and only installs a manifest signed with
FMutate's OTA key. Don't edit these files by hand: publish with `tools/release.exs ota --push`.
