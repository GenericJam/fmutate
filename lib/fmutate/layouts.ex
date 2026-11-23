defmodule FMutate.Layouts do
  @moduledoc """
  Layouts (`priv/layout.schema.json`, format `fmutate.layout/1`): the presets shipped in `priv/layouts/`,
  and the player's own.

  A layout belongs to one firmware and one instance (HANDOFF §3, §5): each `{instance, firmware}` has its
  current layout, saved under the data dir (`FMutate.Paths.layout/2`) whenever it is edited. Until the
  player makes one, it is the classic layout, which is also always one tap away ("Original layout", "Reset
  to classic"). Every change to it (`change/4`, `reset/2`) keeps the layout it replaced in a one-step undo
  slot next to it (`undo/2` swaps the two, so a second press redoes). Presets are starting points: "new
  layout from a preset" copies one for the running firmware, "new page from a preset"
  (`FMutate.LayoutEdit.add_page_from_preset/2`) copies its first page.

  The layout library (`library/0`) holds layouts the player saved on purpose, for no synth in particular:
  each save is a new entry stamped `meta.saved_at`; any of them loads onto the running synth
  (`load_saved/3`), and they import from and export to `.json` files.

  Layouts are decoded JSON (string keys) on this side; the native instrument view gets them as JSON text
  (`encode/1`) and draws them (android `fmutate/Layout.kt`). Every saved layout passes `validate/1`: the
  schema (`FMutate.Layouts.Schema`) and the editing rules (`FMutate.LayoutEdit.semantic_errors/1`).
  """

  alias FMutate.{LayoutEdit, Paths}
  alias FMutate.Layouts.Schema

  @type layout :: map()

  @doc "Directory of the preset layouts."
  def presets_dir, do: Paths.priv("layouts")

  @doc "Every preset as `%{id, name, firmware, frame, data}` (`data` is the decoded layout)."
  def presets do
    presets_dir()
    |> Path.join("*.layout.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&load_preset!/1)
  end

  @doc "A preset by id."
  def preset(id), do: Enum.find(presets(), &(&1.id == id))

  @doc "The classic layout (the FM-1 panel), as shipped; works with any firmware."
  def classic, do: preset("classic").data

  @doc "Presets made for a firmware: its own plus the universal ones (`firmware.id == \"any\"`)."
  def for_firmware(firmware_id), do: Enum.filter(presets(), &(&1.firmware in ["any", firmware_id]))

  defp load_preset!(path) do
    data = path |> File.read!() |> JSON.decode!()
    %{id: data["id"], name: data["name"], firmware: get_in(data, ["firmware", "id"]), frame: data["frame"], data: data}
  end

  ## The player's layouts

  @doc """
  The current layout of an instance for a firmware: the saved one, or the classic layout. A saved file
  that no longer validates (hand-edited, older app) is ignored rather than drawn wrong.
  """
  @spec current(String.t(), String.t() | nil) :: layout
  def current(_instance, nil), do: classic()
  def current(instance, firmware_id), do: locked(instance, firmware_id, fn -> effective(instance, firmware_id) end)

  defp effective(instance, firmware_id), do: working(instance, firmware_id) || for_this(classic(), firmware_id)

  # the saved current layout, or nil (none, or one that no longer validates); under the lock
  defp working(instance, firmware_id) do
    with {:ok, json} <- File.read(Paths.layout(instance, firmware_id)),
         {:ok, data} <- decode(json),
         :ok <- validate(data) do
      data
    else
      _ -> nil
    end
  end

  @doc "Whether the player has a saved layout for this firmware (else the instrument shows classic)."
  def saved?(instance, firmware_id),
    do: locked(instance, firmware_id, fn -> File.exists?(Paths.layout(instance, firmware_id)) end)

  @doc """
  Validate and save the current layout of an instance for a firmware, leaving the undo slot as it is. The
  instance's `FMutate.MIDI` takes its learned MIDI controls from it.
  """
  @spec save(String.t(), String.t(), layout) :: :ok | {:error, [String.t()]}
  def save(instance, firmware_id, layout) do
    layout = for_this(layout, firmware_id)

    with :ok <- validate(layout),
         do: locked(instance, firmware_id, fn -> commit(instance, firmware_id, {:put, layout}, :keep) end)
  end

  @doc """
  Edit the current layout in place, like `save/3`, but with `fun` applied to the layout as it is when the edit
  happens (a writer that holds an older copy, such as `FMutate.MIDI` clearing learned controls, can't undo
  someone else's change). `fun` returns `{:ok, layout}` or an error, which is returned as it is.
  """
  @spec update(String.t(), String.t(), (layout -> {:ok, layout} | term())) :: :ok | term()
  def update(instance, firmware_id, fun) do
    locked(instance, firmware_id, fn ->
      with {:ok, layout} <- fun.(effective(instance, firmware_id)),
           layout = for_this(layout, firmware_id),
           :ok <- validate(layout),
           do: commit(instance, firmware_id, {:put, layout}, :keep)
    end)
  end

  @doc """
  Forget the saved layout: the classic one again ("Original layout", "Reset to classic"). The layout it
  replaces goes into the undo slot. Returns the classic layout.
  """
  def reset(instance, firmware_id) do
    locked(instance, firmware_id, fn ->
      if File.exists?(Paths.layout(instance, firmware_id)) do
        slot = with %{} = before <- working(instance, firmware_id), do: {:put, slot(false, before)}
        commit(instance, firmware_id, :delete, slot || :keep)
      end

      effective(instance, firmware_id)
    end)
  end

  ## One-step undo
  #
  # The undo slot (`Paths.layout_undo/2`) holds the current layout as it was before the last change, or nil
  # when there was no saved one (the classic layout): `{"format": "fmutate.layout-undo/1", "redo": bool,
  # "layout": layout | null}`. Undo swaps it with the current layout, so the next press redoes ("redo": true).
  #
  # The working file and the slot change together: such a change is first written whole to a journal
  # (`Paths.layout_journal/2`, atomically), then applied, then the journal goes; whoever takes the lock next
  # finishes a journal a crash left behind, so the pair is never half changed. Every reader and writer of the
  # pair (this module's functions, `FMutate.MIDI` through `update/3`) holds a lock per {instance, firmware}.

  @doc """
  Make `layout` the current layout of an instance for a firmware (an edit, a new layout from a preset, a load
  from the library): saved as `save/3` does, with the layout it replaces kept in the undo slot. `coalesce:
  true` (the same text field typed into again) keeps the slot as it is, so a name typed letter by letter is one
  step. A layout equal to the current one (the classic one included, when nothing is saved) changes nothing.
  """
  @spec change(String.t(), String.t(), layout, keyword()) :: :ok | {:error, [String.t()]}
  def change(instance, firmware_id, layout, opts \\ []) do
    layout = for_this(layout, firmware_id)

    with :ok <- validate(layout) do
      locked(instance, firmware_id, fn ->
        before = working(instance, firmware_id)

        cond do
          layout == (before || for_this(classic(), firmware_id)) -> :ok
          opts[:coalesce] && match?({:ok, false, _}, read_slot(instance, firmware_id)) -> commit(instance, firmware_id, {:put, layout}, :keep)
          true -> commit(instance, firmware_id, {:put, layout}, {:put, slot(false, before)})
        end
      end)
    end
  end

  @doc "What the undo slot does next: `:undo`, `:redo`, or nil (nothing to undo)."
  @spec undo_state(String.t(), String.t() | nil) :: :undo | :redo | nil
  def undo_state(_instance, nil), do: nil

  def undo_state(instance, firmware_id) do
    case locked(instance, firmware_id, fn -> read_slot(instance, firmware_id) end) do
      {:ok, true, _} -> :redo
      {:ok, false, _} -> :undo
      :none -> nil
    end
  end

  @doc """
  Swap the current layout with the undo slot: undo the last change, or redo it after an undo. Returns the
  current layout, `:none` with nothing to undo, or `{:error, messages}` when the slot's layout no longer
  validates.
  """
  @spec undo(String.t(), String.t()) :: {:ok, layout} | :none | {:error, [String.t()]}
  def undo(instance, firmware_id) do
    locked(instance, firmware_id, fn ->
      with {:ok, redo, layout} <- read_slot(instance, firmware_id),
           target = layout && for_this(layout, firmware_id),
           :ok <- if(target, do: validate(target), else: :ok) do
        before = working(instance, firmware_id)
        commit(instance, firmware_id, if(target, do: {:put, target}, else: :delete), {:put, slot(not redo, before)})
        {:ok, effective(instance, firmware_id)}
      end
    end)
  end

  defp slot(redo, layout), do: %{"format" => "fmutate.layout-undo/1", "redo" => redo, "layout" => layout}

  defp read_slot(instance, firmware_id) do
    with {:ok, json} <- File.read(Paths.layout_undo(instance, firmware_id)),
         {:ok, %{"format" => "fmutate.layout-undo/1", "redo" => redo, "layout" => layout}}
         when is_boolean(redo) and (is_map(layout) or is_nil(layout)) <- JSON.decode(json) do
      {:ok, redo, layout}
    else
      _ -> :none
    end
  end

  # one change to the pair: `working` {:put, layout} | :delete, `slot` {:put, slot} | :keep. Under the lock.
  defp commit(instance, firmware_id, working, slot) do
    journal = Paths.layout_journal(instance, firmware_id)

    if slot != :keep do
      entry = %{"format" => "fmutate.layout-journal/1", "working" => put_or_nil(working), "slot" => elem(slot, 1)}
      write_atomic(journal, JSON.encode!(entry))
    end

    apply_change(instance, firmware_id, working, slot)
    _ = File.rm(journal)

    now = with {:put, layout} <- working, do: layout
    FMutate.MIDI.layout_saved(instance, firmware_id, if(now == :delete, do: for_this(classic(), firmware_id), else: now))
  end

  defp put_or_nil({:put, layout}), do: layout
  defp put_or_nil(:delete), do: nil

  defp apply_change(instance, firmware_id, working, slot) do
    case working do
      {:put, layout} -> write_atomic(Paths.layout(instance, firmware_id), encode(layout))
      :delete -> _ = File.rm(Paths.layout(instance, firmware_id))
    end

    with {:put, s} <- slot, do: write_atomic(Paths.layout_undo(instance, firmware_id), JSON.encode!(s))
  end

  # a journal left by a crash: finish what it says (or drop it if it isn't one)
  defp recover(instance, firmware_id) do
    journal = Paths.layout_journal(instance, firmware_id)

    with {:ok, json} <- File.read(journal) do
      case JSON.decode(json) do
        {:ok, %{"format" => "fmutate.layout-journal/1", "working" => w, "slot" => %{} = s}} when is_map(w) or is_nil(w) ->
          apply_change(instance, firmware_id, if(w, do: {:put, w}, else: :delete), {:put, s})

        _ ->
          :ok
      end

      File.rm(journal)
    end
  end

  # one writer (or reader) of an {instance, firmware}'s layout pair at a time; nested calls run inside the outer one
  defp locked(instance, firmware_id, fun) do
    key = {__MODULE__, instance, firmware_id}

    if Process.get(key) do
      fun.()
    else
      :global.trans(
        {key, self()},
        fn ->
          Process.put(key, true)

          try do
            recover(instance, firmware_id)
            fun.()
          after
            Process.delete(key)
          end
        end,
        [node()]
      )
    end
  end

  defp write_atomic(path, data) do
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
  end

  @doc "A copy of a preset for a firmware, ready to be the current layout."
  def from_preset(preset_id, firmware_id) do
    case preset(preset_id) do
      nil -> nil
      p -> p.data |> for_this(firmware_id) |> put_in(["meta"], %{"made_by" => "user"})
    end
  end

  ## The layout library: layouts saved on purpose, for any synth
  #
  # One file per entry (`Paths.saved_layouts/0`, `<UTC time>-<name>.layout.json`), never overwritten: the
  # layout as it was (unresolved, `firmware.id` the synth it was saved from) with `meta.saved_at`.

  @type entry :: %{file: String.t(), name: String.t(), saved_at: String.t(), firmware: String.t() | nil}

  @doc "The saved layouts, newest first, as `%{file, name, saved_at, firmware}` (files that don't decode are left out)."
  @spec library() :: [entry]
  def library do
    Paths.saved_layouts()
    |> Path.join("*.layout.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, json} <- read_limited(path), {:ok, l} <- decode(json) do
        [%{file: Path.basename(path), name: l["name"], saved_at: get_in(l, ["meta", "saved_at"]) || "", firmware: get_in(l, ["firmware", "id"])}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(&{&1.saved_at, &1.file}, :desc)
  end

  @doc """
  Save a layout to the library under a name (blank: the layout's own name), stamped now: always a new entry.
  """
  @spec save_to_library(layout, String.t()) :: {:ok, entry} | {:error, [String.t()]}
  def save_to_library(layout, name) do
    name = name |> String.trim() |> String.slice(0, 40)
    name = if name == "", do: layout["name"], else: name
    layout |> Map.put("name", name) |> put_saved_at(timestamp()) |> add_to_library()
  end

  @max_bytes 1_000_000
  @max_pages 64

  @doc """
  Import a layout file into the library (it isn't loaded): it must be a valid `fmutate.layout/1` of at most
  1 MB. It keeps its `meta.saved_at` (else it is stamped now) and its `firmware`. Reads the file: call it from a
  task, not from a screen.
  """
  @spec import_file(Path.t()) :: {:ok, entry} | {:error, [String.t()]}
  def import_file(path) do
    with {:ok, json} <- read_limited(path),
         {:ok, layout} <- decode(json),
         :ok <- validate(layout) do
      saved_at =
        case DateTime.from_iso8601(to_string(get_in(layout, ["meta", "saved_at"]))) do
          {:ok, at, _offset} -> at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          _ -> timestamp()
        end

      layout |> put_saved_at(saved_at) |> add_to_library()
    else
      {:error, [_ | _] = messages} -> {:error, messages}
      {:error, :not_an_object} -> {:error, ["it isn't a JSON object"]}
      {:error, reason} when is_atom(reason) -> {:error, ["it can't be read (#{reason})"]}
      _ -> {:error, ["it isn't JSON"]}
    end
  end

  @doc "A saved layout (`entry.file`), validated."
  @spec read_saved(String.t()) :: {:ok, layout} | {:error, [String.t()]}
  def read_saved(file) do
    with {:ok, json} <- read_limited(saved_path(file)),
         {:ok, layout} <- decode(json),
         :ok <- validate(layout) do
      {:ok, layout}
    else
      {:error, [_ | _] = messages} -> {:error, messages}
      _ -> {:error, ["That saved layout can't be read"]}
    end
  end

  @doc """
  Load a saved layout onto a synth: it becomes the current layout for `firmware_id` (retargeted, `change/4`, so
  it can be undone). Its bindings come along as they are. Returns the new current layout.
  """
  @spec load_saved(String.t(), String.t(), String.t()) :: {:ok, layout} | {:error, [String.t()]}
  def load_saved(instance, firmware_id, file) do
    with {:ok, layout} <- read_saved(file),
         :ok <- change(instance, firmware_id, drop_saved_at(layout)) do
      {:ok, current(instance, firmware_id)}
    end
  end

  @doc "Delete a saved layout."
  def delete_saved(file), do: File.rm(saved_path(file))

  @doc """
  Copy a saved layout, as saved, into `dir` (the share sheet's cache directory) as `<name>.layout.json`.
  Returns its path.
  """
  @spec export_saved(String.t(), Path.t()) :: {:ok, Path.t()} | {:error, [String.t()]}
  def export_saved(file, dir) do
    with {:ok, layout} <- read_saved(file) do
      File.mkdir_p!(dir)
      path = Path.join(dir, slug(layout["name"]) <> ".layout.json")
      File.cp!(saved_path(file), path)
      {:ok, path}
    end
  end

  defp saved_path(file), do: Path.join(Paths.saved_layouts(), Path.basename(file))

  defp add_to_library(layout) do
    with :ok <- validate(layout) do
      stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S%fZ")
      file = new_file(Paths.saved_layouts(), "#{stamp}-#{slug(layout["name"])}", encode(layout), 1)
      {:ok, %{file: file, name: layout["name"], saved_at: layout["meta"]["saved_at"], firmware: layout["firmware"]["id"]}}
    end
  end

  # a file of its own: never overwrites an entry (the same name in the same instant gets "-2", "-3", …)
  defp new_file(dir, base, data, n) do
    file = if n == 1, do: base <> ".layout.json", else: "#{base}-#{n}.layout.json"

    case File.open(Path.join(dir, file), [:write, :exclusive, :binary]) do
      {:ok, io} ->
        :ok = IO.binwrite(io, data)
        :ok = File.close(io)
        file

      {:error, :eexist} ->
        new_file(dir, base, data, n + 1)
    end
  end

  defp put_saved_at(layout, at), do: Map.update(layout, "meta", %{"saved_at" => at}, &Map.put(&1, "saved_at", at))

  defp drop_saved_at(%{"meta" => meta} = layout) do
    case Map.delete(meta, "saved_at") do
      empty when map_size(empty) == 0 -> Map.delete(layout, "meta")
      meta -> Map.put(layout, "meta", meta)
    end
  end

  defp drop_saved_at(layout), do: layout

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp slug(name) do
    case to_string(name) |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-") |> String.trim("-") |> String.slice(0, 40) do
      "" -> "layout"
      slug -> slug
    end
  end

  # a layout belongs to the firmware it is saved for
  defp for_this(layout, nil), do: layout
  defp for_this(layout, firmware_id), do: Map.put(layout, "firmware", %{"id" => firmware_id})

  @doc """
  `:ok`, or `{:error, messages}`: the schema first, then the size (at most #{@max_pages} pages, no page with more
  controls, or more cells of them, than its grid has cells: so the editing rules' work stays bounded for any
  file), then the editing rules.
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(layout) do
    with {:schema, :ok} <- {:schema, Schema.validate(layout)},
         [] <- size_errors(layout),
         [] <- LayoutEdit.semantic_errors(layout) do
      :ok
    else
      {:schema, {:error, errors}} ->
        {:error, Enum.map(errors, fn {path, msg} -> "#{if path == "", do: "/", else: path}: #{msg}" end)}

      errors ->
        {:error, errors}
    end
  end

  defp size_errors(%{"grid" => %{"cols" => cols, "rows" => rows}, "pages" => pages} = layout) do
    cells = cols * rows
    dock = layout["dock"] || []

    if length(pages) > @max_pages do
      ["it has #{length(pages)} pages; a layout has at most #{@max_pages}"]
    else
      for p <- pages,
          all = dock ++ (p["controls"] || []),
          length(all) > cells or Enum.sum_by(all, &(&1["at"]["w"] * &1["at"]["h"])) > cells,
          do: "page #{p["name"]} has more controls than its #{cols}×#{rows} grid has room for"
    end
  end

  # at most @max_bytes of a file, else a refusal that says so
  defp read_limited(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) > @max_bytes -> {:error, ["it's too big: a layout file is at most 1 MB"]}
      {:ok, data} when is_binary(data) -> {:ok, data}
      {:ok, :eof} -> {:ok, ""}
      {:ok, {:error, reason}} -> {:error, reason}
      error -> error
    end
  end

  @doc "Layout JSON text (what the instrument view and the files take)."
  def encode(layout), do: JSON.encode!(layout)

  @doc "Decode layout JSON text."
  def decode(json) do
    case JSON.decode(json) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> {:error, :not_an_object}
      error -> error
    end
  end
end
