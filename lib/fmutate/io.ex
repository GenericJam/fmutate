defmodule FMutate.IO do
  @moduledoc """
  The phone's I/O as the app sees it (HANDOFF §10): audio output devices, MIDI devices (USB, Bluetooth, other
  apps' virtual ports), the instances' own virtual ports, the Bluetooth MIDI scan. One per app (it mirrors
  Android's device lists, which aren't per instance); instances use it through `FMutate.MIDI`.

  The Kotlin side (`fmutate/FMutateIO.kt`, through `FMutate.IONif`) pushes its whole state as JSON whenever
  something changes; this process keeps it and tells subscribers `{:io, state}`:

      %{
        available: boolean,                       # false on a host: no Android I/O
        midi: [%{id, name, manufacturer, type, outputs, inputs, open}],   # type :usb | :bluetooth | :virtual
        virtual: [%{instance, name, senders, listeners}],  # the instances' own ports and who has them open
        audio: [%{id, type, name}],               # output devices; type :speaker | :headphones | :usb |
                                                  #   :bluetooth | :other
        bluetooth: %{scanning, permission, found: [%{address, name}]},
        line_in: nil                              # reserved: a phone-only "virtual line-in" (HANDOFF §1);
                                                  #   the FM-1 has no audio in, nothing produces it yet
      }

  Devices the player opened are reopened when they come back (kept by name across restarts).
  """

  use GenServer
  require Logger

  alias FMutate.{Audio, IONif, Paths}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The current state (see the module doc)."
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Subscribe the caller to `{:io, state}`; returns the current state."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "Open a MIDI device's output ports as inputs (they play the instance); remembered by name."
  def open(device_id), do: GenServer.call(__MODULE__, {:open, device_id, true})

  @doc "Close a MIDI device; forgotten for reopening."
  def close(device_id), do: GenServer.call(__MODULE__, {:open, device_id, false})

  @doc "Scan for Bluetooth MIDI devices for 10 s (asks for the Bluetooth permission first if needed)."
  def scan_bluetooth, do: GenServer.call(__MODULE__, {:command, %{op: "scan_bluetooth"}})

  @doc "Connect a Bluetooth MIDI device found by the scan; it then shows in `midi` and can be opened."
  def open_bluetooth(address),
    do: GenServer.call(__MODULE__, {:command, %{op: "open_bluetooth", address: address}})

  @doc """
  Where the sound goes now: `%{type, name}` for the device the audio stream plays to
  (`FMutate.Audio.stats/0` `device_id`), or `%{type: :unknown, name: nil}`.
  """
  def audio_route do
    %{device_id: device_id} = Audio.stats()
    route_of(state().audio, device_id)
  end

  @doc false
  def route_of(audio_devices, device_id) do
    case Enum.find(audio_devices, &(&1.id == device_id)) do
      nil -> %{type: :unknown, name: nil}
      dev -> %{type: dev.type, name: dev.name}
    end
  end

  ## Server

  @impl true
  def init(_opts) do
    saved = load()
    state = %{io: empty(), subscribers: %{}, reopen: MapSet.new(saved[:reopen] || [])}

    if IONif.loaded?() do
      :ok = IONif.subscribe_events(self())
      {:ok, refresh(state)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.io, state}

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, state.io, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  def handle_call({:open, id, open?}, _from, state) do
    with %{} = dev <- Enum.find(state.io.midi, &(&1.id == id)),
         {:ok, _} <- command(%{op: if(open?, do: "open", else: "close"), id: id}) do
      reopen =
        if open?,
          do: MapSet.put(state.reopen, dev.name),
          else: MapSet.delete(state.reopen, dev.name)

      save(reopen)
      {:reply, :ok, refresh(%{state | reopen: reopen})}
    else
      nil -> {:reply, {:error, :no_such_device}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:command, cmd}, _from, state) do
    case command(cmd) do
      {:ok, _} -> {:reply, :ok, refresh(state)}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:fm1io, :event, json}, state),
    do: {:noreply, apply_raw(state, JSON.decode!(json))}

  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp refresh(state) do
    case command(%{op: "state"}) do
      {:ok, raw} ->
        apply_raw(state, raw)

      {:error, reason} ->
        Logger.warning("io: Kotlin side not ready (#{inspect(reason)})")
        Process.send_after(self(), :refresh, 500)
        state
    end
  end

  defp apply_raw(state, raw) do
    io = decode(raw)
    if io != state.io, do: for({pid, _} <- state.subscribers, do: send(pid, {:io, io}))
    reopen(%{state | io: io})
  end

  # devices the player opened before come back opened
  defp reopen(state) do
    for dev <- state.io.midi, not dev.open, MapSet.member?(state.reopen, dev.name) do
      command(%{op: "open", id: dev.id})
    end

    state
  end

  defp command(map) do
    case IONif.call(JSON.encode!(map)) do
      {:ok, reply} ->
        case JSON.decode!(reply) do
          %{"error" => reason} -> {:error, reason}
          ok -> {:ok, ok}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # the Kotlin side's state document (decoded JSON) → the state in the module doc
  def decode(raw) do
    %{
      available: true,
      midi:
        for d <- raw["midi"] || [] do
          %{
            id: d["id"],
            name: d["name"],
            manufacturer: d["manufacturer"],
            type: kind(d["type"], [:usb, :bluetooth, :virtual]),
            outputs: d["outputs"],
            inputs: d["inputs"],
            open: d["open"] == true
          }
        end,
      virtual:
        for v <- raw["virtual"] || [] do
          %{
            instance: v["instance"],
            name: v["name"],
            senders: v["senders"] || 0,
            listeners: v["listeners"] || 0
          }
        end,
      audio:
        for a <- raw["audio"] || [] do
          %{
            id: a["id"],
            type: kind(a["type"], [:speaker, :headphones, :usb, :bluetooth, :other]),
            name: a["name"]
          }
        end,
      bluetooth: %{
        scanning: get_in(raw, ["bluetooth", "scanning"]) == true,
        permission:
          kind(
            get_in(raw, ["bluetooth", "permission"]),
            [:granted, :denied, :unknown, :unsupported],
            :unknown
          ),
        found:
          for f <- get_in(raw, ["bluetooth", "found"]) || [] do
            %{address: f["address"], name: f["name"]}
          end
      },
      line_in: nil
    }
  end

  defp kind(value, allowed, default \\ :other),
    do: Enum.find(allowed, default, &(Atom.to_string(&1) == value))

  defp empty do
    %{
      available: false,
      midi: [],
      virtual: [],
      audio: [],
      bluetooth: %{scanning: false, permission: :unsupported, found: []},
      line_in: nil
    }
  end

  defp load do
    case File.read(Paths.io_state()) do
      {:ok, bin} -> :erlang.binary_to_term(bin, [:safe])
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp save(reopen),
    do: File.write!(Paths.io_state(), :erlang.term_to_binary(%{reopen: MapSet.to_list(reopen)}))
end
