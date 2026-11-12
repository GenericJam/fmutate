defmodule FMutate.SubscriptionTest do
  use ExUnit.Case, async: true

  require FMutate.Subscription

  alias FMutate.Subscription

  # a server that keeps its subscribers in its state, as Instance/Library/IO/Dist do
  defmodule Server do
    use GenServer

    def start(name), do: GenServer.start(__MODULE__, nil, name: name)
    def subscribe(name), do: GenServer.call(name, :subscribe)
    def subscribers(name), do: GenServer.call(name, :subscribers)

    @impl true
    def init(nil), do: {:ok, []}

    @impl true
    def handle_call(:subscribe, {pid, _}, subs), do: {:reply, {:hello, self()}, [pid | subs]}
    def handle_call(:subscribers, _from, subs), do: {:reply, subs, subs}
  end

  defp name, do: :"sub_test_#{System.unique_integer([:positive])}"

  # the next helper message, through Subscription.handle/1, as a screen's handle_info would
  defp next_event(timeout \\ 1_000) do
    receive do
      msg when Subscription.message?(msg) -> Subscription.handle(msg)
    after
      timeout -> flunk("no subscription message within #{timeout} ms")
    end
  end

  test "subscribes, and subscribes again once a restarted server is back" do
    name = name()
    {:ok, first} = Server.start(name)

    assert {:ok, {:hello, ^first}} =
             Subscription.subscribe(:s, name, fn -> Server.subscribe(name) end)

    assert Server.subscribers(name) == [self()]

    Process.exit(first, :kill)
    assert {:down, :s} = next_event()
    # still down at the first retry
    assert :pending = next_event()

    {:ok, second} = Server.start(name)
    assert {:subscribed, :s, {:hello, ^second}} = next_event()
    assert Server.subscribers(name) == [self()]

    # and it watches the new one
    Process.exit(second, :kill)
    assert {:down, :s} = next_event()
  end

  test "a server that isn't up yet is pending until it starts" do
    name = name()
    assert :pending = Subscription.subscribe(:late, name, fn -> Server.subscribe(name) end)

    {:ok, pid} = Server.start(name)
    assert {:subscribed, :late, {:hello, ^pid}} = next_event()
  end

  test "keys are independent; cancel stops the watching; other messages aren't the helper's" do
    a = name()
    b = name()
    {:ok, pa} = Server.start(a)
    {:ok, _} = Server.start(b)
    {:ok, _} = Subscription.subscribe(:a, a, fn -> Server.subscribe(a) end)
    {:ok, _} = Subscription.subscribe(:b, b, fn -> Server.subscribe(b) end)

    :ok = Subscription.cancel(:b)
    Process.exit(pa, :kill)
    assert {:down, :a} = next_event()

    refute Subscription.message?({:DOWN, make_ref(), :process, self(), :normal})
    refute Subscription.message?({:instance, "a", {:state, %{}}})
    refute Subscription.message?(:refresh)
  end
end
