defmodule FmutateApp.MixProject do
  use Mix.Project

  def project do
    [
      app: :fmutate_app,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    # :inets and :ssl for the library's HTTPS (FMutate.Library.HTTP): listed so a release keeps them (Mob's release
    # bundle strips OTP libs the app doesn't declare)
    [extra_applications: [:logger, :inets, :ssl, :public_key, :crypto]]
  end

  defp deps do
    [
      {:mob, "~> 0.9.29"},
      {:mob_dev, "~> 0.7.31", only: :dev, runtime: false},
      {:ecto_sqlite3, "~> 0.18"},
      # motion controls: the editor lists which motion sensors this phone has (MobSensors.list/0);
      # readings never go through the BEAM (the surface reads them, InstrumentView.kt / MotionControl.kt)
      {:mob_sensors, "~> 0.2.0"},
      # MIDI in/out, the virtual port, Bluetooth MIDI (activated in mob.exs)
      {:mob_midi, github: "GenericJam/mob_midi", ref: "052b7754dcf3c79bbe7b333a7527ff8dc5930251"},
      # keeps the app running (mediaPlayback foreground service) while a firmware plays (FMutate.Background)
      {:mob_background, github: "GenericJam/mob_background", ref: "497e915b1d4f0887fc10c9a5130655b95f0f977e"},
      # pairing sibling apps (Humdinger, Magpie) by QR code or typed code, and their TLS distribution
      # (FMutate.Pairing, the Pair screen); pure Elixir, no native code
      {:mob_pair, github: "GenericJam/mob_pair", ref: "b5bcaad5b1fe15216082da75b2553f1856794b4b"},
      # the Pair screen's QR code (pure Elixir)
      {:eqrcode, "~> 0.2.1"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end
end
