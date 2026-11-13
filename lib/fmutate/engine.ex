defmodule FMutate.Engine do
  @moduledoc """
  One running firmware engine (`libfm1engine.so` + a cartridge), owned through a Port.

  Reports to its owner as `{:engine, pid, event}`:

    * `{:spawned, os_pid}` right after the port opened
    * `{:ready, ms}` READY; `ms` from spawn to READY measured here
    * `{:status, status}` every STATUS (`FMutate.Engine.Wire.status/0`)
    * `{:flash_saved, bytes}`
    * `{:exit, reason}` the OS process is gone; this process stops right after. `reason`:
      `:stopped` (we closed the port and it exited), `:stop_killed` (it didn't exit within 3 s of the
      port closing), `:hung` (no STATUS for 1 s), `:ready_timeout` (no READY within 5 s),
      `{:signal, n}`, `{:status, n}`; the last three are kill -9s by the watchdog.
  """

  use GenServer, restart: :temporary
  require Logger

  alias FMutate.Engine.Wire

  @status_timeout_ms 1_000
  @ready_timeout_ms 5_000
  @stop_grace_ms 3_000
  @stop_poll_ms 50

  @doc """
  Options: `:owner`, `:tag` (anything the owner uses to tell engines apart), `:bin`, `:cart`,
  `:prefix`, `:flash`, `:fill` (optional target ring fill in frames), `:env` (optional `{name, value}` strings
  for the engine's environment: development knobs such as the emulator engine's `FM1_NO_JIT`).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Send commands (`t:FMutate.Engine.Wire.cmd/0`) in order."
  def commands(pid, cmds) when is_list(cmds), do: GenServer.cast(pid, {:commands, cmds})

  @doc "Close the port: the engine saves its flash and exits; an `{:exit, _}` event follows."
  def stop(pid), do: GenServer.cast(pid, :stop)

  @doc "kill -9 the OS process from outside (tests and the debug menu)."
  def kill9(pid), do: GenServer.cast(pid, :kill9)

  ## Server

  @impl true
  def init(opts) do
    args =
      [Keyword.fetch!(opts, :cart), Keyword.fetch!(opts, :prefix), Keyword.fetch!(opts, :flash)] ++
        List.wrap(opts[:fill] && Integer.to_string(opts[:fill]))

    t0 = now()
    env = for {k, v} <- Keyword.get(opts, :env, []), do: {to_charlist(k), to_charlist(v)}

    try do
      Port.open({:spawn_executable, Keyword.fetch!(opts, :bin)}, [
        :binary,
        {:packet, 2},
        :exit_status,
        args: args,
        env: env
      ])
    rescue
      e -> {:stop, {:spawn_failed, Exception.message(e)}}
    else
      port ->
        {:os_pid, os_pid} = Port.info(port, :os_pid)

        state = %{
          owner: Keyword.fetch!(opts, :owner),
          tag: Keyword.get(opts, :tag),
          port: port,
          os_pid: os_pid,
          started_at: t0,
          phase: :booting,
          kill_reason: nil,
          watchdog: arm(nil, :ready_timeout, @ready_timeout_ms),
          stop_deadline: nil
        }

        notify(state, {:spawned, os_pid})
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:commands, cmds}, %{phase: :running} = state) do
    for cmd <- cmds, do: Port.command(state.port, Wire.encode(cmd))
    {:noreply, state}
  end

  def handle_cast({:commands, _cmds}, state), do: {:noreply, state}

  def handle_cast(:stop, %{phase: phase} = state) when phase in [:booting, :running] do
    cancel(state.watchdog)
    Port.close(state.port)
    send(self(), :stop_poll)

    {:noreply,
     %{state | phase: :stopping, port: nil, watchdog: nil, stop_deadline: now() + @stop_grace_ms}}
  end

  def handle_cast(:stop, state), do: {:noreply, state}

  def handle_cast(:kill9, %{phase: phase} = state) when phase in [:booting, :running] do
    kill9_os(state.os_pid)
    {:noreply, state}
  end

  def handle_cast(:kill9, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Wire.decode(data) do
      {:ok, {:ready, _}} when state.phase == :booting ->
        notify(state, {:ready, now() - state.started_at})
        {:noreply, %{state | phase: :running, watchdog: arm(state.watchdog, :hung, @status_timeout_ms)}}

      {:ok, {:status, status}} when state.phase == :running ->
        notify(state, {:status, status})
        {:noreply, %{state | watchdog: arm(state.watchdog, :hung, @status_timeout_ms)}}

      {:ok, {:flash_saved, bytes}} ->
        notify(state, {:flash_saved, bytes})
        {:noreply, state}

      {:ok, _other} ->
        {:noreply, state}

      {:error, other} ->
        Logger.warning("engine #{inspect(state.tag)}: unknown message #{inspect(other)}")
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    cancel(state.watchdog)

    reason =
      cond do
        state.kill_reason != nil -> state.kill_reason
        status > 128 -> {:signal, status - 128}
        true -> {:status, status}
      end

    notify(state, {:exit, reason})
    {:stop, :normal, %{state | port: nil, watchdog: nil}}
  end

  def handle_info({:watchdog, ref, reason}, %{watchdog: {ref, _}} = state) do
    Logger.warning("engine #{inspect(state.tag)}: #{reason}, kill -9 #{state.os_pid}")
    kill9_os(state.os_pid)
    {:noreply, %{state | kill_reason: reason, watchdog: nil, phase: :killing}}
  end

  def handle_info({:watchdog, _ref, _reason}, state), do: {:noreply, state}

  def handle_info(:stop_poll, %{phase: :stopping} = state) do
    cond do
      not os_alive?(state.os_pid) ->
        notify(state, {:exit, :stopped})
        {:stop, :normal, state}

      now() >= state.stop_deadline ->
        kill9_os(state.os_pid)
        notify(state, {:exit, :stop_killed})
        {:stop, :normal, state}

      true ->
        Process.send_after(self(), :stop_poll, @stop_poll_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port, os_pid: os_pid}) when port != nil do
    # The owner died or we crashed: stdin EOF asks the engine to exit; make sure it does.
    Port.close(port)
    Process.sleep(200)
    if os_alive?(os_pid), do: kill9_os(os_pid)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp notify(state, event), do: send(state.owner, {:engine, self(), event})

  defp arm(previous, reason, ms) do
    cancel(previous)
    ref = make_ref()
    {ref, Process.send_after(self(), {:watchdog, ref, reason}, ms)}
  end

  defp cancel({_ref, timer}), do: Process.cancel_timer(timer)
  defp cancel(nil), do: :ok

  defp kill9_os(os_pid) do
    kill = System.find_executable("kill") || "/system/bin/kill"
    System.cmd(kill, ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  # A reaped child disappears from /proc; a zombie (state Z) is dead too.
  defp os_alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> not String.match?(stat, ~r/\) Z /)
      {:error, _} -> false
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
