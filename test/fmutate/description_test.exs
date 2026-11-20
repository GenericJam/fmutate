defmodule FMutate.DescriptionTest do
  # Where a synth page's fuller description comes from: the README at the ref the build or package comes from,
  # read again conditionally, the phone's copy when offline, nothing (the card text) when neither. A local
  # server stands in for raw.githubusercontent.com.
  use ExUnit.Case, async: false

  alias FMutate.Firmware
  alias FMutate.Library.{Catalog, Description}
  alias FMutate.Test.FixtureServer

  @readme "# Felucca\n\nOpen-source firmware for the **M-VAVE FM-1**.\n\n## Install\n\nUse the web installer.\n"
  @path "/hugelton/Felucca/v1.8.2/README.md"

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_desc_#{System.unique_integer([:positive])}")
    Application.put_env(:fmutate_app, :data_dir, dir)
    server = FixtureServer.start()
    prev = Application.get_env(:fmutate_app, :readme_base)
    Application.put_env(:fmutate_app, :readme_base, server.url)

    on_exit(fn ->
      FixtureServer.stop(server)
      Application.put_env(:fmutate_app, :readme_base, prev)
      Application.delete_env(:fmutate_app, :data_dir)
      File.rm_rf(dir)
    end)

    {:ok, server: server}
  end

  defp fw(fields \\ []) do
    struct!(
      %Firmware{
        id: "felucca",
        name: "Felucca",
        version: "1.8.2",
        author: "hugelton",
        license: "GPL-3.0",
        source: :hub
      },
      Keyword.merge([repo: "https://github.com/hugelton/Felucca", ref: "v1.8.2"], fields)
    )
  end

  # a README answered with an ETag, and 304 to a request that has it
  defp etagged(body, etag) do
    fn headers ->
      if headers["if-none-match"] == etag,
        do: {304, [{"etag", etag}], ""},
        else: {200, [{"etag", etag}], body}
    end
  end

  test "the README is read at the ref the catalogue pins, and its text shown", %{server: server} do
    FixtureServer.route(server, @path, {200, [], @readme})

    assert %{
             status: :fresh,
             readme: %{blocks: blocks},
             source: %{repo: "hugelton/Felucca", ref: "v1.8.2"}
           } =
             Description.load(fw())

    assert blocks == [
             {:paragraph, "Open-source firmware for the M-VAVE FM-1."},
             {:heading, 2, "Install"},
             {:paragraph, "Use the web installer."}
           ]

    assert [{@path, _}] = FixtureServer.requests(server)
  end

  test "without a pinned ref the default branch's README is read" do
    server = FixtureServer.start(%{"/hugelton/Felucca/HEAD/README.md" => {200, [], "Hello."}})
    Application.put_env(:fmutate_app, :readme_base, server.url)

    assert %{status: :fresh, readme: %{blocks: [{:paragraph, "Hello."}]}} =
             Description.load(fw(ref: nil))

    FixtureServer.stop(server)
  end

  test "read again, it asks with the cached ETag; a 304 shows the cached copy", %{server: server} do
    FixtureServer.route(server, @path, etagged(@readme, ~s("v1")))
    first = Description.load(fw())

    assert %{status: :fresh, readme: readme} = Description.load(fw())
    assert readme == first.readme
    assert [{_, first_headers}, {_, second_headers}] = FixtureServer.requests(server)
    refute Map.has_key?(first_headers, "if-none-match")
    assert second_headers["if-none-match"] == ~s("v1")
  end

  test "a changed README replaces the cached copy", %{server: server} do
    FixtureServer.route(server, @path, etagged(@readme, ~s("v1")))
    Description.load(fw())
    FixtureServer.route(server, @path, etagged("Rewritten.", ~s("v2")))

    assert %{status: :fresh, readme: %{blocks: [{:paragraph, "Rewritten."}]}} =
             Description.load(fw())

    assert %{status: :cached, readme: %{blocks: [{:paragraph, "Rewritten."}]}} =
             Description.cached(fw())
  end

  test "offline: the copy read before, with when it was read; never read: missing", %{
    server: server
  } do
    FixtureServer.route(
      server,
      @path,
      {200, [{"last-modified", "Wed, 18 Nov 2026 10:00:00 GMT"}], @readme}
    )

    before = System.os_time(:second)
    Description.load(fw())
    FixtureServer.stop(server)

    assert %{
             status: :cached,
             fetched_at: at,
             readme: %{blocks: [_, _, _]},
             error: {:failed_connect, _}
           } =
             Description.load(fw())

    assert at >= before
    assert %{status: :missing, readme: nil} = Description.load(fw(ref: "v1.9"))
  end

  test "readme.md when README.md is missing; neither: missing", %{server: server} do
    FixtureServer.route(server, "/hugelton/Felucca/v1.8.2/readme.md", {200, [], "Lower case."})

    assert %{status: :fresh, file: "readme.md", readme: %{blocks: [{:paragraph, "Lower case."}]}} =
             Description.load(fw())

    assert Description.page_url(Description.source(fw()), "readme.md") ==
             "https://github.com/hugelton/Felucca/blob/v1.8.2/readme.md"

    assert %{status: :missing, error: {:http, 404}} = Description.load(fw(ref: "v0.1"))
  end

  test "a README over 512 KB isn't read", %{server: server} do
    FixtureServer.route(server, @path, {200, [], String.duplicate("x", 524_289)})
    assert %{status: :missing, error: :size} = Description.load(fw())
  end

  test "nothing to read without a GitHub repository; a repository or ref that isn't one is refused" do
    assert %{status: :none} = Description.load(fw(repo: nil))
    assert %{status: :none} = Description.load(fw(repo: "https://felucca.example.com"))
    assert Description.source(fw(repo: "https://github.com/../etc")) == nil
    assert Description.source(fw(ref: "../../x")).ref == nil
  end

  test "the catalogue gives each firmware the ref its package was built from and the Hub's picture" do
    hub = %{
      "firmwares" => [
        %{
          "id" => "melodee",
          "pkg" => "fw/melodee-1.6.1.fwsc",
          "repo" => "keremimo/melodee",
          "tag" => "v1.6.1",
          "card" => "fw/cards/melodee-1.w640.webp",
          "provenance" => %{"repo" => "keremimo/melodee", "commit" => "165d177a"}
        },
        %{
          "id" => "sloop",
          "pkg" => "fw/sloop-2.8.5.fwsc",
          "repo" => "isod89/sloop-fm1",
          "tag" => "v2.8.5"
        },
        %{
          "id" => "zp12",
          "pkg" => "fw/zp12-2.5.fwsc",
          "repo" => "zvenson/zp12",
          "card" => "https://elsewhere/x.png"
        }
      ]
    }

    assert [melodee, sloop, zp12] = Catalog.parse_hub(hub)

    assert {melodee.ref, melodee.picture} ==
             {"165d177a", "https://thefirmwarehub.com/fw/cards/melodee-1.w640.webp"}

    assert sloop.ref == "v2.8.5" and sloop.picture == nil
    assert zp12.ref == nil and zp12.picture == nil

    # a built-in firmware keeps the commit its cartridge is built from, under the Hub's entry for it
    [obervave | _] =
      Catalog.merge(
        Firmware.bundled(),
        Catalog.parse_hub(%{"firmwares" => [hub_obervave()]}),
        "/nonexistent"
      )

    assert {obervave.repo, obervave.ref} ==
             {"https://github.com/zvenson/obervave", "792535d23ef4265475b1c2f9895ca30e857fe596"}
  end

  defp hub_obervave,
    do: %{
      "id" => "obervave",
      "pkg" => "fw/obervave-3.5.2.fwsc",
      "repo" => "zvenson/obervave",
      "tag" => "v3.5.2"
    }

  test "the card picture is read once, then from the phone", %{server: server} do
    FixtureServer.route(server, "/fw/cards/felucca-1.w640.webp", {200, [], "RIFF....WEBP"})
    fw = fw(picture: server.url <> "fw/cards/felucca-1.w640.webp")

    assert Description.cached_picture(fw) == nil
    assert {:ok, path} = Description.picture(fw)
    assert File.read!(path) == "RIFF....WEBP" and Path.extname(path) == ".webp"
    FixtureServer.stop(server)
    assert {:ok, ^path} = Description.picture(fw)
    assert Description.cached_picture(fw) == path
    assert Description.picture(fw(picture: nil)) == :none
  end
end
