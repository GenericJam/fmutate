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
end
