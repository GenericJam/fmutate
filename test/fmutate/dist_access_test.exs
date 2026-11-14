defmodule FMutate.Dist.AccessTest do
  use ExUnit.Case, async: true

  alias FMutate.Dist.{Access, Requests}

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

  describe "registrations (the content provider's requests directory)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "fmutate_requests_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "a sibling's name is taken once; anything else is deleted unread", %{dir: dir} do
      fresh = "zz#{System.unique_integer([:positive])}"
      good = ["voice@127.0.0.1", "humdinger_ab2c@127.0.0.1", "fmutate_probe@127.0.0.1"]

      bad = [
        "#{fresh}A@127.0.0.1",
        "#{fresh}@192.168.1.4",
        "#{fresh}@127.0.0.1.tmp",
        "1#{fresh}@127.0.0.1",
        "#{String.duplicate("a", 65)}@127.0.0.1",
        "fmutate_a@127.0.0.1"
      ]

      for name <- good ++ bad, do: File.touch!(Path.join(dir, name))

      assert Enum.sort(Requests.take(dir)) == Enum.sort(good)
      assert File.ls!(dir) == []
      assert Requests.take(dir) == []

      for name <- bad,
          name =~ fresh,
          do: assert_raise(ArgumentError, fn -> String.to_existing_atom(name) end)
    end

    test "at most 16 at a time, the oldest first; the rest are dropped", %{dir: dir} do
      for i <- 1..20 do
        path = Path.join(dir, "app#{i}@127.0.0.1")
        File.touch!(path, 1_700_000_000 + i)
      end

      assert Requests.take(dir) == for(i <- 1..16, do: "app#{i}@127.0.0.1")
      assert File.ls!(dir) == []
    end

    test "no directory, no registrations" do
      assert Requests.take("/nonexistent/requests") == []
    end
  end
end
