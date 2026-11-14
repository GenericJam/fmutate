defmodule FMutate.CartridgesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FMutate.{Cartridges, Firmware, Library, Paths}
  alias FMutate.Library.Catalog

  @platform "android-arm64-v8a"

  @hub %{
    "updated" => "2026-11-13 07:02 UTC",
    "firmwares" => [
      %{"id" => "shineon", "name" => "Shine On", "author" => "zvenson", "pkg" => "fw/shineon-3.0.1.fwsc"},
      %{"id" => "skiff", "name" => "Skiff", "author" => "kurogedelic", "lic" => "GPL-3.0", "pkg" => "fw/skiff-2.5.fwsc"},
      %{"id" => "hortator", "name" => "Hortator", "author" => "DEADACTIVE", "pkg" => "fw/hortator-1.0.1.fwsc"}
    ]
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_carts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, dir: dir, pub: pub, priv: priv}
  end

  defp sign(data, priv), do: Base.encode64(:crypto.sign(:eddsa, :none, data, [priv, :ed25519]))

  # a cartridge's bytes and its index entry (asset for `platform`)
  defp cart(id, version, priv, platform \\ @platform) do
    bytes = :crypto.strong_rand_bytes(300) <> "#{id} #{version}"

    asset = %{
      "url" => "http://example.invalid/libcart_#{id}-#{version}-#{platform}.so",
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      "size" => byte_size(bytes),
      "sig" => sign(bytes, priv)
    }

    entry = %{
      "id" => id,
      "name" => String.capitalize(id),
      "version" => version,
      "repo" => "kurogedelic/#{id}",
      "commit" => "0ea3682d1c2b",
      "license" => "GPL-3.0",
      "build" => "clean",
      "parity" => %{"status" => "match"},
      "assets" => %{platform => asset}
    }

    {bytes, entry}
  end

  defp index(entries, extra \\ %{}),
    do: JSON.encode!(Map.merge(%{"schema" => 1, "engine_abi" => 1, "generated" => "2026-11-14T03:00:00Z", "firmwares" => entries}, extra))

  defp entries_of(body, platform \\ @platform), do: Cartridges.entries(JSON.decode!(body), platform)

  describe "the index" do
    test "only a correctly signed index of schema 1 and engine ABI 1 is used", %{pub: pub, priv: priv} do
      {_, skiff} = cart("skiff", "2.6", priv)
      body = index([skiff])

      assert {:ok, %{"firmwares" => [_]}} = Cartridges.verify_index(body, sign(body, priv) <> "\n", pub)

      tampered = String.replace(body, "2.6", "2.7")
      assert {:error, :signature} = Cartridges.verify_index(tampered, sign(body, priv), pub)

      {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      assert {:error, :signature} = Cartridges.verify_index(body, sign(body, priv), other_pub)
      assert {:error, :signature} = Cartridges.verify_index(body, "not base64!", pub)
      assert {:error, :signature} = Cartridges.verify_index(body, sign(body, priv), nil)

      v2 = index([skiff], %{"schema" => 2})
      assert {:error, :schema} = Cartridges.verify_index(v2, sign(v2, priv), pub)
      abi2 = index([skiff], %{"engine_abi" => 2})
      assert {:error, :engine_abi} = Cartridges.verify_index(abi2, sign(abi2, priv), pub)
    end

    test "this phone's asset: Android ABIs, iOS, none on a host; entries without one are not native here", %{priv: priv} do
      assert Cartridges.platform(:android, "aarch64-unknown-linux-android") == "android-arm64-v8a"
      assert Cartridges.platform(:android, "x86_64-pc-linux-android") == "android-x86_64"
      assert Cartridges.platform(:android, "arm-unknown-linux-androideabi") == "android-armeabi-v7a"
      assert Cartridges.platform(:ios, "aarch64-apple-ios") == "ios-device"
      assert Cartridges.platform(:ios, "aarch64-apple-iossimulator") == "ios-sim"
      assert Cartridges.platform(:host, "aarch64-apple-darwin25.0.0") == nil

      {_, skiff} = cart("skiff", "2.6", priv)
      {_, x86_only} = cart("dinghy", "1.0", priv, "android-x86_64")
      {_, evil} = cart("../evil", "1.0", priv)
      body = index([skiff, x86_only, evil])

      assert Map.keys(entries_of(body)) == ["skiff"]
      assert Map.keys(entries_of(body, "android-x86_64")) == ["dinghy"]
      assert entries_of(body, nil) == %{}
    end
  end

  describe "the catalogue" do
    setup %{priv: priv} do
      {_, skiff} = cart("skiff", "2.6", priv)
      {_, shine} = cart("shineon", "9.9", priv)
      {:ok, body: index([skiff, shine]), hub: Catalog.parse_hub(@hub)}
    end

    test "a cartridge of the build wins over a download, a download over the emulator; the Hub package stays as hub:<id>",
         %{dir: dir, body: body, hub: hub} do
      carts = Path.join(dir, "carts")
      File.mkdir_p!(carts)
      ctx = %{current: nil, quarantined: [], emu?: true}

      merge = fn bundled_cart ->
        natives = body |> entries_of() |> Cartridges.resolve(carts, bundled_cart)
        Catalog.merge(Firmware.bundled(), hub, dir, natives)
      end

      none = fn _ -> nil end
      all = merge.(none)
      assert Enum.map(all, & &1.id) == ["obervave", "shineon", "hub:shineon", "skiff", "hub:skiff", "hortator"]

      # a firmware bundled with the app ignores the index
      shine = Enum.find(all, &(&1.id == "shineon"))
      assert shine.source == :bundled and shine.version == "3.0.1" and shine.native == nil

      # a native build not downloaded yet: Download (the cartridge's size)
      skiff = Enum.find(all, &(&1.id == "skiff"))
      assert skiff.backend == :native and skiff.version == "2.6" and skiff.cart == nil
      assert skiff.size == skiff.native.size
      assert Catalog.status(skiff, ctx) == :available
      assert %{backend: :emu, source: :hub} = Enum.find(all, &(&1.id == "hub:skiff"))
      assert %{backend: :emu, native: nil} = Enum.find(all, &(&1.id == "hortator"))

      # downloaded: on the phone
      File.write!(Path.join(carts, "libcart_skiff-2.6-#{@platform}.so"), "x")
      skiff = Enum.find(merge.(none), &(&1.id == "skiff"))
      assert skiff.cart == Path.join(carts, "libcart_skiff-2.6-#{@platform}.so")
      assert Catalog.status(skiff, ctx) == :on_phone
      refute Catalog.update?(skiff)

      # a cartridge of the build wins over the download: nothing to download or update
      bundled = fn id -> if id == "skiff", do: "/lib/libcart_skiff.so" end
      skiff = Enum.find(merge.(bundled), &(&1.id == "skiff"))
      assert skiff.cart == "/lib/libcart_skiff.so" and Catalog.status(skiff, ctx) == :on_phone
      refute Catalog.update?(skiff)
    end

    test "a newer build than the downloaded one is offered while the old one keeps running",
         %{dir: dir, body: body, hub: hub} do
      old = Path.join(dir, "libcart_skiff-2.5-#{@platform}.so")
      File.write!(old, "x")
      # another id that starts like this one isn't this one's
      File.write!(Path.join(dir, "libcart_skiff-lite-1.0-#{@platform}.so"), "x")

      natives = body |> entries_of() |> Cartridges.resolve(dir, fn _ -> nil end)
      skiff = Enum.find(Catalog.merge([], hub, dir, natives), &(&1.id == "skiff"))
      assert skiff.cart == old and skiff.native.cart_version == "2.5"
      assert Catalog.status(skiff, %{current: nil, quarantined: [], emu?: true}) == :on_phone
      assert Catalog.update?(skiff)
    end

    test "on iOS only a cartridge linked into the app runs natively; the others play emulated", %{dir: dir, priv: priv, hub: hub} do
      {_, skiff} = cart("skiff", "2.6", priv, "ios-device")
      {_, hort} = cart("hortator", "1.1", priv, "ios-device")
      linked = fn id -> if id == "hortator", do: "hortator" end
      natives = index([skiff, hort]) |> entries_of("ios-device") |> Cartridges.resolve(dir, linked)
      all = Catalog.merge([], hub, dir, natives)

      assert %{backend: :emu, native: %{version: "2.6"}} = Enum.find(all, &(&1.id == "skiff"))
      refute Enum.find(all, &(&1.id == "hub:skiff"))
      assert %{backend: :native, cart: "hortator"} = Enum.find(all, &(&1.id == "hortator"))
    end
  end

  describe "downloaded cartridges" do
    test "kept only when size, checksum and signature check; the id's older version goes then",
         %{dir: dir, pub: pub, priv: priv} do
      {bytes, entry} = cart("skiff", "2.6", priv)
      [native] = index([entry]) |> entries_of() |> Map.values()
      part = Path.join(dir, "skiff.part")
      old = Path.join(dir, "libcart_skiff-2.5-#{@platform}.so")
      File.write!(old, "old")

      for {data, n, error} <- [
            {bytes <> "x", native, :size},
            {:binary.copy("x", byte_size(bytes)), native, :sha256},
            {bytes, %{native | sig: sign(bytes <> "x", priv)}, :signature}
          ] do
        File.write!(part, data)
        assert {:error, ^error} = Cartridges.install(part, n, dir, pub)
        refute File.exists?(part)
        assert File.ls!(dir) == [Path.basename(old)]
      end

      {other_pub, _} = :crypto.generate_key(:eddsa, :ed25519)
      File.write!(part, bytes)
      assert {:error, :signature} = Cartridges.install(part, native, dir, other_pub)

      File.write!(part, bytes)
      assert {:ok, dest} = Cartridges.install(part, native, dir, pub)
      assert File.read!(dest) == bytes
      assert File.ls!(dir) == ["libcart_skiff-2.6-#{@platform}.so"]
    end
  end

  describe "saves" do
    test "an id gone native leaves its emulator saves to hub:<id>, once, never over an existing file", %{dir: dir} do
      emu = Path.join([dir, "a", "emu"])
      File.mkdir_p!(emu)
      File.write!(Path.join(emu, "skiff.bin"), "played")

      assert [moved] = Cartridges.move_emu_flash(dir, "skiff")
      assert moved == Path.join(emu, "hub:skiff.bin") and File.read!(moved) == "played"
      refute File.exists?(Path.join(emu, "skiff.bin"))

      # a later emulator save of the id doesn't replace the Hub package's
      File.write!(Path.join(emu, "skiff.bin"), "later")
      assert Cartridges.move_emu_flash(dir, "skiff") == []
      assert File.read!(Path.join(emu, "hub:skiff.bin")) == "played"

      # an instance whose engine may be writing it is left alone
      File.mkdir_p!(Path.join([dir, "b", "emu"]))
      File.write!(Path.join([dir, "b", "emu", "hortator.bin"]), "b")
      assert Cartridges.move_emu_flash(dir, "hortator", ["b"]) == []
    end
  end

  describe "new builds" do
    test "nothing is new before anything was seen; new and updated ids since", %{priv: priv} do
      {_, skiff} = cart("skiff", "2.6", priv)
      {_, dinghy} = cart("dinghy", "1.0", priv)
      entries = entries_of(index([skiff, dinghy]))

      assert Cartridges.fresh(entries, nil) == []
      assert Cartridges.fresh(entries, %{"skiff" => "2.6", "dinghy" => "1.0"}) == []
      assert Cartridges.fresh(entries, %{"skiff" => "2.5"}) == ["dinghy", "skiff"]
    end
  end

  describe "the library process" do
    setup %{dir: dir, pub: pub, priv: priv} do
      server = start_server()
      prev = Application.get_env(:fmutate_app, :cartridges)
      Application.put_env(:fmutate_app, :data_dir, dir)

      Application.put_env(:fmutate_app, :cartridges,
        index_url: "http://127.0.0.1:#{server.port}/index.json",
        public_key: Base.encode64(pub),
        platform: @platform
      )

      on_exit(fn ->
        Application.delete_env(:fmutate_app, :data_dir)
        Application.put_env(:fmutate_app, :cartridges, prev)
      end)

      # a fresh Hub cache: the Hub isn't asked
      File.write!(Path.join(dir, "hub_catalog.json"), JSON.encode!(@hub))
      {skiff_bytes, skiff} = cart("skiff", "2.6", priv)
      skiff = put_url(skiff, server, "/skiff.so")
      serve_index(server, [skiff], priv, "\"v1\"")
      serve(server, "/skiff.so", {200, [], skiff_bytes})
      {:ok, server: server}
    end

    test "the index is read at start and on refresh with its ETag; 304 and a restart keep it", %{server: server} do
      start_supervised!(Library)
      assert_receive {:request, "/index.json", headers}, 2000
      refute headers["if-none-match"]
      wait(fn -> Library.info().index_generated != nil end)
      assert %{backend: :native, cart: nil} = Firmware.get("skiff")

      serve(server, "/index.json", fn h -> if h["if-none-match"] == "\"v1\"", do: {304, [], ""}, else: {500, [], ""} end)
      Library.refresh()
      assert_receive {:request, "/index.json", %{"if-none-match" => "\"v1\""}}, 2000
      wait(fn -> not Library.info().index_refreshing end)
      assert Library.info().index_error == nil
      assert %{backend: :native} = Firmware.get("skiff")

      # offline after a restart: the cached index
      stop_supervised!(Library)
      serve(server, "/index.json", {500, [], ""})
      start_supervised!(Library)
      assert %{backend: :native, version: "2.6"} = Firmware.get("skiff")
      wait(fn -> Library.info().index_error != nil end)
      assert %{backend: :native} = Firmware.get("skiff")
    end

    test "an index that doesn't verify is refused and the last good one stays", %{server: server, priv: priv} do
      start_supervised!(Library)
      wait(fn -> Library.info().index_generated != nil end)

      {_, other} = cart("dinghy", "1.0", priv)
      body = index([other])
      serve(server, "/index.json", {200, [], body})
      serve(server, "/index.json.sig", {200, [], sign(body <> " ", priv)})
      Library.refresh()
      wait(fn -> Library.info().index_error != nil end)

      assert %{backend: :native} = Firmware.get("skiff")
      assert Firmware.get("dinghy") == nil
    end

    test "Download fetches the cartridge: available, then on the phone and native; an update keeps the old one until it's in",
         %{server: server, priv: priv, dir: dir} do
      start_supervised!(Library)
      wait(fn -> Library.info().index_generated != nil end)
      ctx = %{current: nil, quarantined: [], emu?: false}
      assert Catalog.status(Firmware.get("skiff"), ctx) == :available
      assert Firmware.runnable("skiff") == nil

      :ok = Library.download("skiff")
      wait(fn -> Firmware.get("skiff").cart != nil end)
      v26 = Firmware.get("skiff").cart
      assert Catalog.status(Firmware.get("skiff"), ctx) == :on_phone
      assert %{backend: :native, file: ^v26} = Firmware.runnable("skiff")

      # a new build: offered, the old one still runs
      {bytes, skiff27} = cart("skiff", "2.7", priv)
      serve(server, "/skiff27.so", {200, [], bytes})
      serve_index(server, [put_url(skiff27, server, "/skiff27.so")], priv, "\"v2\"")
      Library.refresh()
      wait(fn -> Firmware.get("skiff").native.version == "2.7" end)
      assert Catalog.update?(Firmware.get("skiff"))
      assert %{file: ^v26} = Firmware.runnable("skiff")

      :ok = Library.download("skiff")
      wait(fn -> not Catalog.update?(Firmware.get("skiff")) end)
      assert %{file: v27} = Firmware.runnable("skiff")
      assert File.read!(v27) == bytes
      refute File.exists?(v26)

      # Delete: available again
      assert :ok = Library.delete("skiff")
      assert Catalog.status(Firmware.get("skiff"), ctx) == :available
      assert File.ls!(Path.join(dir, "cartridges")) |> Enum.filter(&String.ends_with?(&1, ".so")) == []
    end

    test "a cartridge that isn't what the index lists is not kept", %{server: server, dir: dir} do
      start_supervised!(Library)
      wait(fn -> Library.info().index_generated != nil end)
      serve(server, "/skiff.so", {200, [], "not the cartridge"})

      :ok = Library.download("skiff")
      wait(fn -> Library.info().error != nil end)
      assert Firmware.get("skiff").cart == nil
      assert File.ls!(Path.join(dir, "cartridges")) |> Enum.filter(&String.contains?(&1, ".so")) == []
    end

    test "New: nothing on the first index; a later one's new builds are New until seen, and notified if asked",
         %{server: server, priv: priv} do
      start_supervised!(Library)
      wait(fn -> Library.info().index_generated != nil end)
      refute Firmware.get("skiff").new
      :ok = Library.subscribe()

      {_, skiff} = cart("skiff", "2.6", priv)
      {_, dinghy} = cart("dinghy", "1.0", priv)
      serve_index(server, [skiff, dinghy], priv, "\"v2\"")
      Library.refresh()
      assert_receive {:library, {:new_natives, ["dinghy"]}}, 2000
      assert Firmware.get("dinghy").new
      refute Firmware.get("skiff").new

      :ok = Library.mark_seen(["dinghy"])
      refute Firmware.get("dinghy").new

      # opted in: the notifier hears of the next one
      :ok = Library.set_notify(true)
      {_, felucca} = cart("felucca", "1.8", priv)
      serve_index(server, [skiff, dinghy, felucca], priv, "\"v3\"")

      log =
        capture_log(fn ->
          Library.refresh()
          assert_receive {:library, {:new_natives, ["felucca"]}}, 2000
          Library.info()
        end)

      assert log =~ "Felucca 1.8"
      assert Library.info().notify_new_natives

      # still New after a restart, until seen
      stop_supervised!(Library)
      serve(server, "/index.json", {304, [], ""})
      start_supervised!(Library)
      assert Firmware.get("felucca").new
      refute Firmware.get("dinghy").new
    end

    test "an id gone native takes its emulator saves along to hub:<id> at start", %{dir: dir} do
      start_supervised!(Library)
      wait(fn -> Library.info().index_generated != nil end)
      stop_supervised!(Library)

      emu = Path.join([dir, "flash", "a", "emu"])
      File.mkdir_p!(emu)
      File.write!(Path.join(emu, "skiff.bin"), "played")
      File.write!(Path.join(emu, "hortator.bin"), "h")

      start_supervised!(Library)
      assert File.read!(Paths.flash("a", "hub:skiff", :emu)) == "played"
      refute File.exists?(Paths.flash("a", "skiff", :emu))
      assert File.read!(Paths.flash("a", "hortator", :emu)) == "h"
    end
  end

  defp put_url(entry, server, path),
    do: put_in(entry, ["assets", @platform, "url"], "http://127.0.0.1:#{server.port}#{path}")

  defp serve_index(server, entries, priv, etag) do
    body = index(entries)
    serve(server, "/index.json", {200, [{"ETag", etag}], body})
    serve(server, "/index.json.sig", {200, [], sign(body, priv)})
  end

  defp wait(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out")
      true -> Process.sleep(20) && wait(fun, tries - 1)
    end
  end

  ## A local HTTP server: routes path → {status, headers, body} or fn(request headers) → that; every request
  ## is reported to the test as {:request, path, headers}

  defp serve(server, path, response), do: Agent.update(server.routes, &Map.put(&1, path, response))

  defp start_server do
    test = self()
    {:ok, routes} = Agent.start_link(fn -> %{} end)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept(listen, routes, test) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    %{port: port, routes: routes}
  end

  defp accept(listen, routes, test) do
    {:ok, sock} = :gen_tcp.accept(listen)
    {:ok, {:http_request, :GET, {:abs_path, path}, _}} = :gen_tcp.recv(sock, 0, 5000)
    headers = read_headers(sock, %{})
    send(test, {:request, path, headers})

    {status, extra, body} =
      case Map.get(Agent.get(routes, & &1), path, {404, [], ""}) do
        fun when is_function(fun) -> fun.(headers)
        response -> response
      end

    head = for {k, v} <- extra, into: "", do: "#{k}: #{v}\r\n"
    reply = "HTTP/1.1 #{status} X\r\n#{head}Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n"
    :gen_tcp.send(sock, if(status == 304, do: reply, else: reply <> body))
    :gen_tcp.close(sock)
    accept(listen, routes, test)
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5000) do
      {:ok, {:http_header, _, name, _, value}} -> read_headers(sock, Map.put(acc, String.downcase(to_string(name)), value))
      {:ok, :http_eoh} -> acc
    end
  end
end
