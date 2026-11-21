defmodule FMutate.AudioMixerTest do
  # The mixer the device runs (c_src/fm1mix.c, mob_audio_io's "fm1_mixer" processor), on this computer: built with
  # the host's C compiler under AddressSanitizer and UBSan and driven as the plugin drives it, over a real ring
  # file (test/c/fm1mix_host.c): the 44.1 kHz clock and the ring's read position against the stream's rate, the
  # resampler across blocks and reopens, mono, underruns, the soft clip and peak, a crossfade ramp, detach.
  use ExUnit.Case, async: true

  @moduletag timeout: 120_000

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_mixer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "the mixer processor's checks pass", %{dir: dir} do
    cc = System.find_executable("cc") || flunk("no C compiler (cc)")
    bin = Path.join(dir, "fm1mix_host")

    {out, status} =
      System.cmd(
        cc,
        ~w(-std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined -o #{bin} test/c/fm1mix_host.c
           -lm -lpthread),
        stderr_to_stdout: true
      )

    assert status == 0, out

    {out, status} = System.cmd(bin, [dir], stderr_to_stdout: true)
    assert status == 0, out
    assert out =~ "all checks passed"
  end
end
