defmodule FMutate.Engine do
  @moduledoc """
  One running firmware engine (`libfm1engine.so` + a cartridge, or `libfm1emu.so` + a package), owned through a
  Port: its own OS process. On iOS, where an app can't start processes, the same engine runs on a thread of the
  app behind `FMutate.EngineNif`, which carries the same messages (`bin: :inproc`).

  Reports to its owner as `{:engine, pid, event}`:

    * `{:spawned, os_pid}` right after the port opened (`nil` in-process)
    * `{:ready, ms}` READY; `ms` from spawn to READY measured here
    * `{:status, status}` every STATUS (`FMutate.Engine.Wire.status/0`)
    * `{:flash_saved, bytes}`
    * `{:exit, reason}` the OS process (the thread) is gone; this process stops right after. `reason`:
      `:stopped` (we closed the port and it exited), `:stop_killed` (it didn't exit within 3 s of the
      port closing), `:hung` (no STATUS for 1 s), `:ready_timeout` (no READY within 5 s),
      `{:signal, n}`, `{:status, n}`, `{:start_failed, reason}` (in-process: `:busy` when the cartridge's
      previous engine still hadn't ended after 4 s of trying again, `:hung` when a hung firmware loop holds
      it; see `FMutate.EngineNif.start/7`); `:hung` and `:ready_timeout` are kill -9s by the watchdog.
  """

  use GenServer, restart: :temporary
  require Logger

  alias FMutate.Engine.Wire
  alias FMutate.EngineNif

  @status_timeout_ms 1_000
  @ready_timeout_ms 5_000
  @stop_grace_ms 3_000
  @stop_poll_ms 50
  # in-process, a cartridge whose previous engine is still ending (a switch back to it, a restart): try again
  # this often, for this long (its stop grace, and the time a hung loop takes to be seen)
  @busy_retry_ms 50
  @busy_wait_ms 4_000

  @doc """
  Options: `:owner`, `:tag` (anything the owner uses to tell engines apart), `:bin` (the executable, or
  `:inproc` for `FMutate.EngineNif`), `:cart` (the cartridge or package; in-process a cartridge id), `:backend`
  (`:native` or `:emu`, needed in-process), `:prefix`, `:flash`, `:fill` (optional target ring fill in frames),
  `:env` (optional `{name, value}` strings for the engine's environment: development knobs such as the emulator
  engine's `FM1_NO_JIT`; in-process only `FM1_MHZ` applies).
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Send commands (`t:FMutate.Engine.Wire.cmd/0`) in order."
  def commands(pid, cmds) when is_list(cmds), do: GenServer.cast(pid, {:commands, cmds})

  @doc "Close the port: the engine saves its flash and exits; an `{:exit, _}` event follows."
  def stop(pid), do: GenServer.cast(pid, :stop)

  @doc "kill -9 the OS process from outside (tests and the debug menu); in-process, abandon its thread."
  def kill9(pid), do: GenServer.cast(pid, :kill9)

  ## Server

  @impl true
  def init(opts) do
    t0 = now()

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      tag: Keyword.get(opts, :tag),
      port: nil,
      handle: nil,
      os_pid: nil,
      started_at: t0,
      phase: :booting,
      kill_reason: nil,
      watchdog: nil,
      stop_deadline: nil,
      opts: opts
    }

    case {opts[:bin], open(opts)} do
      {_bin, {:ok, port, handle, os_pid}} ->
        {:ok, opened(state, port, handle, os_pid)}

      {:inproc, {:error, :busy}} ->
        Process.send_after(self(), :retry_start, @busy_retry_ms)
        {:ok, %{state | phase: :waiting, stop_deadline: t0 + @busy_wait_ms}}

      {:inproc, {:error, reason}} ->
        # (as a process that died at once: the owner's restart and quarantine rules see it)
        {:ok, %{state | phase: :failed}, {:continue, {:start_failed, reason}}}

      {_bin, {:error, reason}} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  defp opened(state, port, handle, os_pid) do
    notify(state, {:spawned, os_pid})

    %{
      state
      | port: port,
        handle: handle,
        os_pid: os_pid,
        phase: :booting,
        started_at: now(),
        stop_deadline: nil,
        watchdog: arm(nil, :ready_timeout, @ready_timeout_ms)
    }
  end

  @impl true
  def handle_continue({:start_failed, reason}, state) do
    notify(state, {:exit, {:start_failed, reason}})
    {:stop, :normal, state}
  end

  defp open(opts) do
    fill = opts[:fill]
    env = Keyword.get(opts, :env, [])

    case Keyword.fetch!(opts, :bin) do
      :inproc ->
        ref = make_ref()

        mhz =
          with {_, v} <- List.keyfind(env, "FM1_MHZ", 0),
               {n, ""} <- Integer.parse(v),
               do: n,
               else: (_ -> 0)

        case EngineNif.start(
               ref,
               Keyword.fetch!(opts, :backend),
               Keyword.fetch!(opts, :cart),
               Keyword.fetch!(opts, :prefix),
               Keyword.fetch!(opts, :flash),
               fill || 0,
               mhz
             ) do
          {:ok, handle} -> {:ok, ref, handle, nil}
          {:error, reason} -> {:error, reason}
        end

      bin ->
        args =
          [
            Keyword.fetch!(opts, :cart),
            Keyword.fetch!(opts, :prefix),
            Keyword.fetch!(opts, :flash)
          ] ++
            List.wrap(fill && Integer.to_string(fill))

        env = for {k, v} <- env, do: {to_charlist(k), to_charlist(v)}

        try do
          Port.open({:spawn_executable, bin}, [
            :binary,
            {:packet, 2},
            :exit_status,
            args: args,
            env: env
          ])
        rescue
          e -> {:error, Exception.message(e)}
        else
          port ->
            {:os_pid, os_pid} = Port.info(port, :os_pid)
            {:ok, port, nil, os_pid}
        end
    end
  end

  @impl true
  def handle_cast({:commands, cmds}, %{phase: :running} = state) do
    for cmd <- cmds, do: command(state, Wire.encode(cmd))
    {:noreply, state}
  end

  def handle_cast({:commands, _cmds}, state), do: {:noreply, state}

  def handle_cast(:stop, %{phase: phase, handle: nil} = state)
      when phase in [:booting, :running] do
    cancel(state.watchdog)
    Port.close(state.port)
    send(self(), :stop_poll)

    {:noreply,
     %{state | phase: :stopping, port: nil, watchdog: nil, stop_deadline: now() + @stop_grace_ms}}
  end

  # in-process: the thread's own exit status says when it has saved its flash and ended
  def handle_cast(:stop, %{phase: phase} = state) when phase in [:booting, :running] do
    cancel(state.watchdog)
    EngineNif.close(state.handle)

    {:noreply,
     %{
       state
       | phase: :stopping,
         watchdog: arm(nil, :stop_killed, @stop_grace_ms),
         stop_deadline: now() + @stop_grace_ms
     }}
  end

  # in-process, still waiting for the cartridge: nothing started, nothing to save
  def handle_cast(:stop, %{phase: :waiting} = state) do
    notify(state, {:exit, :stopped})
    {:stop, :normal, state}
  end

  def handle_cast(:stop, state), do: {:noreply, state}

  def handle_cast(:kill9, %{phase: phase} = state) when phase in [:booting, :running] do
    kill(state)
    {:noreply, state}
  end

  def handle_cast(:kill9, state), do: {:noreply, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Wire.decode(data) do
      {:ok, {:ready, _}} when state.phase == :booting ->
        notify(state, {:ready, now() - state.started_at})

        {:noreply,
         %{state | phase: :running, watchdog: arm(state.watchdog, :hung, @status_timeout_ms)}}

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
        state.phase == :stopping -> :stopped
        state.kill_reason != nil -> state.kill_reason
        status > 128 -> {:signal, status - 128}
        true -> {:status, status}
      end

    notify(state, {:exit, reason})
    {:stop, :normal, %{state | port: nil, handle: nil, watchdog: nil}}
  end

  # in-process, stopping: no exit within the grace (its firmware never parks again): abandon the thread
  def handle_info({:watchdog, ref, :stop_killed}, %{watchdog: {ref, _}, phase: :stopping} = state) do
    Logger.warning(
      "engine #{inspect(state.tag)}: didn't stop within #{@stop_grace_ms} ms, abandoned"
    )

    EngineNif.kill(state.handle)
    notify(state, {:exit, :stop_killed})
    {:stop, :normal, %{state | port: nil, handle: nil, watchdog: nil}}
  end

  def handle_info({:watchdog, ref, reason}, %{watchdog: {ref, _}} = state) do
    Logger.warning(
      "engine #{inspect(state.tag)}: #{reason}, kill -9 #{state.os_pid || "(in-process)"}"
    )

    kill(state)
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

  # in-process: the cartridge's previous engine was still ending; try again
  def handle_info(:retry_start, %{phase: :waiting} = state) do
    case open(state.opts) do
      {:ok, port, handle, os_pid} ->
        {:noreply, opened(state, port, handle, os_pid)}

      {:error, :busy} ->
        if now() < state.stop_deadline do
          Process.send_after(self(), :retry_start, @busy_retry_ms)
          {:noreply, state}
        else
          {:noreply, %{state | phase: :failed}, {:continue, {:start_failed, :busy}}}
        end

      {:error, reason} ->
        {:noreply, %{state | phase: :failed}, {:continue, {:start_failed, reason}}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{handle: handle}) when handle != nil do
    # the owner died or we crashed: as a closed port, the engine saves its flash and ends
    EngineNif.close(handle)
  end

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

  defp command(%{handle: nil, port: port}, bin), do: Port.command(port, bin)
  defp command(%{handle: handle}, bin), do: EngineNif.command(handle, bin)

  defp kill(%{handle: nil, os_pid: os_pid}), do: kill9_os(os_pid)
  defp kill(%{handle: handle}), do: EngineNif.kill(handle)

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

  # A reaped child disappears from /proc; a zombie (state Z) is dead too. Without /proc (macOS): kill -0.
  defp os_alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        not String.match?(stat, ~r/\) Z /)

      {:error, _} ->
        not File.dir?("/proc/self") and
          match?(
            {_, 0},
            System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
          )
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
