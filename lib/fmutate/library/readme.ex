defmodule FMutate.Library.Readme do
  @moduledoc """
  A firmware's README (Markdown, often with HTML in it) as plain blocks a screen draws with text components:
  Mob has no Markdown or HTML view, and a README is its maker's text, untrusted, so nothing in it is run or
  loaded. `extract/2`:

    * reads at most `scan` bytes (64 KB) of it, as UTF-8 (invalid bytes and control characters dropped);
    * drops pictures, badges (a link around a picture), HTML comments and `<picture>`, `<script>`, `<style>`,
      `<svg>`, media and frames with what is in them, code blocks, link reference definitions, and every
      other HTML tag (its text stays); a link keeps its text, inline code and emphasis lose their marks, the
      common HTML entities are decoded;
    * keeps headings (Markdown and `<h1>`…`<h6>`, cut at 300 characters), paragraphs, lists (nested ones
      flattened) and tables (a row becomes a list item, its cells joined with " — ");
    * drops a first heading that only repeats the firmware's `name`;
    * stops at a section boundary (before a heading) once the text passes `budget` characters (4000), or
      inside the first section at a paragraph when that section alone is longer; `truncated` then says the
      rest is in the full README. Every block and list item counts at least 20 characters, so at most 200 are
      drawn; every pattern looks a bounded distance ahead, so a hostile README can't make it backtrack for long.
  """

  @type block :: {:heading, 1..6, String.t()} | {:paragraph, String.t()} | {:list, [String.t()]}
  @type t :: %{blocks: [block], truncated: boolean}

  @scan 65_536
  @budget 4000
  @heading_max 300
  # a hard line break (`<br>`) survives paragraph joining as this (a private-use character, not whitespace, so
  # trimming keeps it; dropped from the input), then becomes "\n"
  @br "\uE000"

  @drop_with_content ~w(picture script style svg video audio iframe object noscript template)
  @tags ~w(a abbr article b big blockquote br button caption center cite code dd del details dfn div dl dt em
           figcaption figure font footer form h1 h2 h3 h4 h5 h6 header hr i img input ins kbd label li main mark
           nav ol p pre q s samp section small source span strike strong sub summary sup table tbody td tfoot th
           thead tr tt u ul var)

  @doc "The README `text` as blocks (see the module doc). Options: `name`, `budget`, `scan`."
  @spec extract(binary, keyword) :: t
  def extract(text, opts \\ []) when is_binary(text) do
    scan = Keyword.get(opts, :scan, @scan)
    budget = Keyword.get(opts, :budget, @budget)
    {text, cut?} = head(text, scan)

    blocks =
      text
      |> clean()
      |> html()
      |> String.split("\n")
      |> parse()
      |> Enum.flat_map(&inline_block/1)
      |> drop_title(opts[:name])

    {kept, truncated?} = fit(blocks, budget)
    %{blocks: kept, truncated: truncated? or cut?}
  end

  ## Input

  # the first `scan` bytes, ended at a line (a long README is read only so far: the page shows its start)
  defp head(text, scan) when byte_size(text) <= scan, do: {text, false}

  defp head(text, scan) do
    part = binary_part(text, 0, scan)

    case :binary.matches(part, "\n") do
      [] -> {part, true}
      matches -> {binary_part(part, 0, elem(List.last(matches), 0)), true}
    end
  end

  defp clean(text) do
    text
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
    |> String.replace(["\r\n", "\r"], "\n")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F\x{2028}\x{2029}\x{E000}]/u, "")
  end

  ## HTML: blocks become Markdown blocks, everything else loses its tags

  defp html(text) do
    text = Regex.replace(~r/<!--.*?(-->|\z)/s, text, "")

    text =
      Enum.reduce(@drop_with_content, text, fn tag, acc ->
        Regex.replace(~r/<#{tag}\b[^>]*>.*?(<\/#{tag}\s*>|\z)/is, acc, "")
      end)

    text
    |> then(
      &Regex.replace(~r/<h([1-6])\b[^>]*>(.{0,500}?)<\/h\1\s*>/is, &1, fn _, n, inner ->
        "\n\n" <>
          String.duplicate("#", String.to_integer(n)) <>
          " " <> String.replace(inner, "\n", " ") <> "\n\n"
      end)
    )
    |> then(&Regex.replace(~r/<br\s*\/?>/i, &1, @br))
    |> then(&Regex.replace(~r/<li\b[^>]*>/i, &1, "\n- "))
    |> then(
      &Regex.replace(
        ~r/<\/?(p|div|center|ul|ol|table|tr|blockquote|details|section|figure|pre)\b[^>]*>|<hr\b[^>]*>/i,
        &1,
        "\n\n"
      )
    )
    |> then(&Regex.replace(~r/<(https?:\/\/[^>\s]+)>/, &1, "\\1"))
    |> then(&Regex.replace(~r/<\/?(?:#{Enum.join(@tags, "|")})\b[^>]*\/?>/i, &1, ""))
  end

  ## Markdown blocks

  defp parse(lines), do: parse(lines, [], nil)

  defp parse([], acc, cur), do: Enum.reverse(push(acc, cur))

  defp parse([line | rest], acc, cur) do
    line = strip_quote(line)
    step(kind(line, cur), line, rest, acc, cur)
  end

  defp kind(line, cur) do
    cond do
      fence?(line) -> :fence
      boundary?(line, cur) -> :boundary
      m = Regex.run(~r/^\s{0,3}(\#{1,6})\s+(.*)$/, line) -> {:heading, m}
      setext?(cur, line) -> :setext
      table_row?(line) -> :table
      m = Regex.run(~r/^\s*(?:[-*+]|\d{1,9}[.)])\s+(.*)$/, line) -> {:item, m}
      true -> :text
    end
  end

  defp step(:fence, line, rest, acc, cur),
    do: parse(skip_fence(rest, fence_mark(line)), push(acc, cur), nil)

  defp step(:boundary, _line, rest, acc, cur), do: parse(rest, push(acc, cur), nil)
  defp step(:table, line, rest, acc, cur), do: parse_table([line | rest], push(acc, cur))
  defp step(:text, line, rest, acc, cur), do: parse(rest, acc, continue(cur, String.trim(line)))

  # (the closing #s trimmed without a regex: a long line of them can't make it backtrack)
  defp step({:heading, [_, hashes, title]}, _line, rest, acc, cur) do
    title = title |> String.trim_trailing() |> String.trim_trailing("#") |> String.trim_trailing()
    parse(rest, [{:heading, String.length(hashes), title} | push(acc, cur)], nil)
  end

  defp step(:setext, line, rest, acc, {:paragraph, lines}) do
    level = if String.contains?(line, "="), do: 1, else: 2
    parse(rest, [{:heading, level, Enum.join(Enum.reverse(lines), " ")} | acc], nil)
  end

  defp step({:item, [_, item]}, _line, rest, acc, {:list, items}),
    do: parse(rest, acc, {:list, [item | items]})

  defp step({:item, [_, item]}, _line, rest, acc, cur),
    do: parse(rest, push(acc, cur), {:list, [item]})

  # a blank line, a link reference definition or a horizontal rule (not a setext underline) ends a block
  defp boundary?(line, cur) do
    blank?(line) or String.match?(line, ~r/^\s*\[[^\]]+\]:\s*\S/) or
      (String.match?(line, ~r/^\s*([-*_]\s*){3,}$/) and not setext?(cur, line))
  end

  defp continue({:list, [item | items]}, text), do: {:list, [item <> " " <> text | items]}
  defp continue({:paragraph, lines}, text), do: {:paragraph, [text | lines]}
  defp continue(nil, text), do: {:paragraph, [text]}

  defp push(acc, nil), do: acc

  defp push(acc, {:paragraph, lines}),
    do: [{:paragraph, Enum.join(Enum.reverse(lines), " ")} | acc]

  defp push(acc, {:list, items}), do: [{:list, Enum.reverse(items)} | acc]

  defp strip_quote(line), do: Regex.replace(~r/^\s{0,3}(>\s?)+/, line, "")

  defp blank?(line), do: String.trim(line) == ""

  defp fence?(line), do: String.match?(line, ~r/^\s{0,3}(```|~~~)/)
  defp fence_mark(line), do: if(String.contains?(line, "~~~"), do: "~~~", else: "```")

  defp skip_fence([], _mark), do: []

  defp skip_fence([line | rest], mark) do
    if String.starts_with?(String.trim_leading(line), mark),
      do: rest,
      else: skip_fence(rest, mark)
  end

  defp setext?({:paragraph, _}, line), do: String.match?(line, ~r/^\s{0,3}(=+|-+)\s*$/)
  defp setext?(_cur, _line), do: false

  defp table_row?(line), do: String.match?(line, ~r/^\s*\|.*\|\s*$/)
  defp separator?(line), do: String.match?(line, ~r/^\s*\|?(\s*:?-+:?\s*\|)+\s*:?-*:?\s*$/)

  # a table: its rows (header and separator dropped) as one list
  defp parse_table(lines, acc) do
    {rows, rest} = Enum.split_while(lines, &table_row?/1)

    rows =
      case rows do
        [_header, sep | body] -> if separator?(sep), do: body, else: rows
        _ -> rows
      end

    items =
      for row <- rows, not separator?(row) do
        row
        |> String.trim()
        |> String.trim_leading("|")
        |> String.trim_trailing("|")
        |> String.split("|")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" — ")
      end

    parse(rest, [{:list, items} | acc], nil)
  end

  ## Inline

  # (a heading is cut as a paragraph would be, at @heading_max characters: ATX and setext alike)
  defp inline_block({:heading, level, text}) do
    case inline(text) do
      "" -> []
      t -> [{:heading, level, t |> String.replace("\n", " ") |> cut_text(@heading_max)}]
    end
  end

  defp inline_block({:paragraph, text}) do
    case inline(text) do
      "" -> []
      t -> [{:paragraph, t}]
    end
  end

  defp inline_block({:list, items}) do
    case items |> Enum.map(&inline/1) |> Enum.reject(&(&1 == "")) do
      [] -> []
      items -> [{:list, items}]
    end
  end

  @doc false
  # one block's text without Markdown marks: "" when nothing readable is left (a row of badges)
  def inline(text) do
    text =
      text
      |> then(&Regex.replace(~r/!\[[^\]]{0,300}\]\([^)]{0,1000}\)/, &1, ""))
      |> then(&Regex.replace(~r/!\[[^\]]{0,300}\]\[[^\]]{0,300}\]/, &1, ""))
      |> then(&Regex.replace(~r/\[([^\]]{0,300})\]\([^)]{0,1000}\)/, &1, "\\1"))
      |> then(&Regex.replace(~r/\[([^\]]{1,300})\]\[[^\]]{0,300}\]/, &1, "\\1"))
      |> then(&Regex.replace(~r/`{1,16}([^`]{1,300})`{1,16}/, &1, "\\1"))
      # (spans bounded: an opener without a closer must not rescan the rest of a hostile paragraph)
      |> then(&Regex.replace(~r/(\*\*|__)(?=\S)(.{1,300}?)(?<=\S)\1/, &1, "\\2"))
      |> then(&Regex.replace(~r/(?<![\w*])\*(?=\S)(.{1,300}?)(?<=\S)\*(?![\w*])/, &1, "\\1"))
      |> then(&Regex.replace(~r/(?<!\w)_(?=\S)(.{1,300}?)(?<=\S)_(?!\w)/, &1, "\\1"))
      |> then(&Regex.replace(~r/~~(.{1,300}?)~~/, &1, "\\1"))
      |> entities()
      |> then(&Regex.replace(~r/[ \t\n]+/, &1, " "))
      |> then(&Regex.replace(~r/[ \t\n]*#{@br}[ \t\n]*/u, &1, "\n"))
      |> String.trim()

    if String.match?(text, ~r/[\p{L}\p{N}]/u), do: text, else: ""
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "middot" => "·",
    "mdash" => "—",
    "ndash" => "–",
    "hellip" => "…",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "rarr" => "→",
    "larr" => "←",
    "times" => "×",
    "bull" => "•"
  }

  defp entities(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]{2,8});/, text, fn whole, name ->
      case name do
        "#x" <> hex -> codepoint(String.to_integer(hex, 16), whole)
        "#" <> dec -> codepoint(String.to_integer(dec), whole)
        _ -> Map.get(@entities, name, whole)
      end
    end)
  end

  # (no control characters, line separators, surrogates or non-characters back in through an entity)
  defp codepoint(cp, _whole)
       when cp in 0x20..0x7E or cp in 0xA0..0x2027 or cp in 0x202A..0xD7FF or cp in 0xE001..0xFFFD or
              cp in 0x10000..0x10FFFF,
       do: <<cp::utf8>>

  defp codepoint(_cp, whole), do: whole

  ## Shape

  # ("OberVave" under "OberVave (Hub package)" too)
  defp drop_title([{:heading, _, title} | rest] = blocks, name) when is_binary(name) do
    t = normal(title)
    if t != "" and String.starts_with?(normal(name), t), do: rest, else: blocks
  end

  defp drop_title(blocks, _name), do: blocks

  defp normal(text), do: text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]/u, "")

  # the blocks that fit `budget` characters, ended at a section boundary, and whether any were left out
  defp fit(blocks, budget) do
    {kept, rest} = take_budget(blocks, budget, 0, [])

    case rest do
      [] ->
        {kept, false}

      _ ->
        kept = section_cut(kept, budget)
        {kept |> drop_trailing_headings() |> first_block(blocks, budget), true}
    end
  end

  defp take_budget([], _budget, _used, acc), do: {Enum.reverse(acc), []}

  defp take_budget([block | rest] = all, budget, used, acc) do
    n = size(block)

    if used + n > budget,
      do: {Enum.reverse(acc), all},
      else: take_budget(rest, budget, used + n, [block | acc])
  end

  # end before the last heading kept, unless that leaves less than a quarter of the budget (the first
  # section is long: end at a paragraph inside it)
  defp section_cut(kept, budget) do
    last_heading =
      kept
      |> Enum.with_index()
      |> Enum.filter(&match?({{:heading, _, _}, i} when i > 0, &1))
      |> List.last()

    case last_heading do
      {_, i} ->
        before = Enum.take(kept, i)
        if Enum.sum_by(before, &size/1) >= div(budget, 4), do: before, else: kept

      nil ->
        kept
    end
  end

  defp drop_trailing_headings(kept) do
    kept |> Enum.reverse() |> Enum.drop_while(&match?({:heading, _, _}, &1)) |> Enum.reverse()
  end

  # nothing fits (one block longer than the budget): that block, cut at a sentence
  defp first_block([], [first | _], budget), do: [shorten(first, budget)]
  defp first_block(kept, _blocks, _budget), do: kept

  defp shorten({:paragraph, text}, budget), do: {:paragraph, cut_text(text, budget)}
  defp shorten({:list, items}, budget), do: {:list, elem(take_items(items, budget), 0)}
  defp shorten({:heading, level, text}, budget), do: {:heading, level, cut_text(text, budget)}

  defp take_items(items, budget) do
    Enum.reduce_while(items, {[], 0}, fn item, {acc, used} ->
      if used + item_size(item) > budget and acc != [],
        do: {:halt, {acc, used}},
        else: {:cont, {acc ++ [cut_text(item, budget)], used + item_size(item)}}
    end)
  end

  defp cut_text(text, budget) do
    if String.length(text) <= budget do
      text
    else
      part = String.slice(text, 0, budget)

      case Regex.run(~r/^(.*[.!?])\s/su, part) do
        [_, sentence] -> sentence <> " …"
        _ -> part <> "…"
      end
    end
  end

  # (every block and list item costs at least 20 characters, so a README of tiny blocks still makes a
  # bounded number of text components: 200 at most)
  defp size({:heading, _, text}), do: max(String.length(text), 20)
  defp size({:paragraph, text}), do: max(String.length(text), 20)
  defp size({:list, items}), do: Enum.sum_by(items, &item_size/1)

  defp item_size(item), do: max(String.length(item), 20)
end
