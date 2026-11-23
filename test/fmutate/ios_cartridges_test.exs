defmodule FMutate.IosCartridgesTest do
  # native/ios_cartridges.exs, which pins (lock) and fetches (fetch) the published iOS cartridges native/build_ios.sh
  # links into the app: it must refuse an index or archive the app's key doesn't vouch for, an index older than the
  # lock, and never pin an index copy of a built-in. The script runs as the build runs it (`elixir`, curl), from a
  # copy beside a config/config.exs of the test's own: a throwaway Ed25519 key and an index served from 127.0.0.1.
  use ExUnit.Case, async: true

  alias FMutate.Test.FixtureServer

  @script Path.expand("native/ios_cartridges.exs")

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_ioscarts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "native"))
    File.mkdir_p!(Path.join(dir, "config"))
    File.cp!(@script, Path.join(dir, "native/ios_cartridges.exs"))
    server = FixtureServer.start()
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config

    config :fmutate_app, :cartridges,
      index_url: "#{server.url}index.json",
      public_key: "#{Base.encode64(pub)}"
    """)

    on_exit(fn ->
      FixtureServer.stop(server)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir, server: server, key: priv, lock: Path.join(dir, "ios.lock"), cache: Path.join(dir, "cache")}
  end

  defp run(ctx, args) do
    System.cmd("elixir", [Path.join(ctx.dir, "native/ios_cartridges.exs") | args], stderr_to_stdout: true)
  end

  defp sign(data, key), do: Base.encode64(:crypto.sign(:eddsa, :none, data, [key, :ed25519]))

  # an archive served at /<name>, and the index's asset for it
  defp asset(ctx, name, bin) do
    FixtureServer.route(ctx.server, "/" <> name, {200, [], bin})

    %{
      "url" => ctx.server.url <> name,
      "sha256" => Base.encode16(:crypto.hash(:sha256, bin), case: :lower),
      "size" => byte_size(bin),
      "sig" => sign(bin, ctx.key)
    }
  end

  defp firmware(ctx, id, version) do
    %{
      "id" => id,
      "version" => version,
      "commit" => String.duplicate("a", 40),
      "assets" => %{
        "ios-device" => asset(ctx, "#{id}-device.a", "#{id} #{version} device"),
        "ios-sim" => asset(ctx, "#{id}-sim.a", "#{id} #{version} sim"),
        "android-arm64-v8a" => asset(ctx, "#{id}-android.so", "#{id} #{version} android")
      }
    }
  end

  # serves the index (and its .sig, made with `sig_key`), generated at `generated`
  defp serve_index(ctx, firmwares, generated, sig_key \\ nil) do
    body =
      JSON.encode!(%{
        "schema" => 1,
        "engine_abi" => 1,
        "generated" => generated,
        "firmwares" => firmwares
      })

    FixtureServer.route(ctx.server, "/index.json", {200, [], body})
    FixtureServer.route(ctx.server, "/index.json.sig", {200, [], sign(body, sig_key || ctx.key)})
  end

  defp lock_lines(ctx) do
    for line <- ctx.lock |> File.read!() |> String.split("\n", trim: true),
        not String.starts_with?(line, "#"),
        do: String.split(line)
  end

  describe "lock" do
    test "pins each iOS asset of the signed index, but never an index copy of a built-in", ctx do
      serve_index(
        ctx,
        [firmware(ctx, "skiff", "1.2"), firmware(ctx, "obervave", "9.9"), firmware(ctx, "dinghy", "0.3")],
        "2026-11-20T10:00:00Z"
      )

      assert {_, 0} = run(ctx, ["lock", ctx.lock, "obervave", "shineon"])
      [generated | entries] = lock_lines(ctx)
      assert generated == ["generated", "2026-11-20T10:00:00Z"]

      assert Enum.map(entries, &Enum.take(&1, 3)) == [
               ["dinghy", "0.3", "ios-device"],
               ["dinghy", "0.3", "ios-sim"],
               ["skiff", "1.2", "ios-device"],
               ["skiff", "1.2", "ios-sim"]
             ]

      bin = "skiff 1.2 sim"
      [_, _, _, sha, size, _sig, url, _, caps] = Enum.at(entries, 3)
      assert sha == Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
      assert size == to_string(byte_size(bin))
      assert url == ctx.server.url <> "skiff-sim.a"
      assert JSON.decode!(caps) == %{}
    end

    test "refuses an index whose signature doesn't verify with the app's key; the lock stays", ctx do
      File.write!(ctx.lock, "generated 2026-11-01T00:00:00Z\n")
      {_, other} = :crypto.generate_key(:eddsa, :ed25519)
      serve_index(ctx, [firmware(ctx, "skiff", "1.2")], "2026-11-20T10:00:00Z", other)

      assert {out, 1} = run(ctx, ["lock", ctx.lock, "obervave"])
      assert out =~ "signature doesn't verify"
      assert File.read!(ctx.lock) == "generated 2026-11-01T00:00:00Z\n"
    end

    test "refuses an index older than the lock's (an old index served again); the same one is fine", ctx do
      serve_index(ctx, [firmware(ctx, "skiff", "1.3")], "2026-11-20T10:00:00Z")
      assert {_, 0} = run(ctx, ["lock", ctx.lock, "obervave"])
      pinned = File.read!(ctx.lock)

      serve_index(ctx, [firmware(ctx, "skiff", "1.2")], "2026-11-20T09:59:59Z")
      assert {out, 1} = run(ctx, ["lock", ctx.lock, "obervave"])
      assert out =~ "older than the lock's (2026-11-20T10:00:00Z)"
      assert File.read!(ctx.lock) == pinned

      serve_index(ctx, [firmware(ctx, "skiff", "1.3")], "2026-11-20T10:00:00Z")
      assert {_, 0} = run(ctx, ["lock", ctx.lock, "obervave"])
      assert File.read!(ctx.lock) == pinned
    end

    test "pins platform-specific partial capabilities, never firmware-wide or another platform's", ctx do
      skiff = firmware(ctx, "skiff", "1.2")
      skiff =
        skiff
        |> Map.put("caps", %{"pitch_bend" => true, "note_pressure" => true})
        |> put_in(["assets", "ios-sim", "caps"], %{"pitch_bend" => true, "note_pressure" => "true", "unknown" => true})
        |> put_in(["assets", "ios-device", "caps"], %{"note_pressure" => true})
      serve_index(ctx, [skiff], "2026-11-20T10:00:00Z")
      assert {_, 0} = run(ctx, ["lock", ctx.lock])

      assert {out, 0} = run(ctx, ["fetch", ctx.lock, "ios-sim", ctx.cache])
      assert out =~ "#{skiff["commit"]} #{skiff["assets"]["ios-sim"]["sha256"]} 1\n"
      assert {out, 0} = run(ctx, ["fetch", ctx.lock, "ios-device", ctx.cache])
      assert out =~ "#{skiff["commit"]} #{skiff["assets"]["ios-device"]["sha256"]} 2\n"
    end
  end

  describe "fetch" do
    # a lock pinning one ios-sim archive `pinned` describes, served as `served`
    defp pin(ctx, pinned, served, sig \\ nil) do
      a = asset(ctx, "skiff-sim.a", pinned)
      FixtureServer.route(ctx.server, "/skiff-sim.a", {200, [], served})

      File.write!(ctx.lock, """
      generated 2026-11-20T10:00:00Z
      skiff 1.2 ios-sim #{a["sha256"]} #{a["size"]} #{sig || a["sig"]} #{a["url"]} -
      """)

      a
    end

    defp cached(ctx), do: if(File.dir?(ctx.cache), do: File.ls!(ctx.cache), else: [])

    test "keeps the pinned archive in the cache by its SHA-256 and names it", ctx do
      a = pin(ctx, "skiff archive", "skiff archive")
      path = Path.join(ctx.cache, a["sha256"] <> ".a")

      assert {out, 0} = run(ctx, ["fetch", ctx.lock, "ios-sim", ctx.cache])
      assert out =~ "skiff 1.2 #{path} - #{a["sha256"]} 0\n"
      assert File.read!(path) == "skiff archive"
      assert cached(ctx) == [a["sha256"] <> ".a"]
    end

    for {what, served, error} <- [
          {"size", "skiff archive, longer", "size"},
          {"SHA-256", "skiff archivE", "SHA-256"}
        ] do
      test "refuses an archive whose #{what} isn't the lock's, and caches nothing", ctx do
        pin(ctx, "skiff archive", unquote(served))
        assert {out, 1} = run(ctx, ["fetch", ctx.lock, "ios-sim", ctx.cache])
        assert out =~ "skiff 1.2 ios-sim (#{ctx.server.url}skiff-sim.a): #{unquote(error)} doesn't match"
        assert cached(ctx) == []
      end
    end

    test "refuses an archive the app's key didn't sign, even when its size and SHA-256 are the lock's", ctx do
      {_, other} = :crypto.generate_key(:eddsa, :ed25519)
      pin(ctx, "skiff archive", "skiff archive", sign("skiff archive", other))
      assert {out, 1} = run(ctx, ["fetch", ctx.lock, "ios-sim", ctx.cache])
      assert out =~ "signature doesn't match"
      assert cached(ctx) == []
    end

    test "a damaged cached copy is fetched again", ctx do
      a = pin(ctx, "skiff archive", "skiff archive")
      path = Path.join(ctx.cache, a["sha256"] <> ".a")
      File.mkdir_p!(ctx.cache)
      File.write!(path, "skiff archivE")

      assert {_, 0} = run(ctx, ["fetch", ctx.lock, "ios-sim", ctx.cache])
      assert File.read!(path) == "skiff archive"
    end
  end
end
