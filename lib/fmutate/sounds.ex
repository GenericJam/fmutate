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

  kept in `sounds/<id>/<UTC time>-<name>.sound.json` (`FMutate.Paths.sounds/1`); saving always adds a file (the
  name is reserved by an exclusive create, so two saves at once never share one). `firmware` is the build that
  ran (`FMutate.Firmware.build/2`, kept with its engine), `commit` when the build says. The payload is the
  engine's flash file as it is: for a native cartridge its save blobs one after the other (its length is the
  cartridge's), for a package in the emulator engine the sectors that differ from the package's own flash
  (records of a little-endian u32 sector offset and 4096 bytes, `docs/engine_protocol.md`).

  Loading checks the sound against the running build (`check/2`): the firmware id and backend must be the same,
  the payload's length and SHA-256 must match it, an emulator payload must be whole records at distinct
  4096-aligned offsets inside the 1 MiB flash, a native one as long as the synth's current file (again once the
  engine has ended). Made with another version of the same synth: `{:other_version, made, have}`, for the player
  to decide. Before replacing, the bytes it replaces are kept (`Paths.sound_undo/2`, one file replaced as a
  whole): `undo/2` puts them back under the same checks and keeps what it replaced, so a second undo redoes.
  """

  require Logger

  alias FMutate.{Instance, Paths}

  @format "fmutate.sound/1"
  @record 4100
  @sector 4096
  @emu_flash 1024 * 1024
  # a whole emulated flash in base64 with its JSON is ~1.4 MB: anything much bigger isn't a sound
  @max_file 4_000_000

  @typedoc "Who a sound is for: the build it was saved from (`FMutate.Firmware.build/2`)."
  @type firmware :: %{
          id: String.t(),
          name: String.t(),
          version: String.t() | nil,
          backend: :native | :emu,
          commit: String.t() | nil
        }

  @typedoc "A sound read and checked."
  @type sound :: %{
          name: String.t(),
          saved_at: String.t(),
          firmware: firmware,
          bytes: binary,
          path: String.t() | nil
        }

  @typedoc "A listed sound: what the list shows, no payload (`list/1`); `read/1` gets the whole sound."
  @type entry :: %{name: String.t(), saved_at: String.t(), firmware: firmware, size: non_neg_integer, path: String.t()}

  @typedoc "What runs: its build, its backend and the length of its flash file (nil when there is none)."
  @type running :: %{firmware: firmware, backend: :native | :emu, flash_size: non_neg_integer | nil}

  ## Saving and the list

  @doc """
  Save the running firmware's save memory as a new sound named `name` (the firmware restarts for a moment).
  `{:ok, sound}` or `{:error, text}`.
  """
  @spec save(String.t(), String.t()) :: {:ok, sound} | {:error, String.t()}
  def save(instance, name) do
    with {:ok, %{build: build, bytes: bytes}} <- Instance.snapshot(instance) |> instance_answer() do
      add(%{name: clean_name(name, build.name), saved_at: now(), firmware: build, bytes: bytes, path: nil})
    end
  end

  @doc """
  The saved sounds of a firmware, newest first, without their payloads (each file is read and let go of in turn).
  Files that aren't sounds are left out (and logged).
  """
  @spec list(String.t()) :: [entry]
  def list(firmware_id) do
    dir = Paths.sounds(firmware_id)

    dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".sound.json"))
    |> Enum.flat_map(fn file ->
      path = Path.join(dir, file)

      case entry(path) do
        {:ok, entry} ->
          [entry]

        # (an empty file is a name reserved by a save still writing)
        :empty ->
          []

        {:error, why} ->
          Logger.warning("sounds: #{path} left out: #{why}")
          []
      end
    end)
    |> Enum.sort_by(&{&1.saved_at, &1.path}, :desc)
  end

  defp entry(path) do
    with {:ok, %{size: size}} when size > 0 <- File.stat(path),
         true <- size <= @max_file || {:error, "too big"},
         {:ok, json} <- File.read(path),
         {:ok, %{"format" => @format} = doc} <- decode(json),
         {:ok, fw} <- parse_firmware(doc["firmware"]),
         %{"bytes" => n} when is_integer(n) <- doc["payload"] do
      saved_at = parse_time(doc["saved_at"]) || ""
      {:ok, %{name: clean_name(doc["name"], "Sound"), saved_at: saved_at, firmware: fw, size: n, path: path}}
    else
      {:ok, %{size: 0}} -> :empty
      {:error, :no_firmware} -> {:error, "no firmware"}
      {:error, reason} when is_atom(reason) -> {:error, to_string(:file.format_error(reason))}
      {:error, _} = error -> error
      _ -> {:error, "not a sound"}
    end
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
  @spec delete(%{path: String.t()}) :: :ok
  def delete(%{path: path}) do
    _ = File.rm(path)
    :ok
  end

  @doc """
  Copy a saved sound into `dir` (the cache, for the share sheet) under a file name made from its name and its
  synth's, and return that path.
  """
  @spec export(%{path: String.t(), name: String.t(), firmware: firmware}, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
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
         :ok <- anyway(check(sound, running)),
         do: add(%{sound | path: nil})
  end

  ## Loading

  @doc "What runs on `instance` now (its build, from the engine), for `check/2`."
  @spec running(String.t()) :: {:ok, running} | {:error, String.t()}
  def running(instance) do
    case Instance.running(instance) do
      %{build: build, flash: flash} ->
        size =
          case File.stat(flash) do
            {:ok, %{size: size}} -> size
            _ -> nil
          end

        {:ok, %{firmware: build, backend: build.backend, flash_size: size}}

      nil ->
        {:error, "The synth isn't running."}
    end
  end

  @doc """
  Whether `sound` can go into the running synth: `:ok`, `{:other_version, made, have}` (the same synth and backend,
  another version: the player decides) or `{:error, text}` saying why not.
  """
  @spec check(%{firmware: firmware, bytes: binary}, running) ::
          :ok | {:other_version, String.t() | nil, String.t() | nil} | {:error, String.t()}
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
  Load a sound into the running synth (it restarts for a moment): checked again here (`check/2`); another version
  only with `anyway: true` (else `{:other_version, made, have}`, nothing done). What it replaces is kept for
  `undo/2`.
  """
  @spec load(String.t(), sound, keyword) ::
          :ok | {:other_version, String.t() | nil, String.t() | nil} | {:error, String.t()}
  def load(instance, sound, opts \\ []) do
    with {:ok, running} <- running(instance),
         :ok <- confirmed(check(sound, running), opts[:anyway]),
         do: restore(instance, running, sound.bytes)
  end

  @doc "Whether the last load into the running firmware on `instance` can be undone (or redone): its backend's."
  @spec undo?(String.t(), String.t(), :native | :emu) :: boolean
  def undo?(instance, firmware_id, backend) do
    match?({:ok, %{backend: ^backend}}, read_undo(instance, firmware_id))
  end

  @doc """
  Put back what the last load (or undo) replaced in the running synth, under the checks of a load (made with
  another version: only with `anyway: true`, else `{:other_version, made, have}`), keeping what this replaces: a
  second undo redoes.
  """
  @spec undo(String.t(), keyword) :: :ok | {:other_version, String.t() | nil, String.t() | nil} | {:error, String.t()}
  def undo(instance, opts \\ []) do
    with {:ok, running} <- running(instance),
         {:ok, kept} <- read_undo(instance, running.firmware.id) |> or_error("There's no load to undo."),
         as_sound = %{firmware: %{running.firmware | version: kept.version, backend: kept.backend}, bytes: kept.bytes},
         :ok <- confirmed(check(as_sound, running), opts[:anyway]),
         do: restore(instance, running, kept.bytes)
  end

  defp confirmed({:other_version, _made, _have}, true), do: :ok
  defp confirmed(answer, _anyway), do: answer

  defp anyway({:other_version, _made, _have}), do: :ok
  defp anyway(answer), do: answer

  # the bytes it replaces: as long as them (native; checked with the engine ended), and kept as the undo first
  defp restore(instance, %{firmware: build}, bytes) do
    keep = fn old ->
      if build.backend == :native and old != nil and byte_size(old) != byte_size(bytes),
        do: {:error, "Its memory is #{byte_size(bytes)} bytes; the synth's is #{byte_size(old)}."},
        else: keep_undo(instance, build, old)
    end

    Instance.restore(instance, build.id, build.backend, bytes, keep) |> instance_answer() |> ok()
  end

  # one file with the bytes and whose they are, written beside and renamed over the last one (which stays whole
  # if this fails); nil (no file) is kept as empty, which the engines read as none too
  defp keep_undo(instance, build, old) do
    kept = %{firmware: build.id, backend: build.backend, version: build.version, kept_at: now(), bytes: old || <<>>}

    case atomic_write(Paths.sound_undo(instance, build.id), :erlang.term_to_binary(kept)) do
      :ok -> :ok
      {:error, reason} -> {:error, "Couldn't keep the current memory for Undo (#{:file.format_error(reason)})."}
    end
  end

  defp read_undo(instance, id) do
    with {:ok, bin} <- File.read(Paths.sound_undo(instance, id)),
         %{firmware: ^id, backend: backend, version: version, bytes: bytes} when backend in [:native, :emu] <-
           safe_term(bin) do
      {:ok, %{backend: backend, version: version, bytes: bytes}}
    else
      _ -> :none
    end
  end

  defp safe_term(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> nil
  end

  ## The file format

  @doc "Decode and check a `fmutate.sound/1` document: `{:ok, sound}` (with `path: nil`) or `{:error, text}`."
  @spec parse(binary) :: {:ok, sound} | {:error, String.t()}
  def parse(json) when byte_size(json) > @max_file, do: {:error, "It's too big to be a sound."}

  def parse(json) do
    with {:ok, %{"format" => @format} = doc} <- decode(json),
         {:ok, fw} <- parse_firmware(doc["firmware"]) |> describe(),
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

  defp parse_firmware(_), do: {:error, :no_firmware}

  defp describe({:error, :no_firmware}), do: {:error, "It doesn't say which synth it is for."}
  defp describe(ok), do: ok

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

  # always a new file: `<UTC time>-<name>.sound.json`, `-2`, `-3`… when that is taken. The name is reserved by an
  # exclusive create (an empty file, left out of the list), then the sound is written beside it and renamed over it.
  defp add(sound) do
    dir = Paths.sounds(sound.firmware.id)
    base = "#{String.replace(sound.saved_at, ["-", ":"], "")}-#{slug(sound.name)}"

    with {:ok, path} <- reserve(dir, base, 1) do
      case atomic_write(path, encode(sound)) do
        :ok ->
          {:ok, %{sound | path: path}}

        {:error, reason} ->
          File.rm(path)
          {:error, "Couldn't save it (#{:file.format_error(reason)})."}
      end
    end
  end

  @max_same 1000

  defp reserve(_dir, _base, n) when n > @max_same, do: {:error, "Couldn't save it (too many of that name)."}

  defp reserve(dir, base, n) do
    path = Path.join(dir, if(n == 1, do: "#{base}.sound.json", else: "#{base}-#{n}.sound.json"))

    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        File.close(io)
        {:ok, path}

      {:error, :eexist} ->
        reserve(dir, base, n + 1)

      {:error, reason} ->
        {:error, "Couldn't save it (#{:file.format_error(reason)})."}
    end
  end

  # (a temp file of its own: two writers never share one)
  defp atomic_write(path, data) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

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
  defp explain(:build_changed), do: "The synth's build changed since it started; nothing was changed."
  defp explain({:stop_failed, _}), do: "The synth didn't stop cleanly; nothing was changed."
  defp explain({:failed_to_start, _}), do: "The synth didn't start with that sound, so its memory is back as it was."
  defp explain({:confirm_failed, _}), do: "Loaded, but FMutate couldn't record it: it goes back at the next start."

  defp explain({:rollback_failed, _why, _reason}),
    do: "The synth didn't start with that sound, and its memory couldn't be put back. Free some space, then Run anyway."

  defp explain({:write_failed, reason}), do: "Couldn't write the synth's memory (#{inspect(reason)}); nothing changed."
  defp explain(text) when is_binary(text), do: text
  defp explain(other), do: "It didn't work (#{inspect(other)})."
end
