defmodule FMutate.Dist.AccessTest do
  use ExUnit.Case, async: true

  alias FMutate.Dist.{Access, Knock}

  @rig :"fmutate_rig@127.0.0.1"
  @voice :"voice@127.0.0.1"

  test "pending → allowed → connected → disconnected" do
    a = Access.new()
    {:pending, a} = Access.knock(a, @rig, 1)
    assert Access.state(a, @rig) == :pending
    refute Access.permitted?(a, @rig)
    assert {:refuse, ^a} = Access.nodeup(a, @rig, 2)

    {:ok, a} = Access.allow(a, @rig, 3)
    assert Access.state(a, @rig) == :allowed
    assert Access.permitted?(a, @rig)
    assert Access.allowed(a) == [@rig]

    {:accept, a} = Access.nodeup(a, @rig, 4)
    assert Access.state(a, @rig) == :connected

    {:ok, a} = Access.disconnect(a, @rig, 5)
    assert Access.state(a, @rig) == :disconnected
    refute Access.permitted?(a, @rig)
    assert Access.allowed(a) == []
    assert {:refuse, _} = Access.nodeup(a, @rig, 6)
  end

  test "a disconnected app that knocks again needs Allow again" do
    {:ok, a} = Access.new([@rig]) |> Access.disconnect(@rig, 1)
    {:pending, a} = Access.knock(a, @rig, 2)
    assert Access.state(a, @rig) == :pending
    {:ok, a} = Access.allow(a, @rig, 3)
    assert {:accept, _} = Access.nodeup(a, @rig, 4)
  end

  test "a connection that drops leaves the app allowed" do
    {:accept, a} = Access.new([@rig]) |> Access.nodeup(@rig, 1)
    a = Access.nodedown(a, @rig, 2)
    assert Access.state(a, @rig) == :allowed
    assert {:accept, _} = Access.nodeup(a, @rig, 3)
  end

  test "unknown nodes are refused and can't be allowed or disconnected" do
    a = Access.new()
    assert {:refuse, ^a} = Access.nodeup(a, @voice, 1)
    refute Access.permitted?(a, @voice)
    assert Access.allow(a, @voice, 1) == {:error, :unknown}
    assert Access.disconnect(a, @voice, 1) == {:error, :unknown}
  end

  test "with the development cookie, unknown nodes that got in are dev tools, not apps" do
    a = Access.new([], dev: true)
    {:dev, a} = Access.nodeup(a, :"rpc_1@127.0.0.1", 1)
    assert MapSet.member?(a.dev_nodes, :"rpc_1@127.0.0.1")
    assert Access.list(a) == []
    refute Access.permitted?(a, :"rpc_1@127.0.0.1")
    a = Access.nodedown(a, :"rpc_1@127.0.0.1", 2)
    assert a.dev_nodes == MapSet.new()
  end

  test "knocks from allowed or connected apps change nothing" do
    a = Access.new([@rig])
    assert {:ignored, ^a} = Access.knock(a, @rig, 1)
  end

  test "only the latest knocks are kept" do
    a =
      Enum.reduce(1..20, Access.new(), fn i, a ->
        a |> Access.knock(:"n#{i}@127.0.0.1", i) |> elem(1)
      end)

    pending = for %{state: :pending, node: n} <- Access.list(a), do: n
    assert length(pending) == 8
    assert :"n20@127.0.0.1" in pending
    refute :"n1@127.0.0.1" in pending
  end

  test "list puts connected apps first" do
    a = Access.new([@voice])
    {:pending, a} = Access.knock(a, @rig, 1)
    {:accept, a} = Access.nodeup(a, @voice, 2)

    assert Enum.map(Access.list(a), &{&1.node, &1.state}) == [
             {@voice, :connected},
             {@rig, :pending}
           ]
  end

  test "the knock handler recognises OTP's refused-handshake report" do
    event = %{
      level: :error,
      msg:
        {~c"** Connection attempt from node ~w rejected. Invalid challenge reply. **~n", [@rig]},
      meta: %{}
    }

    assert Knock.node_of(event) == @rig
    assert Knock.node_of(%{event | msg: {~c"** Node ~p not responding **~n", [@rig]}}) == nil
    assert Knock.node_of(%{event | msg: {:string, "hello"}}) == nil

    # as handlers see it behind Elixir's Logger translator (what the device showed), and as a report
    translated = ~s(** Connection attempt from node :"fmutate_probe@127.0.0.1" rejected. Invalid challenge reply. **)
    assert Knock.node_of(%{event | msg: {:string, translated}}) == :"fmutate_probe@127.0.0.1"

    report = %{label: {:error_logger, :error_msg}, format: elem(event.msg, 0), args: [@rig]}
    assert Knock.node_of(%{event | msg: {:report, report}}) == @rig
  end
end
