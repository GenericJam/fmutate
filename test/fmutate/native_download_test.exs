defmodule FMutate.NativeDownloadTest do
  # A Hub firmware the cartridge index has made native, chosen on an instance before its cartridge is on the
  # phone: the instance downloads it, then starts it in the real engine; if the download fails, the firmware's
  # Hub package runs in the emulator instead, and the native one stays the saved choice.
  use ExUnit.Case, async: false

  alias FMutate.{Firmware, Instance, Library, Paths}
  alias FMutate.Library.Catalog

  @moduletag :emu

  @platform "android-arm64-v8a"
  # the downloaded cartridge: any cartridge of this engine does (a bundled one's bytes, served as dinghy's;
  # the Hub's Dinghy is built by fmutate-cartridges, not here)
  @cart Path.expand("native/build/host/libcart_shineon.so")
  @emu Path.expand("native/build/host/libfm1emu.so")
  @package Path.expand("native/build/packages/dinghy.fwsc")

  unless File.exists?(@cart) and File.exists?(@emu) and File.exists?(@package) do
    @moduletag skip: "needs #{@cart} (native/build_host.sh), #{@emu} and #{@package} (native/build_emu.sh)"
  end

  @hub %{
    "updated" => "2026-11-14 03:00 UTC",
    "firmwares" => [%{"id" => "dinghy", "name" => "Dinghy", "author" => "zvenson", "pkg" => "fw/dinghy-0.5.fwsc"}]
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_natdl_#{System.unique_integer([:positive])}")
    www = Path.join(dir, "www")
    File.mkdir_p!(www)
    Application.put_env(:fmutate_app, :data_dir, dir)
    File.write!(Path.join(dir, "hub_catalog.json"), JSON.encode!(@hub))

    # the cartridge on a local server, in a signed index already on the phone (nothing fetches it again)
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    prev = Application.get_env(:fmutate_app, :cartridges)
    Application.put_env(:fmutate_app, :cartridges, index_url: nil, public_key: Base.encode64(pub), platform: @platform)
    File.cp!(@cart, Path.join(www, "dinghy.so"))
    :ok = :inets.start(:temporary) |> then(&if(&1 == {:error, {:already_started, :inets}}, do: :ok, else: &1))

    {:ok, httpd} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"cartridges",
        server_root: to_charlist(dir),
        document_root: to_charlist(www)
      )

    url = "http://127.0.0.1:#{:httpd.info(httpd)[:port]}/dinghy.so"
    write_index(url, File.read!(@cart), priv)
    File.write!(Paths.instance_state("a"), :erlang.term_to_binary(%{firmware: "dinghy"}))

    start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
    start_supervised!(FMutate.Audio)
    start_supervised!(Library)

    on_exit(fn ->
      :inets.stop(:httpd, httpd)
      Application.delete_env(:fmutate_app, :data_dir)
      Application.put_env(:fmutate_app, :cartridges, prev)
      File.rm_rf(dir)
    end)

    {:ok, www: www}
  end

  defp write_index(url, bytes, priv) do
    sign = &Base.encode64(:crypto.sign(:eddsa, :none, &1, [priv, :ed25519]))

    asset = %{
      "url" => url,
      "size" => byte_size(bytes),
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      "sig" => sign.(bytes)
    }

    body =
      JSON.encode!(%{
        "schema" => 1,
        "engine_abi" => 1,
        "generated" => "2026-11-14T03:00:00Z",
        "firmwares" => [%{"id" => "dinghy", "name" => "Dinghy", "version" => "0.5", "assets" => %{@platform => asset}}]
      })

    File.write!(Path.join(Paths.cartridges_dir(), "index.json"), body)
    File.write!(Path.join(Paths.cartridges_dir(), "index.json.sig"), sign.(body))
  end

  defp start_instance do
    start_supervised!({Instance, id: "a"})
    Instance.subscribe("a")
  end

  # the views the instance publishes until one matches (fails on another final phase)
  defp await(pred, seen \\ []) do
    receive do
      {:instance, "a", {:state, view}} ->
        if pred.(view), do: Enum.reverse([view | seen]), else: await(pred, [view | seen])
    after
      15_000 -> flunk("no matching state; saw #{inspect(Enum.map(seen, &{&1.firmware, &1.phase}))}")
    end
  end

  defp live, do: :sys.get_state(Instance.via("a")).live

  test "a native firmware without its cartridge downloads it before it starts, with progress" do
    assert Firmware.needs_cart?(Firmware.get("dinghy"))
    start_instance()

    views = await(&(&1.phase == :running))
    assert Enum.any?(views, &(&1.phase == :downloading and &1.firmware == "dinghy" and &1.download != nil))
    assert %{firmware: "dinghy", backend: :native, ready: true} = live()
    assert %{backend: :native, file: cart} = Firmware.runnable("dinghy")
    assert File.read!(cart) == File.read!(@cart)
    refute Firmware.needs_cart?(Firmware.get("dinghy"))
  end

  test "a failed download runs the Hub package in the emulator, labelled, and the native one stays chosen", %{www: www} do
    File.rm!(Path.join(www, "dinghy.so"))
    File.cp!(@package, Catalog.hub_package_path(Firmware.get("hub:dinghy"), Paths.packages_dir()))
    start_instance()

    views = await(&(&1.phase == :running))
    assert Enum.any?(views, &(&1.phase == :downloading))
    assert List.last(views).firmware == "hub:dinghy"
    assert Firmware.get("hub:dinghy").name =~ "Hub package"
    assert %{firmware: "hub:dinghy", backend: :emu, ready: true} = live()
    assert Firmware.needs_cart?(Firmware.get("dinghy"))

    # the next start tries the native build again
    assert %{firmware: "dinghy"} = :erlang.binary_to_term(File.read!(Paths.instance_state("a")))
  end

  test "a failed download with no Hub package on the phone: can't run here", %{www: www} do
    File.rm!(Path.join(www, "dinghy.so"))
    start_instance()
    views = await(&(&1.phase == :not_installed))
    assert Enum.any?(views, &(&1.phase == :downloading))
    assert live() == nil
  end

  test "a failed download doesn't start a quarantined Hub package: its safe mode, and Run anyway starts it",
       %{www: www} do
    File.rm!(Path.join(www, "dinghy.so"))
    File.cp!(@package, Catalog.hub_package_path(Firmware.get("hub:dinghy"), Paths.packages_dir()))
    File.write!(Paths.instance_state("a"), :erlang.term_to_binary(%{firmware: "dinghy", quarantined: ["hub:dinghy"]}))
    start_instance()

    views = await(&(&1.phase == :safe_mode))
    assert %{firmware: "hub:dinghy", quarantined: true} = List.last(views)
    assert live() == nil

    :ok = Instance.run_anyway("a")
    await(&(&1.phase == :running))
    assert %{firmware: "hub:dinghy", backend: :emu} = live()
  end
end
