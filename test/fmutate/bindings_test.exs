defmodule FMutate.BindingsTest do
  use ExUnit.Case, async: true

  alias FMutate.{Bindings, InstrumentView}

  describe "absolute targets: last move wins, others pick up" do
    test "the first control to move a target owns it" do
      {:send, 0.3, b} = Bindings.absolute(Bindings.new(), "pot:master", "a", 0.3)
      refute Bindings.stale?(b, "pot:master", "a")
      assert Bindings.stale?(b, "pot:master", "b")
    end

    test "a stale control far from the value is ignored until it reaches it" do
      {:send, _, b} = Bindings.absolute(Bindings.new(), "cc:1:74", "a", 0.8)
      # b picks it up (lands next to 0.8), then takes it down to 0.2
      {:send, _, b} = Bindings.absolute(b, "cc:1:74", "b", 0.79)
      {:send, _, b} = Bindings.absolute(b, "cc:1:74", "b", 0.2)
      # a was at 0.8, the value is 0.2 now: a's jumps at 0.9 and 0.7 don't take it
      assert {:ignore, b} = Bindings.absolute(b, "cc:1:74", "a", 0.9)
      assert {:ignore, b} = Bindings.absolute(b, "cc:1:74", "a", 0.7)
      assert Bindings.value(b, "cc:1:74") == 0.2
      # within the pickup window: a takes over
      {:send, 0.22, b} = Bindings.absolute(b, "cc:1:74", "a", 0.22)
      assert Bindings.stale?(b, "cc:1:74", "b")
      refute Bindings.stale?(b, "cc:1:74", "a")
    end

    test "passing over the value picks it up" do
      {:send, _, b} = Bindings.absolute(Bindings.new(), "pot:master", "a", 0.5)
      {:send, _, b} = Bindings.absolute(b, "pot:master", "b", 0.52)
      {:send, _, b} = Bindings.absolute(b, "pot:master", "b", 0.9)
      {:ignore, b} = Bindings.absolute(b, "pot:master", "a", 0.1)
      assert {:ignore, b} = Bindings.absolute(b, "pot:master", "a", 0.6)
      # from 0.6 to 0.95 it passes 0.9: picked up
      assert {:send, 0.95, _} = Bindings.absolute(b, "pot:master", "a", 0.95)
    end

    test "targets are independent" do
      {:send, _, b} = Bindings.absolute(Bindings.new(), "cc:1:1", "a", 0.1)
      assert {:send, 0.9, _} = Bindings.absolute(b, "cc:1:2", "b", 0.9)
    end
  end

  describe "at play time (the instrument view's inputs)" do
    test "encoder clicks from two controls on one encoder all reach the firmware (deltas add)" do
      {e1, b} = InstrumentView.arbitrate(Bindings.new(), %{"t" => "encoder", "id" => "knob1", "clicks" => 3, "c" => "x"})
      {e2, _} = InstrumentView.arbitrate(b, %{"t" => "encoder", "id" => "knob1", "clicks" => 2, "c" => "y"})
      assert [{:encoder, :knob1, 3}, {:encoder, :knob1, 2}] = [e1, e2]
    end

    test "a pot move from a control that hasn't picked up is dropped" do
      {{:pot, :master, 0.3}, b} = InstrumentView.arbitrate(Bindings.new(), %{"t" => "pot", "v" => 0.3, "c" => "slider"})
      assert {nil, b} = InstrumentView.arbitrate(b, %{"t" => "pot", "v" => 0.9, "c" => "knob"})
      assert {{:pot, :master, 0.31}, _} = InstrumentView.arbitrate(b, %{"t" => "pot", "v" => 0.31, "c" => "knob"})
    end

    test "MIDI CC follows the same rule; notes and keys pass straight through" do
      cc = fn v, c -> %{"t" => "midi", "bytes" => [0xB0, 74, round(v * 127)], "abs" => "cc:1:74", "v" => v, "c" => c} end
      {{:midi, <<0xB0, 74, 13>>}, b} = InstrumentView.arbitrate(Bindings.new(), cc.(0.1, "a"))
      assert {nil, b} = InstrumentView.arbitrate(b, cc.(1.0, "b"))
      assert {{:key, 3, :down}, ^b} = InstrumentView.arbitrate(b, %{"t" => "key", "k" => 3, "d" => true})
    end
  end
end
