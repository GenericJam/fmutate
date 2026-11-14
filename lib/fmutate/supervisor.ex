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
        # apps paired on the Pair screen: their cookies and pinned certificates (mob_pair; FMutate.Dist follows
        # it). FMutate.Dist owns the default cookie. Release builds keep an allow list (paired names added as
        # they pair; FMutate.Dist adds sibling-cookie names), so no other name gets past OTP's handshake to
        # make an atom; development builds (mob_dev's cookie) leave it open for their tools.
        {MobPair.Pairings,
         default_cookie: :keep,
         allow_list: if(FMutate.Dist.dev_build?(), do: false, else: :auto),
         store:
           {MobPair.Pairings.FileStore,
            path: Path.join(FMutate.Paths.dist_dir(), "pairings.json")}},
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
          # the Pair screen's endpoint and the TLS front for paired apps on other phones; last, so its
          # restarts don't restart the instrument
          {FMutate.Pairing, instance: hd(instances)}
        ]

    # an audio restart invalidates every slot, so the instances restart with it
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
