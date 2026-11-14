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

  setup %{tmp_dir: tmp} do
    Application.put_env(:fmutate_app, :app_update_client, FakeClient)
    on_exit(fn -> Application.delete_env(:fmutate_app, :app_update_client) end)
    on_exit(fn -> :persistent_term.erase(FakeClient) end)
    %{state_file: Path.join(tmp, "updates.term")}
  end

  defp script(overrides) do
    base = %{
      pid: self(),
      installed: {:ok, %{package: "com.genericjam.fmutate", version_code: 1, version_name: "0.1.0"}},
      check: {:ok, :up_to_date, %{installed: nil, latest: nil}},
      download: {:ok, "/tmp/fmutate.apk"},
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
    # what the last check found is kept for the screen
    assert relaunched.release == @release
  end

  test "a failed check isn't remembered as a check: the next launch tries again", ctx do
    script(%{check: {:error, {:transport, :nxdomain}}})
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

    # the user allowed installs in Settings and taps Install again
    script(%{check: {:ok, :available, @release}, install: :ok})
    Updates.install()
    assert_receive {:called, :install, ["/tmp/fmutate.apk", _]}
    refute_received {:called, :download, _}
    await(&match?({:confirm, _}, &1.app))

    # Android's dialog: the installer's outcome arrives as a message
    send(Updates, {:mob_app_update, {:install, {:failure, 3, "aborted"}}})
    assert {:error, {:install_failed, 3, "aborted"}} = await(&match?({:error, _}, &1.app)).app
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
end
