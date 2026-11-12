defmodule FMutate.Subscription do
  @moduledoc """
  Subscriptions that survive their server's restart, for screens (and any other subscriber process).

  `FMutate.Instance`, `FMutate.Library`, `FMutate.IO` and `FMutate.Dist` keep their subscribers in their
  own state, so a restarted server has none and an open screen would silently stop hearing from it.
  `subscribe/3` subscribes through a function and monitors the server; when the server goes down (or
  isn't up yet) it retries every 200 ms until the server is back and the subscribe call succeeds.

      # mount: the subscribe function's result, or `:pending` while the server is down
      {:ok, view} = Subscription.subscribe(:instance, Instance.via("a"), fn -> Instance.subscribe("a") end)

      # handle_info: one clause routes the helper's own messages
      def handle_info(msg, socket) when Subscription.message?(msg) do
        case Subscription.handle(msg) do
          {:subscribed, :instance, view} -> {:noreply, assign(socket, :view, view)}
          _ -> {:noreply, socket}
        end
      end

  The bookkeeping (server, subscribe function, monitor) lives in the subscriber's process dictionary,
  keyed by the caller's `key`, so a screen needs no extra assigns.
  """

  @retry_ms 200

  @doc "Whether `msg` is one of this helper's messages (a monitor DOWN or a retry); usable in guards."
  defguard message?(msg)
           when is_tuple(msg) and tuple_size(msg) in [2, 5] and is_tuple(elem(msg, 0)) and
                  tuple_size(elem(msg, 0)) == 2 and elem(elem(msg, 0), 0) == __MODULE__

  @doc """
  Subscribe to `server` (a pid, name or `:via` tuple) by calling `fun` in this process, and keep
  subscribed across its restarts. `{:ok, result}` with `fun`'s result, or `:pending` when the server
  isn't up (or exits during the call): the subscription then arrives later as
  `{:subscribed, key, result}` from `handle/1`.
  """
  @spec subscribe(term, GenServer.server(), (-> result)) :: {:ok, result} | :pending
        when result: term
  def subscribe(key, server, fun) when is_function(fun, 0) do
    cancel(key)

    with pid when is_pid(pid) <- GenServer.whereis(server),
         ref = Process.monitor(pid, tag: {__MODULE__, key}),
         {:ok, result} <- call(fun, ref) do
      Process.put({__MODULE__, key}, %{server: server, fun: fun, ref: ref})
      {:ok, result}
    else
      _ ->
        Process.put({__MODULE__, key}, %{server: server, fun: fun, ref: nil})
        Process.send_after(self(), {{__MODULE__, key}, :retry}, @retry_ms)
        :pending
    end
  end

  @doc """
  Handle one of this helper's messages (`message?/1`): `{:down, key}` when the server went down (a
  retry is scheduled), `{:subscribed, key, result}` once subscribed again, `:pending` while it is
  still down, `:ignore` for a stale message.
  """
  @spec handle(tuple) :: {:down, term} | {:subscribed, term, term} | :pending | :ignore
  def handle({{__MODULE__, key}, ref, :process, _pid, _reason}) do
    case Process.get({__MODULE__, key}) do
      %{ref: ^ref} = sub ->
        Process.put({__MODULE__, key}, %{sub | ref: nil})
        Process.send_after(self(), {{__MODULE__, key}, :retry}, @retry_ms)
        {:down, key}

      _ ->
        :ignore
    end
  end

  def handle({{__MODULE__, key}, :retry}) do
    case Process.get({__MODULE__, key}) do
      %{ref: nil, server: server, fun: fun} ->
        case subscribe(key, server, fun) do
          {:ok, result} -> {:subscribed, key, result}
          :pending -> :pending
        end

      _ ->
        :ignore
    end
  end

  @doc "Stop watching `key` (the server keeps its own subscriber entry until this process exits)."
  @spec cancel(term) :: :ok
  def cancel(key) do
    case Process.delete({__MODULE__, key}) do
      %{ref: ref} when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _ -> :ok
    end

    :ok
  end

  # the subscribe call; a server exiting under it (restarting, gone) is a retry, not a crash
  defp call(fun, ref) do
    {:ok, fun.()}
  catch
    :exit, _ ->
      Process.demonitor(ref, [:flush])
      :error
  end
end
