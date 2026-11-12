defmodule FMutate.LibraryTest do
  use ExUnit.Case, async: false

  alias FMutate.{Firmware, Fwsc, Library}
  alias FMutate.Library.Catalog

  # the start of a real package (ShineOn 3.0's): its UFW header is all Fwsc.valid?/1 reads
  @fixture Path.expand("../fixtures/my-fork-1.2.fwsc", __DIR__)

  @hub %{
    "updated" => "2026-11-10 07:02 UTC",
    "firmwares" => [
      %{
        "id" => "shineon",
        "name" => "Shine On",
        "author" => "zvenson",
        "lic" => "GPL-3.0",
        "kind" => "chords",
        "vintage" => true,
        "repo" => "zvenson/shineon",
        "pkg" => "fw/shineon-3.0.1.fwsc"
      },
      %{
        "id" => "hortator",
        "name" => "Hortator",
        "author" => "DEADACTIVE",
        "lic" => "GPL-3.0",
        "kind" => ["drums", "dev"],
        "what" => "A drum machine.",
        "version" => "1.0.2",
        "pkg" => "fw/hortator-1.0.1+abc123.fwsc",
        "size" => 1024,
        "sha256" => "00"
      },
      %{"id" => "nopkg", "name" => "No package", "pkg" => nil}
    ]
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_lib_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "catalogue" do
    test "parses the Hub: packages only, version from the package name, tags from kind and flags" do
      [shine, hort] = Catalog.parse_hub(@hub)
      assert hort.version == "1.0.1"
      assert hort.tags == ["drums", "dev"]
      assert hort.url == "https://thefirmwarehub.com/fw/hortator-1.0.1+abc123.fwsc"
      assert hort.backend == :emu and hort.source == :hub and hort.package == nil
      assert shine.tags == ["chords", "vintage"]
      assert shine.repo == "https://github.com/zvenson/shineon"
    end

    test "a native cartridge wins over the Hub's entry; downloaded and imported packages are on the phone",
         %{dir: dir} do
      hub = Catalog.parse_hub(@hub)
      [_, hort] = hub
      File.cp!(@fixture, Catalog.hub_package_path(hort, dir))
      {:ok, _} = Catalog.import_file(@fixture, "my-fork-1.2.fwsc", dir)

      all = Catalog.merge(Firmware.bundled(), hub, dir)
      assert Enum.map(all, & &1.id) == ["obervave", "shineon", "imported:my-fork-1.2.fwsc", "hub:shineon", "hortator"]

      shine = Enum.find(all, &(&1.id == "shineon"))
      assert shine.backend == :native and shine.source == :bundled
      assert shine.tags == ["chords", "vintage"]

      hort = Enum.find(all, &(&1.id == "hortator"))
      assert hort.package == Path.join(dir, "hortator-1.0.1+abc123.fwsc")

      assert Enum.find(Catalog.merge(Firmware.bundled(), hub, Path.join(dir, "empty")), &(&1.id == "hortator")).package == nil
    end

    test "the Hub's package of a native firmware stays runnable as hub:<id>, on the phone once downloaded",
         %{dir: dir} do
      hub = Catalog.parse_hub(@hub)
      variant = Enum.find(Catalog.merge(Firmware.bundled(), hub, dir), &(&1.id == "hub:shineon"))
      assert variant.backend == :emu and variant.source == :hub and variant.package == nil
      assert variant.name == "Shine On (Hub package)"
      assert variant.tags == ["chords", "vintage"]

      File.cp!(@fixture, Catalog.hub_package_path(variant, dir))
      variant = Enum.find(Catalog.merge(Firmware.bundled(), hub, dir), &(&1.id == "hub:shineon"))
      assert variant.package == Path.join(dir, "shineon-3.0.1.fwsc")

      ctx = %{current: "shineon", quarantined: [], emu?: true}
      assert Catalog.status(variant, ctx) == :on_phone
      assert Catalog.status(variant, %{ctx | emu?: false}) == :not_yet
      assert Catalog.status(variant, %{ctx | current: "hub:shineon"}) == :running
    end

    test "status: quarantined over running, native on phone, packages need the emulator" do
      ctx = %{current: "a", quarantined: ["q"], emu?: false}
      native = %Firmware{id: "n", name: "n", version: "1", author: "x", license: "x"}
      pkg = %{native | id: "p", backend: :emu, package: "/x.fwsc"}
      hub = %{pkg | id: "h", package: nil}

      assert Catalog.status(%{native | id: "a"}, ctx) == :running
      assert Catalog.status(%{pkg | id: "q"}, ctx) == :quarantined
      assert Catalog.status(%{native | id: "q"}, %{ctx | current: "q"}) == :quarantined
      assert Catalog.status(native, ctx) == :on_phone
      assert Catalog.status(hub, ctx) == :available
      assert Catalog.status(pkg, ctx) == :not_yet
      assert Catalog.status(pkg, %{ctx | emu?: true}) == :on_phone
    end

    test "names from file names" do
      assert Catalog.name_from_filename("my-fork-1.2.fwsc") == {"my-fork", "1.2"}
      assert Catalog.name_from_filename("Felucca_v1.8.2-beta.fwsc") == {"Felucca", "1.8.2-beta"}
      assert Catalog.name_from_filename("FM-1.fwsc") == {"FM-1", nil}
    end
  end

  describe "import" do
    test "copies a package in with its name from the file name", %{dir: dir} do
      assert {:ok, fw} = Catalog.import_file(@fixture, "content:weird/My Fork-1.2.FWSC", dir)
      assert fw.name == "My Fork" and fw.version == "1.2"
      assert fw.backend == :emu and fw.source == :imported
      assert File.read!(fw.package) == File.read!(@fixture)
      assert [%{id: id}] = Catalog.imported(dir)
      assert id == fw.id
    end

    test "refuses a file that isn't an FM-1 package", %{dir: dir} do
      junk = Path.join(dir, "junk.fwsc")
      File.write!(junk, :binary.copy(<<0>>, 2048))
      assert {:error, :not_fwsc} = Catalog.import_file(junk, "junk.fwsc", dir)
      assert Catalog.imported(dir) == []
      refute Fwsc.valid?(binary_part(File.read!(@fixture), 0, 100))
    end
  end

  describe "the library process" do
    setup %{dir: dir} do
      Application.put_env(:fmutate_app, :data_dir, dir)
      # a fresh cache: no network
      File.write!(Path.join(dir, "hub_catalog.json"), JSON.encode!(@hub))
      start_supervised!(Library)
      on_exit(fn -> Application.delete_env(:fmutate_app, :data_dir) end)
      :ok
    end

    test "serves the merged catalogue from the cache; import, delete, and Firmware.all/0 follows" do
      assert Library.info().updated == "2026-11-10 07:02 UTC"
      assert Enum.map(Firmware.all(), & &1.id) == ["obervave", "shineon", "hub:shineon", "hortator"]

      :ok = Library.subscribe()
      assert {:ok, fw} = Library.import_package(@fixture, "my-fork-1.2.fwsc")
      assert_receive {:library, :changed}
      assert Firmware.get(fw.id).package == fw.package

      assert :ok = Library.delete(fw.id)
      assert Firmware.get(fw.id) == nil
      assert {:error, :not_on_phone} = Library.delete("shineon")
    end

    test "a download that doesn't match the Hub's listing is not kept", %{dir: dir} do
      hort = Enum.find(Firmware.all(), &(&1.id == "hortator"))
      part = Path.join(dir, "x.part")
      File.cp!(@fixture, part)
      assert {:error, :sha256} = Library.verify(hort, part)
      assert {:error, :size} = Library.verify(%{hort | size: 5}, part)
      assert :ok = Library.verify(%{hort | sha256: sha(part)}, part)
    end

    test "only the Hub's entries download, by the catalogue's id" do
      assert {:error, :unknown} = Library.download("shineon")
      assert {:error, :unknown} = Library.download("nope")
    end

    test "how a firmware runs: the cartridge, or its package when the emulator engine is there; flash per backend",
         %{dir: dir} do
      libs = Path.join(dir, "lib")
      File.mkdir_p!(libs)
      for f <- ["libfm1engine.so", "libcart_shineon.so"], do: File.touch!(Path.join(libs, f))
      Application.put_env(:fmutate_app, :native_lib_dir, libs)
      on_exit(fn -> Application.delete_env(:fmutate_app, :native_lib_dir) end)

      variant = Firmware.get("hub:shineon")
      File.cp!(@fixture, Catalog.hub_package_path(variant, FMutate.Paths.packages_dir()))

      assert %{backend: :native, file: cart} = Firmware.runnable("shineon")
      assert cart == Path.join(libs, "libcart_shineon.so")
      # no cartridge in this build
      assert Firmware.runnable("obervave") == nil
      # a package on the phone, but no emulator engine: it doesn't run here yet
      refute Library.emu?()
      assert Firmware.runnable("hub:shineon") == nil
      # not on the phone
      assert Firmware.runnable("hortator") == nil

      File.touch!(Path.join(libs, "libfm1emu.so"))
      assert Library.emu?()
      assert %{backend: :emu, engine: emu, file: pkg} = Firmware.runnable("hub:shineon")
      assert emu == Path.join(libs, "libfm1emu.so") and pkg == Firmware.get("hub:shineon").package

      # the two engines' flash formats differ: the same id never shares a file across backends
      native = FMutate.Paths.flash("a", "shineon", :native)
      emu_flash = FMutate.Paths.flash("a", "shineon", :emu)
      assert native == Path.join([dir, "flash", "a", "shineon.bin"])
      assert emu_flash == Path.join([dir, "flash", "a", "emu", "shineon.bin"])
    end
  end

  describe "checking the Hub" do
    test "within a day of the last read: when it was and when the next may go out" do
      # read at 09:30 UTC
      at = DateTime.to_unix(~U[2026-11-12 09:30:00Z])
      assert Library.check_note(at, at + 60, &utc/1) == "Checked today · next check after 09:30"
      assert Library.check_note(at, DateTime.to_unix(~U[2026-11-13 09:29:59Z]), &utc/1) ==
               "Checked yesterday · next check after 09:30"
    end

    test "nothing to say once a check would go out, or before the first read" do
      at = DateTime.to_unix(~U[2026-11-12 09:30:00Z])
      assert Library.check_note(at, at + 24 * 3600, &utc/1) == nil
      assert Library.check_note(nil, at, &utc/1) == nil
    end
  end

  defp utc(secs), do: secs |> DateTime.from_unix!() |> DateTime.to_naive()

  defp sha(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end
