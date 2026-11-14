defmodule FMutate.Supervisor do
  @moduledoc """
  The instrument's processes: the registry, the audio output, and the instances (v1: `"a"`). Started
  from `FmutateApp.App.on_start/0` (Mob apps have no OTP application callback).
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    instances = Keyword.get(opts, :instances, ["a"])

    children =
      [
        {Registry, keys: :unique, name: FMutate.Registry},
        # I/O (device-level): Android's MIDI/audio devices, and distribution for sibling apps (node named
        # after the first instance)
        FMutate.IO,
        {FMutate.Dist, instance: hd(instances)},
        FMutate.Audio,
        # the firmware catalogue the instances ask (FMutate.Firmware.all/0)
        FMutate.Library
      ] ++
        Enum.flat_map(instances, fn id ->
          [
            Supervisor.child_spec({FMutate.Instance, id: id}, id: {:instance, id}),
            # per instance I/O: MIDI in/out and the facade sibling apps call (protocol.md)
            Supervisor.child_spec({FMutate.MIDI, id: id}, id: {:midi, id}),
            Supervisor.child_spec({FMutate.Remote, id: id, register_local: id == hd(instances)}, id: {:remote, id})
          ]
        end) ++
        [
          # keeps the app running in the background while a firmware plays (mob_background)
          {FMutate.Background, instances: instances},
          # app and code updates (last: under rest_for_one its restart touches nothing else)
          FMutate.Updates
        ]

    # an audio restart invalidates every slot, so the instances restart with it
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
