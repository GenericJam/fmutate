defmodule FMutate.UpdatesTest do
  # one named server and the :app_update_client env: not async
  use ExUnit.Case, async: false

  alias FMutate.Updates

  @moduletag :tmp_dir
  # MobDeliver.state/0 off-device logs that mob's NIF isn't loaded
  @moduletag :capture_log

  defmodule FakeClient do
    @moduledoc false
    # MobAppUpdate's API, answering from the test's script (:persistent_term) and reporting each call
    def installed, do: reply(:installed, [])
    def check(opts), do: reply(:check, [opts])
    def download(release, opts), do: reply(:download, [release, opts])
    def install(path, opts), do: reply(:install, [path, opts])
    def open_install_settings, do: reply(:open_install_settings, [])

    defp reply(call, args) do
      %{pid: pid} = script = :persistent_term.get(__MODULE__)
      send(pid, {:called, call, args})

      case Map.fetch!(script, call) do
        fun when is_function(fun) -> apply(fun, args)
        value -> value
      end
    end
  end

  defmodule FakeDeliver do
    @moduledoc false
    # MobDeliver's API as FMutate.Updates uses it; a pending rollback notice is in :persistent_term until taken
    def state,
      do: %{
        running: true,
        disabled: nil,
        active: nil,
        last_check: nil,
        update_status: :ok,
        restart_required: false,
        rollback_notice: :persistent_term.get({__MODULE__, :notice}, nil)
      }

    def check(_opts), do: {:ok, :current}

    def take_rollback_notice do
      notice = :persistent_term.get({__MODULE__, :notice}, nil)
      :persistent_term.erase({__MODULE__, :notice})
      notice
    end
  end

  @release %{
    tag: "v0.1.1",
    name: "FMutate 0.1.1",
    notes: "Fixes",
    published_at: ~U[2026-11-13 12:00:00Z],
    html_url: "https://github.com/GenericJam/fmutate/releases/tag/v0.1.1",
    prerelease: false,
    version_code: 2,
    version_name: "0.1.1",
    package: "com.genericjam.fmutate",
    apk: %{name: "fmutate-0.1.1.apk", url: "https://example.test/a.apk", size: 100, sha256: "00"}
  }

  # what mob_app_update returns with no network (:httpc's reason, passed through)
  @offline {:failed_connect, [{:to_address, {~c"api.github.com", 443}}, {:inet, [:inet], :nxdomain}]}

  setup %{tmp_dir: tmp} do
    Application.put_env(:fmutate_app, :app_update_client, FakeClient)
    Application.put_env(:fmutate_app, :code_client, FakeDeliver)
    on_exit(fn -> Application.delete_env(:fmutate_app, :app_update_client) end)
    on_exit(fn -> Application.delete_env(:fmutate_app, :code_client) end)
    on_exit(fn -> :persistent_term.erase(FakeClient) end)
    on_exit(fn -> :persistent_term.erase({FakeDeliver, :notice}) end)
    Process.put(:apk_dir, tmp)
    %{state_file: Path.join(tmp, "updates.term")}
  end

  defp script(overrides) do
    dir = Process.get(:apk_dir)

    base = %{
      pid: self(),
      installed: {:ok, %{package: "com.genericjam.fmutate", version_code: 1, version_name: "0.1.0"}},
      check: {:ok, :up_to_date, %{installed: nil, latest: nil}},
      # a downloaded APK is a file in the download dir, named after the release's asset
      download: fn release, _opts ->
        path = Path.join(dir, release.apk.name)
        File.write!(path, release.apk.sha256)
        {:ok, path}
      end,
      install: :ok,
      open_install_settings: :ok
    }

    :persistent_term.put(FakeClient, Map.merge(base, overrides))
  end

  defp start(ctx, opts \\ []) do
    start_supervised!({Updates, [file: ctx.state_file, repo: "GenericJam/fmutate"] ++ opts})
    {:ok, state} = Updates.subscribe()
    state
  end

  # the state now if it already matches (a fast fake can finish before the subscription), else the next
  # {:updates, state} that does
  defp await(pattern_fun) do
    state = Updates.state()
    if pattern_fun.(state), do: state, else: await_message(pattern_fun)
  end

  defp await_message(pattern_fun) do
    receive do
      {:updates, state} -> if pattern_fun.(state), do: state, else: await_message(pattern_fun)
    after
      2_000 -> flunk("no matching {:updates, _}")
    end
  end

  describe "due?/3" do
    test "never checked, old enough, or a clock that went back" do
      now = ~U[2026-11-13 12:00:00Z]
      hour = :timer.hours(1)

      assert Updates.due?(nil, now, hour)
      assert Updates.due?(DateTime.add(now, -3600), now, hour)
      refute Updates.due?(DateTime.add(now, -3599), now, hour)
      assert Updates.due?(DateTime.add(now, 60), now, hour)
    end
  end

  test "a launch checks once, and the next launch within the interval doesn't", ctx do
    script(%{check: {:ok, :available, @release}})
    start(ctx)

    assert_receive {:called, :check, [opts]}
    assert opts[:repo] == "GenericJam/fmutate"
    state = await(&match?({:available, _}, &1.app))
    assert %DateTime{} = state.checked_at

    stop_supervised!(Updates)
    relaunched = start(ctx)
    refute_receive {:called, :check, _}, 200
    # what the last check found is still offered, without asking GitHub again
    assert relaunched.app == {:available, @release}
  end

  test "a failed check isn't remembered as a check: the next launch tries again", ctx do
    script(%{check: {:error, @offline}})
    start(ctx)
    assert_receive {:called, :check, _}
    assert await(&match?({:error, _}, &1.app)).checked_at == nil

    stop_supervised!(Updates)
    start(ctx)
    assert_receive {:called, :check, _}
  end

  test "off-device (no installed app) nothing is checked at launch", ctx do
    script(%{installed: {:error, :unsupported}})
    assert start(ctx).installed == nil
    refute_receive {:called, :check, _}, 200
  end

  test "install: download, ask for the install permission, then install without downloading again", ctx do
    script(%{
      check: {:ok, :available, @release},
      install: {:error, :install_permission_required}
    })

    start(ctx)
    await(&match?({:available, _}, &1.app))

    Updates.install()
    assert_receive {:called, :download, [@release, [notify: pid]]}
    assert pid == GenServer.whereis(Updates)
    await(&match?({:needs_permission, _}, &1.app))
    assert_receive {:called, :install, _}

    # the user allowed installs in Settings and taps Install again
    script(%{check: {:ok, :available, @release}, install: :ok})
    Updates.install()
    assert_receive {:called, :install, [path, _]}
    assert Path.basename(path) == "fmutate-0.1.1.apk"
    refute_received {:called, :download, _}
    await(&match?({:confirm, _}, &1.app))

    # Android's dialog: the installer's outcome arrives as a message
    send(Updates, {:mob_app_update, {:install, {:failure, 3, "aborted"}}})
    assert {:error, {:install_failed, 3, "aborted"}} = await(&match?({:error, _}, &1.app)).app
  end

  test "a newer release found after a download installs its own APK, not the one downloaded before", ctx do
    script(%{check: {:ok, :available, @release}, install: {:error, :install_permission_required}})
    start(ctx)
    await(&match?({:available, _}, &1.app))
    Updates.install()
    await(&match?({:needs_permission, _}, &1.app))
    assert_receive {:called, :install, _}

    newer = %{@release | version_code: 3, version_name: "0.1.2", apk: %{@release.apk | name: "fmutate-0.1.2.apk", sha256: "11"}}
    script(%{check: {:ok, :available, newer}})
    Updates.check()
    await(&match?({:available, %{version_code: 3}}, &1.app))

    Updates.install()
    assert_receive {:called, :download, [^newer, _]}
    assert_receive {:called, :install, [path, _]}
    assert Path.basename(path) == "fmutate-0.1.2.apk"
  end

  test "a downloaded APK that was deleted meanwhile is downloaded again", ctx do
    script(%{check: {:ok, :available, @release}, install: {:error, :install_permission_required}})
    start(ctx)
    await(&match?({:available, _}, &1.app))
    Updates.install()
    assert_receive {:called, :download, _}
    await(&match?({:needs_permission, _}, &1.app))
    assert_receive {:called, :install, [path, _]}

    File.rm!(path)
    Updates.install()
    assert_receive {:called, :download, [@release, _]}
  end

  test "an exception in the updater is an error on the screen; the server keeps running", ctx do
    script(%{check: fn _opts -> raise "GitHub client bug" end})
    start(ctx)
    server = GenServer.whereis(Updates)

    assert {:error, {:crashed, _}} = await(&match?({:error, _}, &1.app)).app
    assert GenServer.whereis(Updates) == server
  end

  test "download progress and a failed download are shown", ctx do
    script(%{
      check: {:ok, :available, @release},
      download: fn _release, opts ->
        send(opts[:notify], {:mob_app_update, {:progress, 40, 100}})
        {:error, {:sha256_mismatch, "00", "11"}}
      end
    })

    start(ctx)
    await(&match?({:available, _}, &1.app))
    Updates.install()

    await(&(&1.app == {:downloading, 40, 100}))
    assert await(&match?({:error, _}, &1.app)).app == {:error, {:sha256_mismatch, "00", "11"}}
  end

  test "a launch after an update says which version it replaced", ctx do
    script(%{})
    start(ctx)
    stop_supervised!(Updates)

    script(%{installed: {:ok, %{package: "com.genericjam.fmutate", version_code: 2, version_name: "0.1.1"}}})
    assert start(ctx).updated_from == 1

    stop_supervised!(Updates)
    assert start(ctx).updated_from == nil
  end

  test "once the update is installed, its release isn't offered again", ctx do
    script(%{check: {:ok, :available, @release}})
    start(ctx)
    await(&match?({:available, _}, &1.app))
    stop_supervised!(Updates)

    # the release found above is now installed; the next check (within the interval) fails
    script(%{
      installed: {:ok, %{package: "com.genericjam.fmutate", version_code: 2, version_name: "0.1.1"}},
      check: {:error, @offline}
    })
    assert start(ctx).release == nil

    Updates.check()
    await(&match?({:error, _}, &1.app))
    Updates.install()
    refute_receive {:called, :download, _}, 200
  end

  test "a release withdrawn from GitHub isn't offered any more", ctx do
    script(%{check: {:ok, :available, @release}})
    start(ctx)
    await(&match?({:available, _}, &1.app))

    script(%{check: {:error, :no_update_metadata}})
    Updates.check()
    assert await(&match?({:error, _}, &1.app)).release == nil
    Updates.install()
    refute_receive {:called, :download, _}, 200

    stop_supervised!(Updates)
    assert start(ctx).release == nil
  end

  test "Android's outcome arriving before the session's start isn't overwritten; Install works from the dialog", ctx do
    script(%{
      check: {:ok, :available, @release},
      # the installer fails on its own thread before install/2 has returned
      install: fn _path, opts ->
        send(opts[:notify], {:mob_app_update, {:install, {:failure, 1, "session failed"}}})
        :ok
      end
    })

    start(ctx)
    await(&match?({:available, _}, &1.app))
    Updates.install()
    assert_receive {:called, :install, _}
    assert {:error, {:install_failed, 1, _}} = await(&match?({:error, _}, &1.app)).app
    # the task's own result (the session started) came after it
    refute_receive {:updates, %{app: {:confirm, _}}}, 200

    # Android's dialog went away without an outcome: Install opens it again
    script(%{check: {:ok, :available, @release}, install: :ok})
    Updates.install()
    await(&match?({:confirm, _}, &1.app))
    Updates.install()
    assert_receive {:called, :install, _}
    assert_receive {:called, :install, _}
  end

  test "the updater runs when its state can't be saved", ctx do
    script(%{})
    blocker = Path.join(Path.dirname(ctx.state_file), "not_a_dir")
    File.write!(blocker, "")
    start(%{ctx | state_file: Path.join(blocker, "updates.term")})
    assert await(&(&1.app == :up_to_date))
  end

  test "the saved state has no atoms of its own: a launch reads it before mob_app_update's modules load", ctx do
    script(%{check: {:ok, :available, @release}})
    start(ctx)
    await(&match?({:available, _}, &1.app))

    # binary_to_term(bin, [:safe]) refuses the whole file for one atom that doesn't exist yet, and at launch the
    # release map's keys (:notes, :html_url, …) don't: only the atoms that always exist may be in it
    saved = ctx.state_file |> File.read!() |> :erlang.binary_to_term([:safe])
    assert saved |> atoms() |> Enum.uniq() |> Kernel.--([true, false, nil]) == []
  end

  test "a state file from before this format doesn't stop the launch: it's a first launch", ctx do
    old = %{checked_at: DateTime.utc_now(), release: @release, version_code: 1}
    File.write!(ctx.state_file, :erlang.term_to_binary(old))
    script(%{})

    assert start(ctx).release == nil
    assert_receive {:called, :check, _}
  end

  test "a rollback is shown for the launch after it, and not after the next launch", ctx do
    notice = %{rolled_back: "abfc2a1b", at: ~U[2026-11-19 22:16:15Z]}
    :persistent_term.put({FakeDeliver, :notice}, notice)
    script(%{})

    assert start(ctx).code.rollback == notice
    Updates.check()
    assert await(&(&1.app == :up_to_date)).code.rollback == notice

    stop_supervised!(Updates)
    assert start(ctx).code.rollback == nil
  end

  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_map(term), do: Enum.flat_map(term, fn {key, value} -> atoms(key) ++ atoms(value) end)
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> atoms()
  defp atoms(_term), do: []
end
