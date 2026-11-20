import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# FmutateApp.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :fmutate_app, ecto_repos: [FmutateApp.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, FmutateApp.Repo

# Native cartridges of Hub firmwares (FMutate.Cartridges): the signed index built by
# github.com/GenericJam/fmutate-cartridges and the Ed25519 key (base64, raw 32 bytes) it and every cartridge
# are signed with. `platform` overrides the asset key (a host has none: no native builds).
config :fmutate_app, :cartridges,
  index_url: "https://genericjam.github.io/fmutate-cartridges/index.json",
  public_key: "PlTQbGPmAqukMY78jvsMLR6BBxPQAa2E3T77ofuv8h8="

# tests serve their own index; none comes from the network
if config_env() == :test, do: config(:fmutate_app, :cartridges, index_url: nil)
