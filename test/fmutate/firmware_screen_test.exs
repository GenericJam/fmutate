defmodule FMutate.FirmwareScreenTest do
  # A firmware's synth page, opened from its library card: who made it and where their repository is, the
  # Hub's card text and the README as theirs, the rest of a long README in the browser, and what it shows
  # offline. Runs the real library and instance (native/build_host.sh); a local server stands in for GitHub.
  use Mob.ScreenCase, async: false

  alias FMutate.{FirmwareScreen, Instance, Library, LibraryScreen}
  alias FMutate.Test.FixtureServer

  @moduletag :engine

  @what "A deep synth for the FM-1, with a sequencer."
  @readme "# Felucca\n\n![screens](docs/s.png)\n\nOpen-source firmware for the **M-VAVE FM-1**.\n\n- Web installer\n- Editor\n"
  @readme_path "/hugelton/Felucca/v1.8.2/README.md"
  @obervave_path "/zvenson/obervave/792535d23ef4265475b1c2f9895ca30e857fe596/README.md"

  @hub %{
    "updated" => "2026-11-19 21:26 UTC",
    "firmwares" => [
      %{
        "id" => "felucca",
        "name" => "Felucca",
        "author" => "hugelton",
        "repo" => "hugelton/Felucca",
        "tag" => "v1.8.2",
        "what" => @what,
        "lic" => "GPL-3.0",
        "pkg" => "fw/felucca-1.8.2.fwsc"
      }
    ]
  }

  setup do
    unless File.exists?(FMutate.Paths.engine_bin()),
      do: raise("run native/build_host.sh first: no #{FMutate.Paths.engine_bin()}")

    # (Mob.ScreenCase gives each test a throwaway data dir, MOB_DATA_DIR, which FMutate.Paths reads too)
    dir = FMutate.Paths.data_dir()
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hub_catalog.json"), JSON.encode!(@hub))
    server = FixtureServer.start()
    prev = Application.get_env(:fmutate_app, :readme_base)
    Application.put_env(:fmutate_app, :readme_base, server.url)
    test = self()
    Application.put_env(:fmutate_app, :open_url, &send(test, {:opened, &1}))

    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)
    start_supervised!(Library)
    start_supervised!({Instance, id: "a"}, id: {:instance, "a"})

    on_exit(fn ->
      FixtureServer.stop(server)
      Application.put_env(:fmutate_app, :readme_base, prev)
      Application.delete_env(:fmutate_app, :open_url)
    end)

    {:ok, server: server}
  end

  defp open(id), do: FirmwareScreen |> mount_screen(%{id: id}) |> render_async()

  defp press(view, %{props: %{on_tap: {_pid, tag}}}), do: render_info(view, {:tap, tag})

  test "a tap on a card opens that firmware's synth page" do
    view = mount_screen(LibraryScreen)
    card = find(view, :box, on_tap: {self(), {:open, "felucca"}})
    assert card

    view = press(view, card)
    assert navigated_to(view) == FirmwareScreen
    assert {:push, FirmwareScreen, %{id: "felucca"}} = view.socket.__mob__.nav_action
  end

  test "the page names the maker, links their repository, and gives the card text and README as theirs",
       %{server: server} do
    FixtureServer.route(server, @readme_path, {200, [], @readme})
    view = open("felucca")
    text = text(view)

    assert text =~ "by hugelton"
    assert text =~ "hugelton’s card text on The Firmware Hub " <> @what
    assert text =~ "hugelton’s description, from github.com/hugelton/Felucca at v1.8.2"
    assert text =~ "Open-source firmware for the M-VAVE FM-1."
    assert text =~ "Web installer"
    assert text =~ "Firmware list: The Firmware Hub – https://thefirmwarehub.com (CC-BY-4.0)"
    refute text =~ "docs/s.png"
    # all of it fits: no link to the rest
    refute find(view, :button, text: "Read the full README ↗")
    assert_renderable(view)

    press(view, find(view, :button, text: "github.com/hugelton/Felucca ↗"))
    assert_received {:opened, "https://github.com/hugelton/Felucca"}

    press(
      view,
      find(view, :text,
        text: "hugelton’s description, from github.com/hugelton/Felucca at v1.8.2"
      )
    )

    assert_received {:opened, "https://github.com/hugelton/Felucca"}
  end

  test "a long README stops at a section and opens the rest in the browser, at the pinned ref", %{
    server: server
  } do
    sections =
      Enum.map_join(
        1..12,
        "\n\n",
        &"## Part #{&1}\n\n#{String.duplicate("Some words here. ", 30)}"
      )

    FixtureServer.route(server, @readme_path, {200, [], "Intro.\n\n" <> sections})
    view = open("felucca")

    assert text(view) =~ "Part 1"
    refute text(view) =~ "Part 12"
    press(view, find(view, :button, text: "Read the full README ↗"))
    assert_received {:opened, "https://github.com/hugelton/Felucca/blob/v1.8.2/README.md"}
  end

  test "offline with nothing read before: the card text stays, with a note and the link", %{
    server: server
  } do
    FixtureServer.stop(server)
    view = open("felucca")

    assert text(view) =~ @what
    assert text(view) =~ "Couldn’t read the README (offline?)"
    assert find(view, :button, text: "Read the full README ↗")
  end

  test "offline with a copy read before: the copy at once, then said to be from that day", %{
    server: server
  } do
    FixtureServer.route(server, @readme_path, {200, [{"etag", ~s("1")}], @readme})
    open("felucca")
    FixtureServer.stop(server)

    view = mount_screen(FirmwareScreen, %{id: "felucca"})
    assert text(view) =~ "Open-source firmware for the M-VAVE FM-1."
    refute text(view) =~ "Offline"

    view = render_async(view)
    assert text(view) =~ "Open-source firmware for the M-VAVE FM-1."
    assert text(view) =~ ~r/Offline: the README as read on \d{4}-\d{2}-\d{2}\./
  end

  test "a built-in firmware reads the README at the commit its cartridge is built from", %{
    server: server
  } do
    FixtureServer.route(server, @obervave_path, {200, [], "# OberVave\n\nAn 8-voice poly."})
    view = open("obervave")

    assert text(view) =~ "zvenson’s description, from github.com/zvenson/obervave at 792535d"
    assert text(view) =~ "An 8-voice poly."
    assert [{@obervave_path, _}] = FixtureServer.requests(server)
  end

  test "an imported package says it carries no description" do
    {:ok, fw} =
      Library.import_package(Path.expand("test/fixtures/my-fork-1.2.fwsc"), "my-fork-1.2.fwsc")

    view = open(fw.id)

    assert text(view) =~ "An imported package carries no description"
    refute text(view) =~ "README"
  end
end
