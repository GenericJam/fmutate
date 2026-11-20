# The synth parameters a bundled firmware's MIDI CCs set, from its source: priv/midi_params/<id>@<version>.json
# (FMutate.MIDI.Params reads them, for the I/O screen's pins and what an unmapped knob does).
#
#     sh native/build_android.sh        # fetches the firmwares at their pinned commits (native/build/fw/)
#     mise exec -- elixir tools/midi_params.exs
#
# OberVave and Shine On share their MIDI code: `PDEF` (obv_params.h / shn_params.h) lists the parameters, each with
# a fixed CC or 0; `cc_map_init` (obervave.c / shineon.c) gives the fixed ones theirs and the rest the CCs from 20
# up in table order, skipping 64 and taken ones, below 120. The channel handler takes some CCs before `cc_map`
# (`d1 == 7u`, 64, 120, 123): those set no parameter and are left out. A parameter is named by the page that has it
# on a knob (`PAGE`, in page order, PERFORM last since it repeats other pages' parameters), e.g. "OSC 1 · WAVE".
# The script checks the source is at the commit native/build_android.sh pins, so the file matches what the app runs.

defmodule MidiParams do
  @root Path.expand("..", __DIR__)

  # firmware id, source dir, params header, main source, the version build_android.sh names
  @firmwares [
    {"obervave", "obv_params.h", "obervave.c"},
    {"shineon", "shn_params.h", "shineon.c"}
  ]

  def run do
    pins = pinned()

    for {id, header, main} <- @firmwares do
      {repo, commit, version} = Map.fetch!(pins, id)
      dir = Path.join([@root, "native/build/fw", id])

      head =
        dir
        |> then(&System.cmd("git", ["-C", &1, "rev-parse", "HEAD"]))
        |> elem(0)
        |> String.trim()

      if head != commit,
        do: raise("#{id}: #{dir} is at #{head}, native/build_android.sh pins #{commit}")

      h = File.read!(Path.join([dir, "firmware/src", header]))
      c = File.read!(Path.join([dir, "firmware/src", main]))
      params = params(h, c)
      out = Path.join([@root, "priv/midi_params", "#{id}@#{version}.json"])
      File.mkdir_p!(Path.dirname(out))

      json = %{
        "firmware" => id,
        "version" => version,
        "source" => "#{repo} #{commit}",
        "params" => params
      }

      File.write!(out, pretty(json))
      IO.puts("#{Path.relative_to(out, @root)}: #{length(params)} parameters")
    end
  end

  # name -> {repo, commit, version} from native/build_android.sh's CARTRIDGES
  defp pinned do
    for line <- File.read!(Path.join(@root, "native/build_android.sh")) |> String.split("\n"),
        [name, repo, commit, version] <- [String.split(line)],
        String.starts_with?(repo, "https://"),
        into: %{},
        do: {name, {repo, commit, version}}
  end

  defp params(h, c) do
    names = enum(h, ~r/enum \{\s*(P_[A-Z0-9_]+.*?)NPARAM/s)
    pages = enum(h, ~r/enum \{\s*(PG_[A-Z0-9_]+.*?)NPAGE/s)

    pdef =
      for [_, p, name, _max, cc] <-
            Regex.scan(
              ~r/\[(P_[A-Z0-9_]+)\]\s*=\s*\{"([^"]*)",\s*([^,]+),\s*[^,]+,\s*[^,]+,\s*(\d+)\}/,
              block(h, "PDEF")
            ),
          into: %{},
          do: {p, %{name: name, cc: String.to_integer(cc)}}

    if map_size(pdef) != length(names),
      do: raise("PDEF has #{map_size(pdef)} entries for #{length(names)} parameters")

    page_of =
      for [_, pg, title, knobs] <-
            Regex.scan(
              ~r/\[(PG_[A-Z0-9_]+)\]\s*=\s*\{"([^"]*)",\s*\{([^}]*)\}\}/,
              block(h, "PAGE")
            ),
          into: %{},
          do: {pg, {title, knobs |> String.split(",") |> Enum.map(&String.trim/1)}}

    # the page that shows a parameter: page order, PERFORM (a page of other pages' parameters) last
    order = Enum.reject(pages, &(&1 == "PG_PERFORM")) ++ ["PG_PERFORM"]

    place =
      for pg <- order,
          {title, knobs} = Map.get(page_of, pg, {nil, []}),
          {p, i} <- Enum.with_index(knobs),
          String.starts_with?(p, "P_"),
          reduce: %{} do
        acc -> Map.put_new(acc, p, {Enum.find_index(order, &(&1 == pg)), i, title})
      end

    taken_first =
      for(m <- Regex.scan(~r/d1 == (\d+)u/, c), do: String.to_integer(Enum.at(m, 1)))
      |> Enum.uniq()

    cc_of = cc_map(names, pdef)

    names
    |> Enum.with_index()
    |> Enum.map(fn {p, i} -> {p, i, Map.fetch!(cc_of, p)} end)
    |> Enum.reject(fn {_p, _i, cc} -> cc == nil or cc in taken_first end)
    |> Enum.sort_by(fn {p, i, _cc} ->
      {Map.get(place, p, {length(order), i, nil}) |> Tuple.delete_at(2), i}
    end)
    |> Enum.map(fn {p, _i, cc} ->
      d = pdef[p]
      {_, _, page} = Map.get(place, p, {nil, nil, "OTHER"})
      %{"cc" => cc, "page" => page, "name" => d.name}
    end)
  end

  # cc_map_init: the fixed CCs, then from 20 up in table order, skipping 64 and taken ones, below 120
  defp cc_map(names, pdef) do
    fixed = for p <- names, pdef[p].cc > 0, into: %{}, do: {p, pdef[p].cc}
    taken = MapSet.new(Map.values(fixed))

    {map, _, _} =
      Enum.reduce(names, {fixed, taken, 20}, fn p, {map, taken, next} ->
        if Map.has_key?(fixed, p) do
          {map, taken, next}
        else
          next =
            Stream.iterate(next, &(&1 + 1))
            |> Enum.find(&(&1 >= 120 or (&1 not in taken and &1 != 64)))

          if next < 120,
            do: {Map.put(map, p, next), MapSet.put(taken, next), next + 1},
            else: {Map.put(map, p, nil), taken, next}
        end
      end)

    map
  end

  defp enum(h, re) do
    [_, body] = Regex.run(re, h)

    body
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.split([",", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp block(h, name) do
    [_, body] = Regex.run(~r/#{name}\[N[A-Z]+\]\s*=\s*\{(.*?)\n\};/s, h)
    body
  end

  defp pretty(%{"params" => params} = json) do
    rows = Enum.map_join(params, ",\n", &("    " <> JSON.encode!(&1)))

    head =
      json
      |> Map.delete("params")
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {k, v} -> "  #{JSON.encode!(k)}: #{JSON.encode!(v)}" end)

    "{\n#{head},\n  \"params\": [\n#{rows}\n  ]\n}\n"
  end
end

MidiParams.run()
