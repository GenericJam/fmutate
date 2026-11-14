import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# FmutateApp.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :fmutate_app, ecto_repos: [FmutateApp.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, FmutateApp.Repo

# ── Updates (FMutate.Updates, docs/decisions/2026-11-13-updates.md) ──
#
# mob_dev evaluates this file on the build machine and ships the result inside the native build, so all of this
# is fixed per build.
version =
  for line <- File.read!(Path.expand("../android/version.properties", __DIR__)) |> String.split("\n"),
      [key, value] <- [String.split(String.trim(line), "=", parts: 2)],
      into: %{},
      do: {key, value}

# "production" for releases; a test build sets FMUTATE_UPDATE_TRACK (e.g. "updates-test") so it follows GitHub
# pre-releases and its own OTA channel, never what users get.
track = System.get_env("FMUTATE_UPDATE_TRACK", "production")

# The app (APK): a newer release of this repository on GitHub, installed only when the user taps Install.
config :fmutate_app, :updates,
  repo: "GenericJam/fmutate",
  prerelease: track != "production",
  launch_check_after: :timer.hours(12)

# The code (Elixir): signed BEAMs from GitHub Pages (the gh-pages branch's ota/ directory, written by
# tools/ota_publish.exs). The channel is per versionCode, so delivered code only ever runs on the build it was
# compiled against.
config :mob_deliver,
  # the public half of FMutate's OTA signing key (tools/ota_publish.exs; the private key never enters the repo)
  trusted_publish_key: "ed25519:XnmNVb6k58WZsSlFDsmTvWahbFDyKqosMv0Cyp4QE+I=",
  app: "com.genericjam.fmutate",
  channel: "#{track}-#{version["versionCode"]}",
  endpoint: System.get_env("FMUTATE_OTA_ENDPOINT", "https://genericjam.github.io/fmutate/ota"),
  endpoint_type: :static,
  # Android has no CA store the BEAM can read: the build machine's CAs, embedded at build time
  req_options: [
    connect_options: [
      transport_opts: [cacerts: for({:cert, der, _} <- :public_key.cacerts_get(), do: der)]
    ]
  ],
  poll_interval: :timer.hours(6),
  # a forced-update screen (never used by FMutate's publishes) would send people to the releases page
  store_url: "https://github.com/GenericJam/fmutate/releases/latest"
