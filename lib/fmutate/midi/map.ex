defmodule FMutate.MIDI.Map do
  @moduledoc """
  Incoming MIDI from one source (a USB/Bluetooth device's port, an app on the instance's virtual port) →
  `FMutate.Instance` inputs (HANDOFF §10). Pure: `feed/2` takes the bytes as they arrive and returns the
  inputs plus the new state, so running status and messages split across packets work.

  Settings (per source, except `clock` and `bend`, which `FMutate.MIDI` sets for the whole instance):

    * `channel` — `:all` or `1..16`. Channel messages on other channels are dropped.
    * `notes` — `:keys` (default): a note in the FM-1's range (F3..G5, MIDI 53..79) presses that firmware
      key (FM-1 keys carry no velocity). Notes outside the range, and every note with `:firmware`, go to the
      firmware's MIDI in as they are (velocity kept).
    * `bend` — whether the firmware does something with pitch bend (`caps.pitch_bend`, the same cap that
      enables keyboard wobble). Pitch bend goes to the firmware's MIDI in only then.
    * `clock` — `:follow` passes clock, start, continue, stop and song position to the firmware's MIDI in;
      `:send` (FMutate is the clock master, `FMutate.MIDI` makes the clock) and `:off` drop them.

  Control change, program change and aftertouch go to the firmware's MIDI in on accepted channels; CC 120
  (all sound off) and 123 (all notes off) also let go of the keys this source holds. Messages passed on
  keep their channel. System exclusive, active sensing and reset are dropped.
  """

  @key_low 53
  @key_high 79

  defstruct channel: :all,
            notes: :keys,
            bend: false,
            clock: :follow,
            status: nil,
            data: [],
            sysex: false,
            held: %{}

  @type clock :: :follow | :send | :off
  @type t :: %__MODULE__{
          channel: :all | 1..16,
          notes: :keys | :firmware,
          bend: boolean(),
          clock: clock(),
          status: nil | byte(),
          data: [byte()],
          sysex: boolean(),
          held: %{optional(byte()) => {:key, 0..26} | :firmware}
        }

  @type input :: {:key, 0..26, :down | :up} | {:midi, binary()}

  @doc "A parser with `opts` (`:channel`, `:notes`, `:bend`, `:clock`)."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: configure(%__MODULE__{}, opts)

  @doc "Change settings, keeping the parser and the held notes."
  @spec configure(t(), keyword()) :: t()
  def configure(%__MODULE__{} = map, opts) do
    Enum.reduce(opts, map, fn
      {:channel, ch}, m when ch == :all or ch in 1..16 ->
        %{m | channel: ch}

      {:notes, mode}, m when mode in [:keys, :firmware] ->
        %{m | notes: mode}

      {:bend, bend}, m when is_boolean(bend) ->
        %{m | bend: bend}

      {:clock, mode}, m when mode in [:follow, :send, :off] ->
        %{m | clock: mode}

      {key, value}, _ ->
        raise ArgumentError, "bad MIDI setting #{inspect(key)}: #{inspect(value)}"
    end)
  end

  @doc "MIDI bytes in, instance inputs out (in order)."
  @spec feed(t(), binary()) :: {[input()], t()}
  def feed(%__MODULE__{} = map, bytes) when is_binary(bytes) do
    {acc, map} = parse(bytes, [], map)
    {Enum.reverse(acc), map}
  end

  @doc """
  Inputs that let go of everything this source holds (the source went away, or settings changed), and the
  state without held notes.
  """
  @spec release_all(t()) :: {[input()], t()}
  def release_all(%__MODULE__{held: held} = map) do
    inputs =
      held
      |> Enum.sort()
      |> Enum.map(fn
        {_note, {:key, k}} -> {:key, k, :up}
        {note, :firmware} -> {:midi, <<0x80, note, 0>>}
      end)

    {inputs, %{map | held: %{}}}
  end

  ## Parser

  defp parse(<<>>, acc, map), do: {acc, map}

  # real-time bytes may come anywhere, even inside another message, and don't touch running status
  defp parse(<<b, rest::binary>>, acc, map) when b >= 0xF8,
    do: parse(rest, realtime(b, acc, map), map)

  defp parse(<<0xF0, rest::binary>>, acc, map),
    do: parse(rest, acc, %{map | sysex: true, status: nil, data: []})

  defp parse(<<0xF7, rest::binary>>, acc, map), do: parse(rest, acc, %{map | sysex: false})

  # inside system exclusive: skip its data; any other status byte ends it
  defp parse(<<b, rest::binary>>, acc, %{sysex: true} = map) when b < 0x80,
    do: parse(rest, acc, map)

  # a status byte (system common ones cancel running status when they complete)
  defp parse(<<b, rest::binary>>, acc, map) when b >= 0x80,
    do: complete(%{map | status: b, data: [], sysex: false}, rest, acc)

  defp parse(<<_d, rest::binary>>, acc, %{status: nil} = map), do: parse(rest, acc, map)

  defp parse(<<d, rest::binary>>, acc, map),
    do: complete(%{map | data: map.data ++ [d]}, rest, acc)

  # a message is complete when it has its data bytes; channel messages keep their status for running status
  defp complete(%{status: st, data: data} = map, rest, acc) do
    if length(data) == data_length(st) do
      {acc, map} = message(st, data, acc, map)
      map = if st >= 0xF0, do: %{map | status: nil, data: []}, else: %{map | data: []}
      parse(rest, acc, map)
    else
      parse(rest, acc, map)
    end
  end

  defp data_length(st) when st in 0xF1..0xF3, do: if(st == 0xF2, do: 2, else: 1)
  defp data_length(st) when st in 0xF4..0xF6, do: 0
  defp data_length(st) when div(st, 16) in [0xC, 0xD], do: 1
  defp data_length(_st), do: 2

  ## Messages

  defp realtime(b, acc, %{clock: :follow}) when b in [0xF8, 0xFA, 0xFB, 0xFC],
    do: [{:midi, <<b>>} | acc]

  defp realtime(_b, acc, _map), do: acc

  # song position: part of following the clock
  defp message(0xF2, [lsb, msb], acc, %{clock: :follow} = map),
    do: {[{:midi, <<0xF2, lsb, msb>>} | acc], map}

  defp message(st, _data, acc, map) when st >= 0xF0, do: {acc, map}

  defp message(st, data, acc, map) do
    if accepts?(map, rem(st, 16) + 1),
      do: channel_message(div(st, 16), st, data, acc, map),
      else: {acc, map}
  end

  defp accepts?(%{channel: :all}, _ch), do: true
  defp accepts?(%{channel: want}, ch), do: want == ch

  # note on (velocity 0 is note off)
  defp channel_message(0x9, st, [note, 0], acc, map), do: note_off(st - 0x10, note, acc, map)

  defp channel_message(0x9, st, [note, vel], acc, map) do
    {acc, map} =
      if Map.has_key?(map.held, note), do: note_off(st - 0x10, note, acc, map), else: {acc, map}

    case target(map, note) do
      {:key, k} = key -> {[{:key, k, :down} | acc], put_in(map.held[note], key)}
      :firmware -> {[{:midi, <<st, note, vel>>} | acc], put_in(map.held[note], :firmware)}
    end
  end

  defp channel_message(0x8, st, [note, _vel], acc, map), do: note_off(st, note, acc, map)

  # pitch bend: wobble, only for firmwares that bend
  defp channel_message(0xE, st, [lsb, msb], acc, %{bend: true} = map),
    do: {[{:midi, <<st, lsb, msb>>} | acc], map}

  defp channel_message(0xE, _st, _data, acc, map), do: {acc, map}

  # all sound off / all notes off: let go of this source's keys too
  defp channel_message(0xB, st, [cc, v], acc, map) when cc in [120, 123] do
    {ups, map} = release_all(map)
    {[{:midi, <<st, cc, v>>} | Enum.reverse(ups, acc)], map}
  end

  defp channel_message(_kind, st, data, acc, map),
    do: {[{:midi, IO.iodata_to_binary([st | data])} | acc], map}

  defp note_off(st, note, acc, map) do
    case Map.pop(map.held, note) do
      {{:key, k}, held} ->
        {[{:key, k, :up} | acc], %{map | held: held}}

      {:firmware, held} ->
        {[{:midi, <<st, note, 0>>} | acc], %{map | held: held}}

      # not held by this source (on before a settings change, or a stray off): pass it to where it would go
      {nil, _} ->
        case target(map, note) do
          {:key, k} -> {[{:key, k, :up} | acc], map}
          :firmware -> {[{:midi, <<st, note, 0>>} | acc], map}
        end
    end
  end

  defp target(%{notes: :keys}, note) when note in @key_low..@key_high, do: {:key, note - @key_low}
  defp target(_map, _note), do: :firmware
end
