defmodule FMutate.IosArchiveTest do
  # native/ios_archive.sh, the step of native/build_ios.sh that makes libfm1native.a, with a stand-in xcrun: a
  # libtool that fails must fail the build (it once printed its error and went on, reporting success).
  use ExUnit.Case, async: true

  @script Path.expand("native/ios_archive.sh")

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_archive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "bin"))
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  # an xcrun whose libtool does `body` (sh; $out is the archive it was asked for)
  defp xcrun(dir, body) do
    path = Path.join(dir, "bin/xcrun")

    File.write!(path, """
    #!/bin/sh
    while [ "$1" != "-o" ]; do shift; done
    out=$2
    #{body}
    """)

    File.chmod!(path, 0o755)
  end

  defp archive(dir) do
    out = Path.join(dir, "libx.a")
    env = [{"PATH", Path.join(dir, "bin") <> ":" <> System.get_env("PATH")}]

    {text, status} =
      System.cmd("sh", [@script, "iphoneos", out, "a.o"], env: env, stderr_to_stdout: true)

    {text, status, out}
  end

  test "libtool failing fails the step, with what it said", ctx do
    xcrun(ctx.dir, ~s|echo "libtool: error: a.o: no such file" >&2; exit 1|)
    {text, status, out} = archive(ctx.dir)
    assert status != 0
    assert text =~ "libtool: error: a.o: no such file"
    refute File.exists?(out)
  end

  test "libtool exiting 0 without an archive fails the step", ctx do
    xcrun(ctx.dir, "exit 0")
    {_text, status, _out} = archive(ctx.dir)
    assert status != 0
  end

  test "an archive made: success, with libtool's 'has no symbols' notes hidden and its other output shown",
       ctx do
    xcrun(ctx.dir, """
    echo "libtool: warning: x.o has no symbols" >&2
    echo "libtool: warning: something else" >&2
    echo archive > "$out"
    """)

    {text, status, out} = archive(ctx.dir)
    assert status == 0, text
    assert File.exists?(out)
    refute text =~ "has no symbols"
    assert text =~ "something else"
  end
end
