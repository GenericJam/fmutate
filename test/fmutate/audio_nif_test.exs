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
  # on slot 0, attached to a ring at `ring`; each {:render, n} first makes n more frames available. {:stress, n}
  # runs the callback on a thread of its own (64 frames at a time, as fast as it goes) while n gain and balance
  # commands reverse each other's ramps, then sends gain 1000 and balance 0 (15 ms) and lets it run 50 ms more.
  # {:attach} attaches slot 0 again (a new engine in the same slot); {:noise, n} sends n gain commands to slot 3
  # (no ring). Returns the renders as [{left, right}] lists.
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
    static _Atomic int spin_on;
    static _Atomic uint64_t spun;
    static pthread_t spin_t;
    static void *spin_main(void *a) {
        static int16_t buf[64 * 2];
        while (atomic_load(&spin_on)) { render_out(buf, 64); atomic_fetch_add(&spun, 1); }
        return NULL;
    }
    static ERL_NIF_TERM rig_spin(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        atomic_store(&spin_on, 1);
        return enif_make_atom(env, pthread_create(&spin_t, NULL, spin_main, NULL) ? "error" : "ok");
    }
    static ERL_NIF_TERM rig_unspin(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        atomic_store(&spin_on, 0);
        pthread_join(spin_t, NULL);
        return enif_make_uint64(env, atomic_load(&spun));
    }
    static ERL_NIF_TERM rig_render(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
        int n; ErlNifBinary out;
        if (!enif_get_int(env, argv[0], &n) || !enif_alloc_binary(n * 4, &out)) return enif_make_badarg(env);
        render_out((int16_t *)out.data, n);
        return enif_make_binary(env, &out);
    }
    static ErlNifFunc rig_funcs[] = {
        {"attach", 2, nif_attach, 0}, {"gain", 3, nif_gain, 0}, {"balance", 3, nif_balance, 0},
        {"render", 1, rig_render, 0}, {"spin", 0, rig_spin, 0}, {"unspin", 0, rig_unspin, ERL_NIF_DIRTY_JOB_CPU_BOUND},
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
      def spin, do: :erlang.nif_error(:nif_not_loaded)
      def unspin, do: :erlang.nif_error(:nif_not_loaded)
    end

    {ring, ops} = :erlang.binary_to_term(File.read!("ops.bin"))
    :ok = FMutate.MixRig.attach(0, ring)
    {:ok, fd} = :file.open(ring, [:read, :write, :raw, :binary])

    {outs, _} =
      Enum.flat_map_reduce(ops, 0, fn
        {:gain, g, ms}, w -> {[], (:ok = FMutate.MixRig.gain(0, g, ms)) && w}
        {:balance, b, ms}, w -> {[], (:ok = FMutate.MixRig.balance(0, b, ms)) && w}
        {:attach}, w -> {[], (:ok = FMutate.MixRig.attach(0, ring)) && w}
        {:noise, n}, w -> {[], Enum.each(1..n, fn i -> :ok = FMutate.MixRig.gain(3, rem(i, 1000), 5) end) && w}
        {:stress, n}, w ->
          :ok = FMutate.MixRig.spin()

          for i <- 1..n do
            :ok = FMutate.MixRig.balance(0, if(rem(i, 2) == 0, do: 1000, else: 0), rem(i, 20))
            :ok = FMutate.MixRig.gain(0, if(rem(i, 3) == 0, do: 200, else: 1000), rem(i, 7))
            if rem(i, 50) == 0, do: Process.sleep(1)
          end

          :ok = FMutate.MixRig.gain(0, 1000, 15)
          :ok = FMutate.MixRig.balance(0, 0, 15)
          Process.sleep(50)
          true = FMutate.MixRig.unspin() > 100
          {[], w}

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

    [plain, centre, left, right, centre_again, ramp_left, back, settled, _to_right, reversing, reversed, stressed] =
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
        {:render, p},
        {:balance, 0, 15},
        {:render, 2 * p},
        {:balance, 500, 15},
        {:render, 2 * p},
        {:render, p},
        # a move reversed in the middle of its ramp
        {:balance, 1000, 15},
        {:render, 200},
        {:balance, 0, 15},
        {:render, 2 * p - 200},
        {:render, p},
        # commands from another thread while the mixer runs
        {:stress, 3000},
        {:render, p}
      ])

    {ls, rs} = Enum.unzip(plain)
    assert Enum.all?(ls, &(&1 > 0)) and Enum.all?(rs, &(&1 < 0))
    assert centre == plain and centre_again == plain

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

    # reversed a third of the way to the right: the right channel goes from all of it to nothing, and stays
    {_, rev_r} = Enum.unzip(reversing)
    assert hd(rev_r) == Enum.at(rs, 200)
    assert rev_r |> Enum.drop(662) |> Enum.all?(&(&1 == 0))
    assert reversed == left

    # the last command lands however the commands met the mixer
    assert stressed == left
  end

  # (1023 and 1023 other commands first: a command used to be told apart by a 10-bit count of every command, and
  # these two came out equal to what the slot had when it was attached)
  test "a slot's first commands after attach land, whatever was sent before (to it or to other slots)", ctx do
    ring = ring!(ctx.dir, 8)
    p = @period

    [fresh, right, reattached] =
      mix_rig(ctx.dir, ring, [
        {:noise, 1023},
        {:balance, 0, 0},
        {:gain, 1000, 0},
        {:render, p},
        {:balance, 1000, 0},
        {:render, p},
        {:attach},
        {:noise, 1023},
        {:balance, 1000, 0},
        {:gain, 1000, 0},
        {:render, p}
      ])

    {l, r} = Enum.unzip(fresh)
    assert Enum.all?(l, &(&1 > 0)) and Enum.all?(r, &(&1 == 0))
    {l, r} = Enum.unzip(right)
    assert Enum.all?(l, &(&1 == 0)) and Enum.all?(r, &(&1 < 0))
    assert reattached == right
  end

  # (a sanitizer can't be loaded into the BEAM on macOS, so this runs the mixer in a plain executable: NIF terms are
  # plain ints there)
  test "gain and balance commands while the callback mixes: no data race (ThreadSanitizer)", ctx do
    File.write!(Path.join(ctx.dir, "race.c"), """
    #include <erl_nif.h>
    #include <stdio.h>
    #include <stdlib.h>
    #pragma push_macro("ERL_NIF_INIT")
    #undef ERL_NIF_INIT
    #define ERL_NIF_INIT(...)
    #include "#{@src}"
    #pragma pop_macro("ERL_NIF_INIT")
    int32_t fm1_session_activate(double *rate, double *io, void (*on_event)(int32_t)) { return -1; }
    void fm1_session_deactivate(void) {}
    double fm1_session_latency(void) { return 0; }
    int enif_get_int(ErlNifEnv *env, ERL_NIF_TERM t, int *ip) { *ip = (int)t; return 1; }
    ERL_NIF_TERM enif_make_atom(ErlNifEnv *env, const char *name) { return 0; }
    static _Atomic int on = 1;
    static void *render(void *a) { static int16_t buf[128]; while (atomic_load(&on)) render_out(buf, 64); return NULL; }
    int main(void) {
        size_t len = sizeof(ring_hdr) + 4410 * 4;
        ring_hdr *rg = calloc(1, len);
        pthread_t t;
        rg->magic = RING_MAGIC; rg->capacity = 4410; rg->rate = 44100;
        slots[0].map_len = len;
        atomic_store(&slots[0].ring, rg);
        pthread_create(&t, NULL, render, NULL);
        for (int i = 0; i < 100000; i++) {
            ERL_NIF_TERM b[3] = {0, (i & 1) ? 1000 : 0, 15}, g[3] = {0, (i & 2) ? 1000 : 200, 7};
            nif_balance(NULL, 3, b);
            nif_gain(NULL, 3, g);
        }
        atomic_store(&on, 0);
        pthread_join(t, NULL);
        puts("done");
        return 0;
    }
    """)

    cc!(~w(-fsanitize=thread -g -DkAudioUnitSubType_RemoteIO=0x72696f63 -Wno-unused-function -Wno-unused-variable
         -I#{erts_include()} #{ctx.dir}/race.c -framework AudioToolbox -Wl,-undefined,dynamic_lookup
         -o #{ctx.dir}/race))

    {out, _} =
      System.cmd(Path.join(ctx.dir, "race"), [], stderr_to_stdout: true, env: [{"TSAN_OPTIONS", "halt_on_error=0"}])

    assert out =~ "done"
    refute out =~ "ThreadSanitizer", out
  end
end
