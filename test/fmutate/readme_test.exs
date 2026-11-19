defmodule FMutate.ReadmeTest do
  # A firmware's README as its synth page draws it: the maker's text without pictures, badges, HTML or
  # Markdown marks, its headings, paragraphs and lists kept, cut at a section boundary.
  use ExUnit.Case, async: true

  alias FMutate.Library.Readme

  defp blocks(md, opts \\ []), do: Readme.extract(md, opts).blocks

  test "pictures, badges, HTML and comments go; the text inside HTML stays" do
    md = """
    <p align="center"><img src="assets/logo.png" width="800" alt="the logo"></p>

    [![License: GPL-3.0](https://img.shields.io/badge/license-GPL-blue.svg)](LICENSE) ![CI](https://ci/badge.svg)

    <p align="center">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="logo.svg">
        <img src="logo-light.svg" alt="Skiff">
      </picture>
    </p>

    <!-- a comment the maker left -->
    <p align="center"><b>A six-track groovebox</b> for the <a href="https://m-vave.com">FM-1</a><br>synths and drums</p>

    <script>alert("no")</script><style>p { color: red }</style>
    Plays **loud** and *soft*, with `SEL` held &amp; more &lt;fun&gt; &#8211; see [the manual](docs/MANUAL.md).
    """

    assert blocks(md) == [
             {:paragraph, "A six-track groovebox for the FM-1\nsynths and drums"},
             {:paragraph, "Plays loud and soft, with SEL held & more <fun> – see the manual."}
           ]
  end

  test "headings (Markdown, setext and HTML), lists and tables are kept; code and link definitions are not" do
    md = """
    <h2 align="center">USB RECORDING</h2>

    What it does
    ============

    - **Six tracks** of SID
    - Speech, made by
      SAM on the unit
      * nested items flatten
    1. numbered too

    ```sh
    ./build.sh --web
    ```

    | Engine | What it is |
    | --- | --- |
    | **HYBRID** | Three oscillators |
    | FMX | Six operators |

    > **Released: 3.5.2**: locked to MIDI clock

    [manual]: https://example.com/manual
    ### Links ###
    """

    assert blocks(md) == [
             {:heading, 2, "USB RECORDING"},
             {:heading, 1, "What it does"},
             {:list,
              [
                "Six tracks of SID",
                "Speech, made by SAM on the unit",
                "nested items flatten",
                "numbered too"
              ]},
             {:list, ["HYBRID — Three oscillators", "FMX — Six operators"]},
             {:paragraph, "Released: 3.5.2: locked to MIDI clock"},
             {:heading, 3, "Links"}
           ]
  end

  test "a first heading that only repeats the firmware's name goes, a longer title stays" do
    assert blocks("# OberVave\n\nA poly.", name: "OberVave (Hub package)") == [
             {:paragraph, "A poly."}
           ]

    assert blocks("# GHOULBOX: FM-1 Dungeon Synth\n\nDark.", name: "GHOULBOX") ==
             [{:heading, 1, "GHOULBOX: FM-1 Dungeon Synth"}, {:paragraph, "Dark."}]
  end

  test "a long README ends at a section boundary, and says it was cut" do
    section = fn title -> "## #{title}\n\n" <> String.duplicate("word ", 120) <> "\n\n" end
    md = "Intro.\n\n" <> section.("One") <> section.("Two") <> section.("Three")

    %{blocks: blocks, truncated: true} = Readme.extract(md, budget: 1300)

    # One and Two fit (about 1200 characters), Three doesn't: no part of Three, and no dangling heading
    assert Enum.filter(blocks, &match?({:heading, _, _}, &1)) == [
             {:heading, 2, "One"},
             {:heading, 2, "Two"}
           ]

    assert List.last(blocks) |> elem(0) == :paragraph

    # Two's heading fits but its text doesn't: the page ends after One, not on Two's heading
    %{blocks: blocks, truncated: true} = Readme.extract(md, budget: 700)

    assert blocks == [
             {:paragraph, "Intro."},
             {:heading, 2, "One"},
             {:paragraph, String.trim(String.duplicate("word ", 120))}
           ]

    assert %{truncated: false} = Readme.extract(md)
  end

  test "a first section longer than the budget is cut at a paragraph, a single huge paragraph at a sentence" do
    para = fn n -> String.duplicate("Sentence #{n} goes on. ", 20) end
    md = Enum.map_join(1..5, "\n\n", para) <> "\n\n## Later\n\nMore."

    %{blocks: blocks, truncated: true} = Readme.extract(md, budget: 1000)
    assert blocks == [{:paragraph, String.trim(para.(1))}, {:paragraph, String.trim(para.(2))}]

    %{blocks: [{:paragraph, text}], truncated: true} =
      Readme.extract(String.duplicate("Long one. ", 300), budget: 100)

    assert String.ends_with?(text, "Long one. …") and String.length(text) <= 102
  end

  test "only the first 64 KB are read, at a line, and invalid bytes and control characters are dropped" do
    big = "Start.\n\n" <> String.duplicate("filler line\n", 10_000)
    %{blocks: [{:paragraph, first} | _], truncated: true} = Readme.extract(big, budget: 1_000_000)
    assert first == "Start."
    assert Readme.extract(big, budget: 1_000_000, scan: 1_000).blocks |> length() == 2

    assert blocks("Bad \xFF\xFE bytes\x07 and &#7; &#x2028;.") == [
             {:paragraph, "Bad bytes and &#7; &#x2028;."}
           ]
  end
end
