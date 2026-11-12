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
        FMutate.Audio,
        # the firmware catalogue the instances ask (FMutate.Firmware.all/0)
        FMutate.Library
      ] ++
        for id <- instances do
          Supervisor.child_spec({FMutate.Instance, id: id}, id: {:instance, id})
        end

    # an audio restart invalidates every slot, so the instances restart with it
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
