defmodule FMutate.CrashMarker do
  @moduledoc """
  Native firmware crashes when engines run in the app (iOS): a firmware that crashes there ends the app, with no
  process to lose instead (docs/decisions/2026-11-13-ios-port.md §1). On a fatal signal in a firmware's threads,
  `c_src/fm1host.c` writes that cartridge's id to a marker file; `arm/0`, once per launch before any engine starts,
  takes what the previous launch left there and arms the marker for this one. The instances count what it took
  (`crashed/0`) as failures of those firmwares (`FMutate.Instance`).

  Elsewhere (Android, the host) an engine is an OS process whose crash the app survives, and nothing is armed.
  """

  alias FMutate.{EngineNif, Paths}

  @key {__MODULE__, :crashed}

  @doc """
  Read and remove the previous launch's marker, then arm it (in-process engines only). Once per launch: later
  calls (a restarted supervisor) keep what the first one took.
  """
  def arm(path \\ Paths.crash_marker()) do
    if :persistent_term.get(@key, nil) == nil do
      crashed = take(path)
      if Paths.inproc?(), do: :ok = EngineNif.crash_marker(path)
      :persistent_term.put(@key, crashed)
    end

    :ok
  end

  @doc "The firmwares (cartridge ids) that ended the previous launch of the app, as `arm/0` found them."
  def crashed, do: :persistent_term.get(@key, [])

  @doc false
  # the ids in a marker file, removed (one line each; a crash writes one)
  def take(path) do
    ids =
      case File.read(path) do
        {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.uniq()
        {:error, _} -> []
      end

    File.rm(path)
    ids
  end
end
