defmodule FMutate.Sounds do
  @moduledoc """
  Sounds: a firmware's whole save memory (every patch and setting it keeps in its flash), as opaque bytes, saved
  under a name, loaded back, exported and imported. Only the same synth takes one back: the same firmware id
  (`hub:<id>` is another synth than `<id>`) on the same backend. The bytes are read and replaced with no engine
  running, through `FMutate.Instance.snapshot/1` and `restore/5`, so loading one restarts the firmware for a moment.

  A sound is a `fmutate.sound/1` JSON file:

      {"format": "fmutate.sound/1", "name": "Pads", "saved_at": "2026-11-22T18:04:12Z",
       "firmware": {"id": "obervave", "name": "OberVave", "version": "3.3.2", "backend": "native",
                    "commit": "792535d…"},
       "payload": {"encoding": "base64", "bytes": 147456, "sha256": "…", "data": "…"}}

  kept in `sounds/<id>/<UTC time>-<name>.sound.json` (`FMutate.Paths.sounds/1`); saving always adds a file.
  `commit` is there when the build says. The payload is the engine's flash file as it is: for a native
  cartridge its save blobs one after the other (its length is the cartridge's), for a package in the emulator
  engine the sectors that differ from the package's own flash (records of a little-endian u32 sector offset and
  4096 bytes, `docs/engine_protocol.md`).

  Loading checks the sound against the running synth (`check/2`): the firmware id and backend must be the same,
  the payload's length and SHA-256 must match it, an emulator payload must be whole records at distinct
  4096-aligned offsets inside the 1 MiB flash, a native one as long as the synth's current file. Made with
  another version of the same synth: `{:other_version, made, have}`, for the player to decide. Before replacing,
  the bytes it replaces are kept (`Paths.sound_undo/2`): `undo/1` puts them back and keeps what it replaced, so a
  second undo redoes.
  """

  require Logger

  alias FMutate.{Firmware, Instance, Paths}

  @format "fmutate.sound/1"
  @record 4100
  @sector 4096
  @emu_flash 1024 * 1024
  # a whole emulated flash in base64 with its JSON is ~1.4 MB: anything much bigger isn't a sound
  @max_file 4_000_000

  @typedoc "A sound read and checked: `firmware` has `id`, `name`, `version`, `backend` and optionally `commit`."
  @type sound :: %{
          name: String.t(),
          saved_at: String.t(),
          firmware: %{id: String.t(), name: String.t(), version: String.t(), backend: :native | :emu},
          bytes: binary,
          path: String.t() | nil
        }

  @typedoc "What runs: the firmware, its backend and the length of its flash file (nil when there is none)."
  @type running :: %{firmware: Firmware.t(), backend: :native | :emu, flash_size: non_neg_integer | nil}

  ## Saving and the list

  @doc """
  Save the running firmware's save memory as a new sound named `name` (the firmware restarts for a moment).
  `{:ok, sound}` or `{:error, text}`.
  """
  @spec save(String.t(), String.t()) :: {:ok, sound} | {:error, String.t()}
  def save(instance, name) do
    with {:ok, snap} <- Instance.snapshot(instance) |> instance_answer(),
         %Firmware{} = fw <- snap.firmware || {:error, "The running firmware isn't known."} do
      sound = %{
        name: clean_name(name, fw.name),
        saved_at: now(),
        firmware: %{id: fw.id, name: fw.name, version: fw.version, backend: snap.backend, commit: commit(fw)},
        bytes: snap.bytes,
        path: nil
      }

      add(sound)
    end
  end

  @doc "The saved sounds of a firmware, newest first. Files that aren't sounds are left out (and logged)."
  @spec list(String.t()) :: [sound]
  def list(firmware_id) do
    dir = Paths.sounds(firmware_id)

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".sound.json"))
    |> Enum.flat_map(fn file ->
      path = Path.join(dir, file)

      case read(path) do
        {:ok, sound} ->
          [sound]

        {:error, why} ->
          Logger.warning("sounds: #{path} left out: #{why}")
          []
      end
    end)
    |> Enum.sort_by(&{&1.saved_at, &1.path}, :desc)
  end

  @doc "Read a saved or picked sound file (`parse/1`)."
  @spec read(String.t()) :: {:ok, sound} | {:error, String.t()}
  def read(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file ->
        {:error, "It's too big to be a sound."}

      {:ok, _} ->
        with {:ok, json} <- File.read(path) |> file_answer(),
             {:ok, sound} <- parse(json),
             do: {:ok, %{sound | path: path}}

      {:error, reason} ->
        {:error, "Couldn't read it (#{:file.format_error(reason)})."}
    end
  end

  @doc "Delete a saved sound."
  @spec delete(sound) :: :ok
  def delete(%{path: path}) do
    _ = File.rm(path)
    :ok
  end

  @doc """
  Copy a saved sound into `dir` (the cache, for the share sheet) under a file name made from its name and its
  synth's, and return that path.
  """
  @spec export(sound, String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def export(%{path: path} = sound, dir) do
    out = Path.join(dir, "#{slug(sound.name)}-#{slug(sound.firmware.name)}.sound.json")

    with :ok <- File.mkdir_p(dir) |> file_answer(),
         {:ok, _} <- File.copy(path, out) |> file_answer(),
         do: {:ok, out}
  end

  @doc """
  Add a picked sound file to the running synth's list (it isn't loaded). Refused, saying why, when it isn't a sound
  or is for another synth or backend; one made with another version is added and shows as such.
  """
  @spec import(String.t(), String.t()) :: {:ok, sound} | {:error, String.t()}
  def import(path, instance) do
    with {:ok, sound} <- read(path),
         {:ok, running} <- running(instance),
         :ok <- importable(check(sound, running)),
         do: add(%{sound | path: nil})
  end

  defp importable({:other_version, _made, _have}), do: :ok
  defp importable(answer), do: answer

  ## Loading

  @doc "What runs on `instance` now, for `check/2`."
  @spec running(String.t()) :: {:ok, running} | {:error, String.t()}
  def running(instance) do
    view = Instance.view(instance)

    with :running <- view.phase,
         %Firmware{} = fw <- Firmware.get(view.firmware),
         %{backend: backend} <- Firmware.runnable(fw.id) do
      size =
        case File.stat(Paths.flash(instance, fw.id, backend)) do
          {:ok, %{size: size}} -> size
          _ -> nil
        end

      {:ok, %{firmware: fw, backend: backend, flash_size: size}}
    else
      _ -> {:error, "The synth isn't running."}
    end
  end

  @doc """
  Whether `sound` can go into the running synth: `:ok`, `{:other_version, made, have}` (the same synth and backend,
  another version: the player decides) or `{:error, text}` saying why not.
  """
  @spec check(sound, running) :: :ok | {:other_version, String.t(), String.t()} | {:error, String.t()}
  def check(%{firmware: sf} = sound, %{firmware: fw, backend: backend} = running) do
    cond do
      sf.id != fw.id ->
        {:error, "This sound is for #{sf.name}, not #{fw.name}."}

      sf.backend != backend ->
        {:error, "This sound is #{sf.name}'s #{backend_name(sf.backend)}; here it runs #{backend_name(backend)}."}

      backend == :native and running.flash_size not in [nil, byte_size(sound.bytes)] ->
        {:error, "Its memory is #{byte_size(sound.bytes)} bytes; #{fw.name}'s here is #{running.flash_size}."}

      sf.version != fw.version ->
        {:other_version, sf.version, fw.version}

      true ->
        :ok
    end
  end

  @doc """
  Load a checked sound into the running synth (it restarts for a moment). What it replaces is kept for `undo/1`.
  """
  @spec load(String.t(), sound) :: :ok | {:error, String.t()}
  def load(instance, %{firmware: %{id: id, backend: backend}, bytes: bytes}) do
    version = current_version(id)

    keep = fn old ->
      if backend == :native and old != nil and byte_size(old) != byte_size(bytes),
        do: {:error, "Its memory is #{byte_size(bytes)} bytes; the synth's is #{byte_size(old)}."},
        else: keep_undo(instance, id, backend, version, old)
    end

    Instance.restore(instance, id, backend, bytes, keep) |> instance_answer() |> ok()
  end

  @doc "Whether the last load into `firmware_id` on `backend` can be undone (or redone) on `instance`."
  @spec undo?(String.t(), String.t(), :native | :emu) :: boolean
  def undo?(instance, firmware_id, backend) do
    match?({:ok, %{backend: ^backend}}, undo_meta(instance, firmware_id))
  end

  @doc """
  Put back what the last load (or undo) replaced in the running synth, keeping what this replaces: a second undo
  redoes.
  """
  @spec undo(String.t()) :: :ok | {:error, String.t()}
  def undo(instance) do
    with {:ok, %{firmware: fw, backend: backend}} <- running(instance),
         {:ok, %{backend: ^backend}} <- undo_meta(instance, fw.id),
         {:ok, bytes} <- File.read(Paths.sound_undo(instance, fw.id) <> ".bin") |> file_answer() do
      keep = &keep_undo(instance, fw.id, backend, fw.version, &1)
      Instance.restore(instance, fw.id, backend, bytes, keep) |> instance_answer() |> ok()
    else
      {:error, _} = error -> error
      _ -> {:error, "There's no load to undo."}
    end
  end

  # the bytes about to be replaced, and whose they are, as the undo (nil: there was no file, which is what an
  # empty one gives the engines too)
  defp keep_undo(instance, id, backend, version, old) do
    base = Paths.sound_undo(instance, id)
    meta = JSON.encode!(%{firmware: id, backend: backend, version: version, kept_at: now()})

    with :ok <- atomic_write(base <> ".bin", old || <<>>),
         :ok <- atomic_write(base <> ".json", meta) do
      :ok
    else
      {:error, reason} -> {:error, "Couldn't keep the current memory for Undo (#{:file.format_error(reason)})."}
    end
  end

  defp undo_meta(instance, id) do
    base = Paths.sound_undo(instance, id)

    with true <- File.exists?(base <> ".bin"),
         {:ok, json} <- File.read(base <> ".json"),
         {:ok, %{"firmware" => ^id, "backend" => b} = meta} when b in ["native", "emu"] <- JSON.decode(json) do
      {:ok, %{backend: String.to_existing_atom(b), version: meta["version"]}}
    else
      _ -> :none
    end
  end

  defp current_version(id) do
    case Firmware.get(id) do
      %Firmware{version: v} -> v
      nil -> nil
    end
  end

  ## The file format

  @doc "Decode and check a `fmutate.sound/1` document: `{:ok, sound}` (with `path: nil`) or `{:error, text}`."
  @spec parse(binary) :: {:ok, sound} | {:error, String.t()}
  def parse(json) when byte_size(json) > @max_file, do: {:error, "It's too big to be a sound."}

  def parse(json) do
    with {:ok, %{"format" => @format} = doc} <- decode(json),
         {:ok, fw} <- parse_firmware(doc["firmware"]),
         {:ok, bytes} <- parse_payload(doc["payload"]),
         :ok <- check_bytes(fw.backend, bytes) do
      {:ok,
       %{
         name: clean_name(doc["name"], "Sound"),
         saved_at: parse_time(doc["saved_at"]) || now(),
         firmware: fw,
         bytes: bytes,
         path: nil
       }}
    else
      {:ok, %{"format" => other}} when is_binary(other) -> {:error, "It's a #{other} file, not a sound."}
      {:ok, _} -> {:error, "It isn't an FMutate sound."}
      {:error, _} = error -> error
    end
  end

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, "It isn't an FMutate sound (not JSON)."}
    end
  end

  defp parse_firmware(%{"id" => id, "version" => version, "backend" => backend} = fw)
       when is_binary(id) and id != "" and is_binary(version) and backend in ["native", "emu"] do
    name = if is_binary(fw["name"]) and fw["name"] != "", do: fw["name"], else: id
    commit = if is_binary(fw["commit"]), do: fw["commit"]
    {:ok, %{id: id, name: name, version: version, backend: String.to_existing_atom(backend), commit: commit}}
  end

  defp parse_firmware(_), do: {:error, "It doesn't say which synth it is for."}

  defp parse_payload(%{"encoding" => "base64", "bytes" => n, "sha256" => sha, "data" => data})
       when is_integer(n) and n >= 0 and is_binary(sha) and is_binary(data) do
    with {:ok, bytes} <- Base.decode64(data) |> or_error("Its memory isn't readable (bad base64)."),
         true <- byte_size(bytes) == n || {:error, "Its memory is #{byte_size(bytes)} bytes, not the #{n} it says."},
         true <- sha256(bytes) == String.downcase(sha) || {:error, "Its memory is damaged (its SHA-256 differs)."} do
      {:ok, bytes}
    end
  end

  defp parse_payload(_), do: {:error, "It has no memory in it (no base64 payload)."}

  # the emulator engine's file: whole records, each a distinct 4096-aligned sector inside the 1 MiB flash (the
  # engine ignores a malformed file and boots the package's own flash, which would look like a reset)
  defp check_bytes(:emu, bytes) when rem(byte_size(bytes), @record) != 0,
    do: {:error, "Its memory isn't whole emulator flash records."}

  defp check_bytes(:emu, bytes) do
    offsets = for <<offset::little-32, _::binary-size(@sector) <- bytes>>, do: offset

    cond do
      Enum.any?(offsets, &(rem(&1, @sector) != 0 or &1 + @sector > @emu_flash)) ->
        {:error, "Its memory has a sector outside the emulated flash."}

      length(Enum.uniq(offsets)) != length(offsets) ->
        {:error, "Its memory has the same sector twice."}

      true ->
        :ok
    end
  end

  defp check_bytes(:native, _bytes), do: :ok

  defp encode(sound) do
    fw = sound.firmware

    firmware =
      %{id: fw.id, name: fw.name, version: fw.version, backend: fw.backend}
      |> then(&if fw[:commit], do: Map.put(&1, :commit, fw.commit), else: &1)

    JSON.encode!(%{
      format: @format,
      name: sound.name,
      saved_at: sound.saved_at,
      firmware: firmware,
      payload: %{
        encoding: "base64",
        bytes: byte_size(sound.bytes),
        sha256: sha256(sound.bytes),
        data: Base.encode64(sound.bytes)
      }
    })
  end

  # always a new file: `<UTC time>-<name>.sound.json`, `-2`, `-3`… when that is taken
  defp add(sound) do
    dir = Paths.sounds(sound.firmware.id)
    stamp = sound.saved_at |> String.replace(["-", ":"], "")
    base = "#{stamp}-#{slug(sound.name)}"

    path =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(fn
        1 -> Path.join(dir, base <> ".sound.json")
        n -> Path.join(dir, "#{base}-#{n}.sound.json")
      end)
      |> Enum.find(&(not File.exists?(&1)))

    case atomic_write(path, encode(sound)) do
      :ok -> {:ok, %{sound | path: path}}
      {:error, reason} -> {:error, "Couldn't save it (#{:file.format_error(reason)})."}
    end
  end

  defp atomic_write(path, data) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, data, [:sync]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  ## Helpers

  @doc "A sound's time as the player reads it: local time, to the minute (`2026-11-22 18:04`)."
  @spec local_time(String.t()) :: String.t()
  def local_time(saved_at) do
    case DateTime.from_iso8601(saved_at) do
      {:ok, dt, _} ->
        dt
        |> DateTime.to_unix()
        |> :calendar.system_time_to_local_time(:second)
        |> NaiveDateTime.from_erl!()
        |> Calendar.strftime("%Y-%m-%d %H:%M")

      _ ->
        saved_at
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp parse_time(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # the build's commit when it says: a Hub native build's index entry, or a bundled cartridge's pinned source
  defp commit(%Firmware{native: %{commit: c}}) when is_binary(c), do: c
  defp commit(%Firmware{source: :bundled, ref: ref}) when is_binary(ref), do: ref
  defp commit(_fw), do: nil

  defp clean_name(name, default) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, 60) do
      "" -> default
      name -> name
    end
  end

  defp clean_name(_name, default), do: default

  defp slug(name) do
    case name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-") |> String.trim("-") |> String.slice(0, 40) do
      "" -> "sound"
      slug -> slug
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp backend_name(:native), do: "native build"
  defp backend_name(:emu), do: "package in the emulator"

  defp or_error({:ok, _} = ok, _text), do: ok
  defp or_error(_, text), do: {:error, text}

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  defp file_answer(:ok), do: :ok
  defp file_answer({:ok, _} = ok), do: ok
  defp file_answer({:error, reason}), do: {:error, "File error: #{:file.format_error(reason)}."}

  # FMutate.Instance's refusals, for the player
  defp instance_answer({:ok, _} = ok), do: ok
  defp instance_answer({:error, reason}), do: {:error, explain(reason)}

  defp explain(:busy), do: "A sound is already being saved or loaded."
  defp explain(:switching), do: "The synth is switching; try again in a moment."
  defp explain(:not_running), do: "The synth isn't running."
  defp explain(:quit), do: "FMutate is quitting."
  defp explain(:wrong_synth), do: "Another synth is running now."
  defp explain(:backend_changed), do: "The synth now runs on another engine; nothing was changed."
  defp explain({:stop_failed, _}), do: "The synth didn't stop cleanly; nothing was changed."
  defp explain({:failed_to_start, _}), do: "The synth didn't start with that sound, so its memory is back as it was."
  defp explain(text) when is_binary(text), do: text
  defp explain(other), do: "It didn't work (#{inspect(other)})."
end
