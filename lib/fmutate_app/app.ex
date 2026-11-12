defmodule FmutateApp.App do
  @moduledoc "Application entry point for FmutateApp."

  use Mob.App

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: FMutate.InstrumentScreen)
  end

  @impl Mob.App
  def on_start do
    # Configure BEAM's DNS path so Req / Finch / Mint / `gen_tcp:connect/3`
    # with a hostname work on iOS without per-host setup. Flips the lookup
    # chain from the iOS-broken `:native` (inet_gethost port program) path
    # to `[:file, :dns]` and seeds Google + Cloudflare as fallback
    # nameservers. Override with `nameservers:` if you need to (corporate
    # resolver, Quad9, etc.) — see `Mob.DNS.configure_pure_beam/1`.
    #
    # For hosts that need Apple's resolver (VPN-pushed DNS, mDNS,
    # captive portals, search-domain expansion) call `Mob.DNS.resolve/1`
    # for those specific hostnames here too. Both paths compose.
    Mob.DNS.configure_pure_beam()

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = FmutateApp.Repo.start_link()
    Ecto.Migrator.with_repo(FmutateApp.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    # the instrument: audio output, instance "a" and its firmware engine, MIDI and I/O, and the
    # distribution node sibling apps (and tools/rpc.exs) connect to (FMutate.Supervisor, FMutate.Dist)
    {:ok, _} = FMutate.Supervisor.start_link()

    # the root behind every screen (Mob's nav host paints the theme background) shows where a screen is inset:
    # a display cutout, hidden system bars. The flat skin's background, so it reads as the instrument's.
    Mob.Theme.set(
      background: FMutate.Style.argb(:bg),
      on_background: FMutate.Style.argb(:text),
      surface: FMutate.Style.argb(:surface),
      on_surface: FMutate.Style.argb(:text)
    )

    Mob.Screen.start_root(FMutate.InstrumentScreen)
    # (no Mob.Dist.ensure_started/1: FMutate.Dist owns distribution as fmutate_a@127.0.0.1, see protocol.md)
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil       -> Application.app_dir(:fmutate_app, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end
end
