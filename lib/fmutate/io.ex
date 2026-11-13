defmodule FMutate.IO do
  @moduledoc """
  The phone's I/O as the app sees it (HANDOFF §10): audio output devices, MIDI devices (USB, Bluetooth, other
  apps' virtual ports), the instances' own virtual ports, the Bluetooth MIDI scan. One per app (it mirrors
  Android's device lists, which aren't per instance); instances use it through `FMutate.MIDI`.

  MIDI devices come from the mob_midi plugin (`MobMidi`): this process lists them (and re-lists on its
  hot-plug events), scans for and connects Bluetooth MIDI devices, and asks the instance that plays them
  (the *player*, `FMutate.MIDI` of instance `"a"`, `attach_player/1`) to open their inputs, so incoming
  bytes go straight to it. The player reports what opened and its virtual port's clients back here. Audio
  outputs come from the Kotlin side (`fmutate/FMutateIO.kt`, through `FMutate.IONif`). Subscribers get
  `{:io, state}`:

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

  @list_retry_ms 500

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
  def scan_bluetooth, do: GenServer.call(__MODULE__, :scan_bluetooth)

  @doc "Connect a Bluetooth MIDI device found by the scan; it then shows in `midi` and can be opened."
  def open_bluetooth(address), do: GenServer.call(__MODULE__, {:open_bluetooth, address})

  @doc """
  The calling process plays the devices the player opens: this process casts it `{:open_device, id,
  ports}` and expects `{:device_opened, id}` / `{:device_failed, id, reason}` back.
  """
  def attach_player(pid), do: GenServer.call(__MODULE__, {:attach_player, pid})

  @doc "An instance's virtual port: how many apps send into it and listen to it."
  def virtual_status(instance, name, senders, listeners),
    do: GenServer.cast(__MODULE__, {:virtual, instance, name, senders, listeners})

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

    state = %{
      io: empty(),
      available: IONif.loaded?(),
      subscribers: %{},
      reopen: MapSet.new(saved[:reopen] || []),
      devices: [],
      open: MapSet.new(),
      opening: MapSet.new(),
      player: nil,
      virtual: %{},
      audio: [],
      bluetooth: %{
        scanning: false,
        permission:
          if(MobMidi.Platform.bluetooth_central?(MobMidi.Platform.current()),
            do: :unknown,
            else: :unsupported
          ),
        found: []
      }
    }

    MobMidi.list_devices(nil)

    if state.available do
      :ok = IONif.subscribe_events(self())
      {:ok, refresh_audio(state)}
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

  def handle_call({:attach_player, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, reopen(%{state | player: pid, open: MapSet.new(), opening: MapSet.new()})}
  end

  def handle_call({:open, id, true}, _from, state) do
    case Enum.find(state.devices, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :no_such_device}, state}

      _dev when state.player == nil ->
        {:reply, {:error, :no_player}, state}

      dev ->
        reopen = MapSet.put(state.reopen, dev.name)
        save(reopen)
        {:reply, :ok, %{state | reopen: reopen} |> open_device(dev) |> publish()}
    end
  end

  def handle_call({:open, id, false}, _from, state) do
    case Enum.find(state.devices, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :no_such_device}, state}

      dev ->
        MobMidi.close(nil, id)
        reopen = MapSet.delete(state.reopen, dev.name)
        save(reopen)

        state = %{
          state
          | reopen: reopen,
            open: MapSet.delete(state.open, id),
            opening: MapSet.delete(state.opening, id)
        }

        {:reply, :ok, publish(state)}
    end
  end

  def handle_call(:scan_bluetooth, _from, state) do
    case MobMidi.scan_bluetooth(nil) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, :ok, state}
    end
  end

  def handle_call({:open_bluetooth, address}, _from, state) do
    case MobMidi.connect_bluetooth(nil, address) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:virtual, instance, name, senders, listeners}, state) do
    v = %{instance: instance, name: name, senders: senders, listeners: listeners}
    {:noreply, publish(%{state | virtual: Map.put(state.virtual, instance, v)})}
  end

  @impl true
  def handle_info({:midi, :devices, payload}, state) do
    devices =
      for d <- MobMidi.parse_devices(payload), not d.own do
        %{
          id: d.id,
          name: d.name,
          manufacturer: d.manufacturer,
          type: if(d.type == :other, do: :virtual, else: d.type),
          outputs: d.input_ports,
          inputs: d.output_ports
        }
      end

    ids = MapSet.new(devices, & &1.id)

    state = %{
      state
      | devices: devices,
        open: MapSet.intersection(state.open, ids),
        opening: MapSet.intersection(state.opening, ids)
    }

    {:noreply, state |> reopen() |> publish()}
  end

  def handle_info({:midi, event, _}, state) when event in [:device_added, :device_removed] do
    MobMidi.list_devices(nil)
    {:noreply, state}
  end

  def handle_info({:midi, :connected, _}, state) do
    MobMidi.list_devices(nil)
    {:noreply, state}
  end

  def handle_info({:midi, :error, %{op: :list_devices, reason: reason}}, state) do
    Logger.warning("io: MIDI devices not listed yet (#{reason})")
    Process.send_after(self(), :list_devices, @list_retry_ms)
    {:noreply, state}
  end

  def handle_info({:midi, :error, %{op: :scan_bluetooth, reason: :permission_denied}}, state) do
    Mob.Permissions.request(nil, :midi_bluetooth)
    {:noreply, state}
  end

  def handle_info({:midi, :error, %{op: :scan_bluetooth, reason: :unsupported}}, state),
    do: {:noreply, put_bluetooth(state, permission: :unsupported, scanning: false)}

  def handle_info({:midi, :error, %{op: op, reason: reason}}, state) do
    Logger.warning("io: MIDI #{op} failed (#{reason})")
    {:noreply, state}
  end

  def handle_info({:permission, :midi_bluetooth, :granted}, state) do
    MobMidi.scan_bluetooth(nil)
    {:noreply, put_bluetooth(state, permission: :granted)}
  end

  def handle_info({:permission, :midi_bluetooth, :denied}, state),
    do: {:noreply, put_bluetooth(state, permission: :denied)}

  def handle_info({:midi, :bluetooth_scan, :started}, state),
    do: {:noreply, put_bluetooth(state, scanning: true, permission: :granted)}

  def handle_info({:midi, :bluetooth_scan, :stopped}, state),
    do: {:noreply, put_bluetooth(state, scanning: false)}

  def handle_info({:midi, :bluetooth_device, %{address: address} = found}, state) do
    found = [found | Enum.reject(state.bluetooth.found, &(&1.address == address))]
    {:noreply, put_bluetooth(state, found: found)}
  end

  def handle_info({:device_opened, id}, state) do
    state = %{state | open: MapSet.put(state.open, id), opening: MapSet.delete(state.opening, id)}
    {:noreply, publish(state)}
  end

  def handle_info({:device_failed, id, reason}, state) do
    Logger.warning("io: MIDI device #{id} didn't open (#{reason})")
    {:noreply, %{state | opening: MapSet.delete(state.opening, id)}}
  end

  def handle_info(:list_devices, state) do
    MobMidi.list_devices(nil)
    {:noreply, state}
  end

  def handle_info({:fm1io, :event, json}, state),
    do: {:noreply, publish(%{state | audio: decode_audio(JSON.decode!(json))})}

  def handle_info(:refresh_audio, state), do: {:noreply, refresh_audio(state)}

  def handle_info({:DOWN, _ref, :process, pid, _}, %{player: pid} = state),
    do: {:noreply, publish(%{state | player: nil, open: MapSet.new(), opening: MapSet.new()})}

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp open_device(%{player: nil} = state, _dev), do: state

  defp open_device(state, dev) do
    if MapSet.member?(state.open, dev.id) or MapSet.member?(state.opening, dev.id) do
      state
    else
      GenServer.cast(state.player, {:open_device, dev.id, dev.outputs})
      %{state | opening: MapSet.put(state.opening, dev.id)}
    end
  end

  # devices the player opened before come back opened
  defp reopen(state) do
    state.devices
    |> Enum.filter(&MapSet.member?(state.reopen, &1.name))
    |> Enum.reduce(state, &open_device(&2, &1))
  end

  defp put_bluetooth(state, changes),
    do: publish(%{state | bluetooth: Map.merge(state.bluetooth, Map.new(changes))})

  defp publish(state) do
    io = %{
      available: state.available,
      midi: for(d <- state.devices, do: Map.put(d, :open, MapSet.member?(state.open, d.id))),
      virtual: state.virtual |> Map.values() |> Enum.sort_by(& &1.instance),
      audio: state.audio,
      bluetooth: state.bluetooth,
      line_in: nil
    }

    if io != state.io, do: for({pid, _} <- state.subscribers, do: send(pid, {:io, io}))
    %{state | io: io}
  end

  defp refresh_audio(state) do
    case command(%{op: "state"}) do
      {:ok, raw} ->
        publish(%{state | audio: decode_audio(raw)})

      {:error, reason} ->
        Logger.warning("io: Kotlin side not ready (#{inspect(reason)})")
        Process.send_after(self(), :refresh_audio, 500)
        state
    end
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

  # the Kotlin side's audio document (decoded JSON) → `audio` in the module doc
  defp decode_audio(raw) do
    for a <- raw["audio"] || [] do
      %{
        id: a["id"],
        type: kind(a["type"], [:speaker, :headphones, :usb, :bluetooth, :other]),
        name: a["name"]
      }
    end
  end

  defp kind(value, allowed),
    do: Enum.find(allowed, :other, &(Atom.to_string(&1) == value))

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
