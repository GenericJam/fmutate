defmodule FMutate.RemoteTest do
  # The sibling-app facade on a real instance (host engine, native/build_host.sh), called locally: the
  # protocol checks, the calls and the status/leds subscription. Distribution itself is exercised on a device
  # (tools/sibling_probe.exs).
  use ExUnit.Case, async: false

  alias FMutate.{Instance, Remote}

  @moduletag :engine

  describe "inputs (protocol.md §2)" do
    test "the protocol's key press is the instance's" do
      assert Remote.to_input({:key, 7, :down, 100}) == {:key, 7, :down}
      assert Remote.to_input({:key, 7, :up}) == {:key, 7, :up}
    end

    test "inputs outside §2 are dropped, never passed on" do
      assert Remote.to_input({:key, 27, :down, 100}) == nil
      assert Remote.to_input({:key, 3, :down, 0}) == nil
      assert Remote.to_input({:button, :launch_missiles, :down}) == nil
      assert Remote.to_input({:encoder, :knob9, 1}) == nil
      assert Remote.to_input({:pot, :master, 1.5}) == nil
      assert Remote.to_input({:spawn, fn -> :ok end}) == nil
    end

    test "buttons, encoders, pot and MIDI pass" do
      assert Remote.to_input({:button, :play, :down}) == {:button, :play, :down}
      assert Remote.to_input({:encoder, :knob1, -2}) == {:encoder, :knob1, -2}
      assert Remote.to_input({:pot, :master, 1}) == {:pot, :master, 1.0}
      assert Remote.to_input({:midi, <<0x90, 60, 1>>}) == {:midi, <<0x90, 60, 1>>}
    end
  end

  test "status: phases, and slow when the instance says so" do
    assert Remote.status_of(%{phase: :running, slow: false, clock_pct: 100}) == :running
    # the instance's hysteresis decides: a dip below 95 % isn't slow yet
    assert Remote.status_of(%{phase: :running, slow: false, clock_pct: 90}) == :running
    assert Remote.status_of(%{phase: :running, slow: true, clock_pct: 80}) == {:slow, 80}
    assert Remote.status_of(%{phase: :booting, slow: false, clock_pct: nil}) == :booting
    assert Remote.status_of(%{phase: :not_installed, slow: false, clock_pct: nil}) == :crashed
  end

  test "LEDs: 27 key bits and the 14 buttons by name" do
    {keys, buttons} = Remote.leds_of(%{led_keys: 0xFFFFFFFF, led_buttons: 0b1_0000_0000_0001})
    assert keys == 0x7FFFFFF
    assert buttons.oct_down == :on and buttons.play == :on and buttons.rec == :off
    assert map_size(buttons) == 14
  end

  describe "the facade process" do
    setup do
      unless File.exists?(FMutate.Paths.engine_bin()),
        do: raise("run native/build_host.sh first: no #{FMutate.Paths.engine_bin()}")

      dir = Path.join(System.tmp_dir!(), "fmutate_test_#{System.unique_integer([:positive])}")
      Application.put_env(:fmutate_app, :data_dir, dir)
      start_supervised!({Registry, keys: :unique, name: FMutate.Registry})
      start_supervised!(FMutate.Audio)
      start_supervised!({Instance, id: "a"}, id: {:instance, "a"})
      start_supervised!({Remote, id: "a", register_local: false}, id: {:remote, "a"})

      on_exit(fn ->
        Application.delete_env(:fmutate_app, :data_dir)
        File.rm_rf(dir)
      end)

      :ok
    end

    defp call(payload, id \\ "a", version \\ 1),
      do: GenServer.call({:global, {:fmutate, "a"}}, {:fmutate, version, id, payload})

    test "names the instance and the protocol version" do
      assert call({:list_firmware}, "b") == {:error, :no_such_instance}
      assert call({:list_firmware}, "a", 2) == {:error, :unsupported_version}
      assert call({:reboot_phone}) == {:error, :unsupported}
    end

    test "lists firmwares and layouts" do
      {:ok, fws} = call({:list_firmware})
      assert %{id: "obervave", status: s} = Enum.find(fws, &(&1.id == "obervave"))
      assert s in [:running, :installed]
      {:ok, layouts} = call({:list_layouts, "obervave"})
      assert Enum.any?(layouts, &(&1.id == "classic"))
      {:ok, json} = call({:get_layout, "classic"})
      assert is_binary(json)
      assert call({:get_layout, "nope"}) == {:error, :not_found}
    end

    test "subscribers get the status, and unknown topics are refused" do
      assert call({:subscribe, self(), [:bogus]}) == {:error, {:unknown_topics, [:bogus]}}
      assert call({:subscribe, self(), [:status, :leds]}) == :ok
      assert_receive {:status, status}
      assert status in [:booting, :running]
      assert_receive {:status, :running}, 5_000
      assert_receive {:leds, keys, buttons}, 5_000
      assert is_integer(keys) and map_size(buttons) == 14
    end

    test "a key press sent as a message reaches the engine" do
      Instance.subscribe("a")
      wait_running()
      send(:global.whereis_name({:fmutate, "a"}), {:fmutate, 1, "a", {:key, 7, :down, 100}})
      :sys.get_state(Remote.via("a"))
      assert MapSet.member?(:sys.get_state(Instance.via("a")).held_keys, 7)
      GenServer.cast({:global, {:fmutate, "a"}}, {:fmutate, 1, "a", {:key, 7, :up}})
      :sys.get_state(Remote.via("a"))
      refute MapSet.member?(:sys.get_state(Instance.via("a")).held_keys, 7)
    end
  end

  defp wait_running do
    if Instance.view("a").phase == :running do
      :ok
    else
      assert_receive {:instance, "a", {:state, %{phase: :running}}}, 5_000
    end
  end
end
