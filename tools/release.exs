# Publishing FMutate (docs/decisions/2026-11-13-updates.md). Run from the repository root:
#
#   mise exec -- mix run --no-start tools/release.exs apk --notes-file NOTES.md [--prerelease] [--draft]
#   mise exec -- mix run --no-start tools/release.exs ota [--push]
#
# apk  A release of the app: builds the release APK (mix mob.release --android, then gradle assembleRelease,
#      signed with android/keystore.properties), refuses an APK not signed with FMutate's release key, publishes
#      it as GitHub release v<versionName> with update metadata (mix mob_app_update.publish), then an empty OTA
#      manifest for the new build's channel. Version: android/version.properties (raise it first, with mix.exs).
# ota  Elixir-only changes over the air to the installed build: compiles the lib/ files changed since the
#      build's tag (v<versionName>, or --since REF), signs a manifest for channel <track>-<versionCode> and
#      writes it into the gh-pages worktree's ota/ directory, which GitHub Pages serves. Refuses when anything
#      other than Elixir under lib/ changed (that needs an APK). With no changes it publishes an empty manifest,
#      which takes devices back to the code their APK was built with. --push commits and pushes gh-pages.
#
# Options:
#   --track T            production (default) or a test track (FMUTATE_UPDATE_TRACK of the build), e.g.
#                        updates-test; a test track's APK must be --prerelease
#   --site DIR           the gh-pages worktree (default ../fmutate-site; created if missing)
#   --key-file F         the OTA signing key (default ~/.config/fmutate/mob_deliver_signing.key, or
#                        MOB_DELIVER_SIGNING_KEY)
#   --signer-sha256 HEX  apk: accept this signing certificate instead of the release key's (test builds with a
#                        throwaway key; only with --prerelease)
#   --apk PATH           apk: publish this already built APK instead of building
#   --since REF          ota: compare with REF instead of the build's tag
#   --force              ota: publish even if non-Elixir files changed (you know the APK has them)
#   --dry-run            print what would be published, publish nothing

defmodule FMutate.Release do
  @repo "GenericJam/fmutate"
  @app "com.genericjam.fmutate"
  # SHA-256 of FMutate's release signing certificate (v0.1.0 onwards). Installed copies only accept updates
  # signed with it; the key itself is not in the repository or on every machine.
  @release_signer "154ffa7b77ae7ab1cf427e4d01af941663778392eb28207830bdf80f8440e28f"
  @default_key "~/.config/fmutate/mob_deliver_signing.key"

  @switches [
    notes_file: :string,
    prerelease: :boolean,
    draft: :boolean,
    track: :string,
    site: :string,
    key_file: :string,
    signer_sha256: :string,
    apk: :string,
    since: :string,
    force: :boolean,
    push: :boolean,
    dry_run: :boolean
  ]

  def main(["apk" | args]), do: apk(parse(args))
  def main(["ota" | args]), do: ota(parse(args))
  def main(_), do: fail("usage: tools/release.exs apk|ota [options] (see the header of tools/release.exs)")

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} -> opts
      {_, rest, invalid} -> fail("unexpected arguments: #{inspect(rest ++ invalid)}")
    end
  end

  ## The app (APK on GitHub Releases)

  defp apk(opts) do
    version = version()
    tag = "v#{version["versionName"]}"
    track = Keyword.get(opts, :track, "production")
    notes = opts[:notes_file] || fail("--notes-file is required (the release notes users see in the app)")

    if track != "production" and not opts[:prerelease], do: fail("a #{track} build must be --prerelease")
    if opts[:signer_sha256] && !opts[:prerelease], do: fail("--signer-sha256 is for --prerelease test builds only")
    if System.get_env("FMUTATE_UPDATE_TRACK", "production") != track,
      do: fail("FMUTATE_UPDATE_TRACK (#{System.get_env("FMUTATE_UPDATE_TRACK")}) must match --track #{track}")

    if release_exists?(tag), do: fail("#{tag} is already released; raise android/version.properties first")

    apk = opts[:apk] || build_apk(version)
    check_apk!(apk, version, opts[:signer_sha256] || @release_signer)
    head = git!(["rev-parse", "HEAD"])

    unless git_ok?(["branch", "-r", "--contains", head]),
      do: fail("push #{head} first: the release is tagged at it")

    publish = [
      "--repo", @repo, "--apk", apk, "--tag", tag, "--title", "FMutate #{version["versionName"]}",
      "--notes-file", notes, "--target", head
    ] ++ flag(opts, :prerelease) ++ flag(opts, :draft) ++ flag(opts, :dry_run)

    Mix.Task.run("mob_app_update.publish", publish)

    # the new build's channel starts with an empty manifest (its bundled code): checks find something to verify
    # rather than a 404, and the floor starts at this release
    ota(Keyword.merge(opts, since: "HEAD", force: false))
  end

  defp build_apk(version) do
    unless File.exists?("android/keystore.properties"),
      do:
        fail(
          "android/keystore.properties is missing: release builds are signed with FMutate's release key, which " <>
            "isn't on this machine (AGENTS.md, Releases)"
        )

    Mix.Task.run("mob.release", ["--android"])
    cmd!("bash", ["gradlew", "assembleRelease", "--no-daemon"], cd: "android")
    out = Path.join(["_build", "release", "fmutate-#{version["versionName"]}.apk"])
    File.mkdir_p!(Path.dirname(out))
    File.cp!("android/app/build/outputs/apk/release/app-release.apk", out)
    out
  end

  defp check_apk!(apk, version, signer) do
    badging = cmd!(tool("aapt2"), ["dump", "badging", apk])
    [_, package, code, name] = Regex.run(~r/package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'/, badging)

    if {package, code, name} != {@app, version["versionCode"], version["versionName"]},
      do:
        fail(
          "#{apk} is #{package} #{name} (#{code}); android/version.properties says " <>
            "#{version["versionName"]} (#{version["versionCode"]})"
        )

    certs = cmd!(tool("apksigner"), ["verify", "--print-certs", apk])

    signers =
      for [_, sha] <- Regex.scan(~r/certificate SHA-256 digest: ([0-9a-f]{64})/, certs), uniq: true, do: sha

    if signers != [signer],
      do:
        fail(
          "#{apk} is signed by #{inspect(signers)}, not #{signer}: installed copies would refuse it as an update"
        )

    IO.puts("#{apk}: #{package} #{name} (#{code}), signer #{signer}")
  end

  defp release_exists?(tag), do: git_ok?(["ls-remote", "--exit-code", "--tags", "origin", "refs/tags/#{tag}"])

  ## The code (OTA on GitHub Pages)

  defp ota(opts) do
    version = version()
    track = Keyword.get(opts, :track, "production")
    channel = "#{track}-#{version["versionCode"]}"
    since = opts[:since] || "v#{version["versionName"]}"
    files = changed_lib_files!(since, opts[:force])
    private_key = signing_key(opts)
    check_key!(private_key)

    IO.puts("OTA #{channel}: #{length(files)} changed file(s) since #{since}")
    Enum.each(files, &IO.puts("  " <> &1))

    Mix.Task.run("compile")

    build =
      case files do
        [] -> %{}
        files -> build!(files)
      end

    for {key, {sha, _}} <- Enum.sort(build), do: IO.puts("  #{key} sha256:#{sha}")

    if opts[:dry_run] do
      IO.puts("--dry-run: nothing published")
    else
      site = site!(opts)
      root = Path.join(site, "ota")

      %{fields: fields} =
        MobDeliverServer.publish(build,
          app: @app,
          channel: channel,
          private_key: private_key,
          storage: {MobDeliverServer.Storage.FS, root: root}
        )
        |> ok!("publish")

      IO.puts("signed #{channel} issued_at #{fields["issued_at"]} into #{root}")
      commit_site!(site, "OTA #{channel} #{fields["issued_at"]}: #{map_size(build)} module(s)", opts[:push])
    end
  end

  # Elixir under lib/ is what can change over the air. Anything else that ships in the APK (native code, the
  # Kotlin surface, priv/, config, dependencies) needs an APK release.
  defp changed_lib_files!(since, force?) do
    unless git_ok?(["rev-parse", "--verify", "--quiet", since <> "^{commit}"]),
      do: fail("#{since} isn't a commit here (the build's tag; --since REF to compare with something else)")

    # the working tree against REF, plus new (untracked) modules under lib/; build outputs a release leaves
    # untracked elsewhere (otp.zip, generated plugin bridges) are not source changes
    changed =
      (git!(["diff", "--name-only", since]) <> "\n" <> git!(["ls-files", "--others", "--exclude-standard", "--", "lib"]))
      |> String.split("\n", trim: true)
      |> Enum.uniq()

    shipped = Enum.reject(changed, &(&1 =~ ~r{^(test|docs|tools)/|\.md$}))
    {lib, other} = Enum.split_with(shipped, &(&1 =~ ~r{^lib/.*\.ex$}))

    if other != [] and !force?,
      do: fail("these changed since #{since} and need an APK release, not OTA: #{Enum.join(other, ", ")}")

    {present, deleted} = Enum.split_with(lib, &File.exists?/1)

    if deleted != [],
      do: IO.puts("note: deleted since #{since} (still in the APK, OTA can't remove them): #{Enum.join(deleted, ", ")}")

    present
  end

  defp build!(files), do: files |> MobDeliverServer.build() |> ok!("build")

  defp signing_key(opts) do
    case opts[:key_file] do
      nil -> System.get_env("MOB_DELIVER_SIGNING_KEY") || read_key(Path.expand(@default_key))
      path -> read_key(path)
    end
  end

  defp read_key(path) do
    case File.read(path) do
      {:ok, key} -> key
      {:error, _} -> fail("no OTA signing key at #{path} (--key-file or MOB_DELIVER_SIGNING_KEY)")
    end
  end

  defp check_key!(private_key) do
    public = MobDeliverServer.Manifest.public_key_string(private_key)
    trusted = Application.get_env(:mob_deliver, :trusted_publish_key)

    if public != trusted,
      do: fail("the signing key's public half #{public} isn't config/config.exs' trusted_publish_key #{trusted}")
  end

  # gh-pages, checked out next to this repository; created as an orphan branch the first time
  defp site!(opts) do
    site = Path.expand(Keyword.get(opts, :site, "../fmutate-site"))

    cond do
      File.dir?(Path.join(site, ".git")) or File.regular?(Path.join(site, ".git")) ->
        git!(["-C", site, "pull", "--ff-only", "--quiet"])

      git_ok?(["ls-remote", "--exit-code", "--heads", "origin", "gh-pages"]) ->
        git!(["fetch", "--quiet", "origin", "gh-pages"])
        git!(["worktree", "add", site, "gh-pages"])

      true ->
        git!(["worktree", "add", "--orphan", "-b", "gh-pages", site])
    end

    # served as files, no Jekyll
    File.write!(Path.join(site, ".nojekyll"), "")
    site
  end

  defp commit_site!(site, message, push?) do
    git!(["-C", site, "add", "-A", ".nojekyll", "ota"])
    git!(["-C", site, "commit", "--quiet", "-m", message])

    if push? do
      git!(["-C", site, "push", "--quiet", "origin", "gh-pages"])
      IO.puts("pushed gh-pages; GitHub Pages serves it within a few minutes (and caches up to 10)")
    else
      IO.puts("committed in #{site}; push gh-pages to publish (or rerun with --push)")
    end
  end

  ## Helpers

  defp version do
    for line <- File.read!("android/version.properties") |> String.split("\n"),
        [key, value] <- [String.split(String.trim(line), "=", parts: 2)],
        into: %{},
        do: {key, value}
  end

  defp tool(name) do
    sdk =
      System.get_env("ANDROID_HOME") || System.get_env("ANDROID_SDK_ROOT") ||
        Path.expand("~/Library/Android/sdk")

    case Path.wildcard(Path.join([sdk, "build-tools", "*", name])) |> Enum.sort() |> List.last() do
      nil -> System.find_executable(name) || fail("#{name} not found (Android SDK build-tools)")
      path -> path
    end
  end

  defp flag(opts, key), do: if(opts[key], do: ["--" <> String.replace(to_string(key), "_", "-")], else: [])

  defp ok!({:ok, value}, _what), do: value
  defp ok!({:error, reason}, what), do: fail("#{what} failed: #{inspect(reason)}")

  defp git!(args), do: cmd!("git", args)
  defp git_ok?(args), do: match?({_, 0}, System.cmd("git", args, stderr_to_stdout: true))

  defp cmd!(cmd, args, opts \\ []) do
    case System.cmd(cmd, args, Keyword.merge([stderr_to_stdout: true], opts)) do
      {out, 0} -> String.trim(out)
      {out, status} -> fail("#{cmd} #{Enum.join(args, " ")} exited #{status}:\n#{out}")
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "release: " <> message)
    System.halt(1)
  end
end

FMutate.Release.main(System.argv())
