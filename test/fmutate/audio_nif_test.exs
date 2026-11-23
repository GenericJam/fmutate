defmodule FMutate.AudioNifTest do
  # The audio NIF's (c_src/fm1audio.c) start when its platform's audio says no, on this Mac: the NIF built for the
  # host, with the platform's side stubbed, loaded into a VM of its own (FMutate.AudioNif loads ./fm1audio.so from
  # its working directory there). AAudio's side needs the NDK's AAudio.h (ANDROID_NDK_HOME or the SDK's ndk/).
  use ExUnit.Case, async: true

  @moduletag timeout: 120_000

  unless match?({:unix, :darwin}, :os.type()) do
    @moduletag skip: "macOS only: builds the NIF with the host's clang"
  end

  @src Path.expand("c_src/fm1audio.c")

  # every function load_backend resolves, in its order
  @aaudio ~w(AAudio_createStreamBuilder AAudioStreamBuilder_setFormat AAudioStreamBuilder_setChannelCount
             AAudioStreamBuilder_setSampleRate AAudioStreamBuilder_setPerformanceMode
             AAudioStreamBuilder_setSharingMode AAudioStreamBuilder_setUsage AAudioStreamBuilder_setContentType
             AAudioStreamBuilder_setDataCallback AAudioStreamBuilder_setErrorCallback
             AAudioStreamBuilder_openStream AAudioStreamBuilder_delete AAudioStream_requestStart AAudioStream_close
             AAudioStream_getSampleRate AAudioStream_getFramesPerBurst AAudioStream_setBufferSizeInFrames
             AAudioStream_getBufferSizeInFrames AAudioStream_getSharingMode AAudioStream_getPerformanceMode
             AAudioStream_getXRunCount AAudioStream_getFramesWritten AAudioStream_getTimestamp
             AAudioStream_getDeviceId AAudio_convertResultToText)

  setup do
    dir = Path.join(System.tmp_dir!(), "fmutate_audionif_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp erts_include,
    do: Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "include"])

  defp cc!(args) do
    {out, status} = System.cmd("xcrun", ["clang" | args], stderr_to_stdout: true)
    assert status == 0, out
  end

  defp aaudio_headers do
    roots =
      [
        System.get_env("ANDROID_NDK_HOME")
        | Path.wildcard(Path.expand("~/Library/Android/sdk/ndk/*"))
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(roots, fn root ->
      root
      |> Path.join("toolchains/llvm/prebuilt/*/sysroot/usr/include/aaudio")
      |> Path.wildcard()
      |> List.first()
    end)
  end

  # FMutate.AudioNif.start/0 twice in a VM whose working directory is `dir`; what it printed, and how it ended
  defp start_twice(dir) do
    ebin = Path.dirname(:code.which(FMutate.AudioNif))

    script = """
    IO.inspect(FMutate.AudioNif.start(), label: "start")
    IO.inspect(FMutate.AudioNif.start(), label: "start")
    IO.puts("alive")
    """

    System.cmd("elixir", ["-pa", ebin, "-e", script], cd: dir, stderr_to_stdout: true)
  end

  # the AAudio side of the NIF in `dir`, beside a libaaudio.so exporting `names` (all failing calls)
  defp aaudio_rig(dir, names) do
    headers = aaudio_headers() || flunk("no NDK AAudio.h: set ANDROID_NDK_HOME")
    File.mkdir_p!(Path.join(dir, "inc"))
    File.ln_s!(headers, Path.join(dir, "inc/aaudio"))

    cc!(
      ~w[-bundle -undefined dynamic_lookup -DFM1AUDIO_AAUDIO -D__INTRODUCED_IN(x)= -I#{erts_include()}
         -I#{dir}/inc #{@src} -o #{dir}/fm1audio.so]
    )

    stub =
      Enum.map_join(names, "\n", fn
        "AAudio_createStreamBuilder" ->
          "int AAudio_createStreamBuilder(void **b) { return -899; }"

        "AAudio_convertResultToText" ->
          ~s|const char *AAudio_convertResultToText(int r) { return "stub"; }|

        name ->
          "void #{name}(void) {}"
      end)

    File.write!(Path.join(dir, "stub.c"), stub)
    cc!(~w(-dynamiclib #{dir}/stub.c -o #{dir}/libaaudio.so))
  end

  test "an AAudio library missing a function counts as no AAudio, at every start (no half-loaded API)",
       ctx do
    aaudio_rig(ctx.dir, List.delete(@aaudio, "AAudio_createStreamBuilder"))
    {out, status} = start_twice(ctx.dir)
    assert status == 0, out

    assert out =~
             ~r/start: \{:error, ~c"libaaudio.so not available"\}\s+start: \{:error, ~c"libaaudio.so not available"\}\s+alive/
  end

  test "(the same rig with every function: the library is found and used)", ctx do
    aaudio_rig(ctx.dir, @aaudio)
    {out, status} = start_twice(ctx.dir)
    assert status == 0, out
    assert out =~ ~s|start: {:error, ~c"stub"}|
  end

  test "RemoteIO: an output that fails after the audio session is active gives the session back",
       ctx do
    File.write!(Path.join(ctx.dir, "session.c"), """
    #include <stdio.h>
    #include <stdint.h>
    #include <AudioToolbox/AudioToolbox.h>
    int32_t fm1_session_activate(double *rate, double *io, void (*on_event)(int32_t)) {
        fprintf(stderr, "session: activate\\n"); *rate = 48000; *io = 0.005; return 0;
    }
    void fm1_session_deactivate(void) { fprintf(stderr, "session: deactivate\\n"); }
    double fm1_session_latency(void) { return 0; }
    /* (no RemoteIO unit: the first step after the session fails) */
    AudioComponent fm1test_find_next(AudioComponent c, const AudioComponentDescription *d) { return NULL; }
    """)

    cc!(~w(-bundle -undefined dynamic_lookup -DkAudioUnitSubType_RemoteIO=0x72696f63
         -DAudioComponentFindNext=fm1test_find_next -I#{erts_include()} #{@src} #{ctx.dir}/session.c
         -framework AudioToolbox -o #{ctx.dir}/fm1audio.so))

    {out, status} = start_twice(ctx.dir)
    assert status == 0, out

    assert Regex.scan(~r/session: \w+/, out) |> List.flatten() ==
             List.duplicate(["session: activate", "session: deactivate"], 2) |> List.flatten()

    assert out =~ ~s|start: {:error, ~c"no RemoteIO unit"}|
  end

  # The mixer itself (RemoteIO build, no stream): fm1audio.c with a `render(n)` NIF that runs the audio callback's
  # mixing for n frames (44.1 kHz, no resampling), as module FMutate.MixRig in a VM of its own. `ops` run in order
  # on slot 0, attached to a ring at `ring`; each {:render, n} first makes n more frames available. Returns the
  # renders as [{left, right}] lists.
  defp mix_rig(dir, ring, ops) do
    File.write!(Path.join(dir, "rig.c"), """
    #include <erl_nif.h>
    #pragma push_macro("ERL_NIF_INIT")
    #undef ERL_NIF_INIT
    #define ERL_NIF_INIT(...)
    #include "#{@src}"
    #pragma pop_macro("ERL_NIF_INIT")
    int32_t fm1_session_activate(double *rate, double *io, void (*on_event)(int32_t)) { return -1; }
    void fm1_session_deactivate(void) {}
    double fm1_session_latency(void) { return 0; }
    static ERL_NIF_TERM rig_render(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        int n; ErlNifBinary out;
        if (!enif_get_int(env, argv[0], &n) || !enif_alloc_binary(n * 4, &out)) return enif_make_badarg(env);
        render_out((int16_t *)out.data, n);
        return enif_make_binary(env, &out);
    }
    static ErlNifFunc rig_funcs[] = {
        {"attach", 2, nif_attach, 0}, {"gain", 3, nif_gain, 0}, {"balance", 3, nif_balance, 0},
        {"render", 1, rig_render, 0},
    };
    ERL_NIF_INIT(Elixir.FMutate.MixRig, rig_funcs, NULL, NULL, NULL, NULL)
    """)

    # (macOS's SDK has no RemoteIO subtype: the existing RemoteIO test defines it the same way)
    cc!(~w(-bundle -undefined dynamic_lookup -DkAudioUnitSubType_RemoteIO=0x72696f63 -Wno-unused-function
         -Wno-unused-variable -I#{erts_include()}
         #{dir}/rig.c -framework AudioToolbox -o #{dir}/mixrig.so))

    File.write!(Path.join(dir, "ops.bin"), :erlang.term_to_binary({ring, ops}))

    script = """
    defmodule FMutate.MixRig do
      @on_load :load
      def load, do: :erlang.load_nif(~c"./mixrig", 0)
      def attach(_s, _p), do: :erlang.nif_error(:nif_not_loaded)
      def gain(_s, _g, _ms), do: :erlang.nif_error(:nif_not_loaded)
      def balance(_s, _b, _ms), do: :erlang.nif_error(:nif_not_loaded)
      def render(_n), do: :erlang.nif_error(:nif_not_loaded)
    end

    {ring, ops} = :erlang.binary_to_term(File.read!("ops.bin"))
    :ok = FMutate.MixRig.attach(0, ring)
    {:ok, fd} = :file.open(ring, [:read, :write, :raw, :binary])

    {outs, _} =
      Enum.flat_map_reduce(ops, 0, fn
        {:gain, g, ms}, w -> {[], (:ok = FMutate.MixRig.gain(0, g, ms)) && w}
        {:balance, b, ms}, w -> {[], (:ok = FMutate.MixRig.balance(0, b, ms)) && w}
        {:render, n}, w ->
          :ok = :file.pwrite(fd, 16, <<w + n::little-64>>)
          {[FMutate.MixRig.render(n)], w + n}
      end)

    IO.write("renders:" <> Base.encode64(:erlang.term_to_binary(outs)))
    """

    {out, status} = System.cmd("elixir", ["-e", script], cd: dir, stderr_to_stdout: true)
    assert status == 0, out
    [_, b64] = String.split(out, "renders:")

    for bin <- :erlang.binary_to_term(Base.decode64!(b64)) do
      for <<l::little-signed-16, r::little-signed-16 <- bin>>, do: {l, r}
    end
  end

  # one period of the test signal, 441 frames (10 ms): left and right differ and are never 0
  @period 441

  # a ring of `periods` × @period frames of it, nothing written yet (the engine's ring header, docs/engine_protocol.md)
  defp ring!(dir, periods) do
    cap = periods * @period
    frames =
      for _ <- 1..periods, i <- 0..(@period - 1), into: <<>>,
        do: <<2000 + 30 * i::little-16, -3000 - 20 * i::little-16>>

    header = <<0x464D3152::little-32, cap::little-32, 44_100::little-32, 0::32, 0::64, 0::64, 0::64, 0::32, 0::160>>
    path = Path.join(dir, "ring")
    File.write!(path, header <> frames)
    path
  end

  test "balance: centre is the ring as it is, bit for bit; an end silences the other channel; moves are ramped",
       ctx do
    ring = ring!(ctx.dir, 8)
    p = @period

    [plain, centre, left, right, ramp_left, back, settled] =
      mix_rig(ctx.dir, ring, [
        {:gain, 1000, 0},
        {:render, p},
        {:balance, 500, 0},
        {:render, p},
        {:balance, 0, 0},
        {:render, p},
        {:balance, 1000, 0},
        {:render, p},
        {:balance, 500, 0},
        {:balance, 0, 15},
        {:render, 2 * p},
        {:balance, 500, 15},
        {:render, 2 * p},
        {:render, p}
      ])

    {ls, rs} = Enum.unzip(plain)
    assert Enum.all?(ls, &(&1 > 0)) and Enum.all?(rs, &(&1 < 0))
    assert centre == plain

    # full left: the right channel is silent, the left untouched; full right the other way round
    assert left == Enum.map(plain, fn {l, _} -> {l, 0} end)
    assert right == Enum.map(plain, fn {_, r} -> {0, r} end)

    # 15 ms to the left (662 frames): the right channel fades, from almost all of it to nothing; the left stays
    {ramp_l, ramp_r} = Enum.unzip(ramp_left)
    assert ramp_l == ls ++ ls
    share = fn i -> Enum.at(ramp_r, i) / Enum.at(rs ++ rs, i) end
    assert share.(0) > 0.99 and share.(0) < 1
    assert_in_delta share.(331), 0.5, 0.01
    assert ramp_r |> Enum.drop(662) |> Enum.all?(&(&1 == 0))

    # and back: the ramp lands exactly on the centre
    refute back == plain ++ plain
    assert settled == plain
  end
end
