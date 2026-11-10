defmodule FMutate.Dist.Knock do
  @moduledoc """
  Hears refused distribution handshakes. A sibling app that isn't allowed yet connects with the sibling
  cookie, which this node doesn't accept for it, so OTP's handshake (`dist_util`) refuses it and logs

      ** Connection attempt from node <node> rejected. Invalid challenge reply. **

  This `:logger` handler turns that report into `{:knock, node}` for `FMutate.Dist`, which lists the node as
  pending (the player's Allow). OTP has no other hook for a refused handshake.
  """

  @format ~c"** Connection attempt from node ~w rejected. Invalid challenge reply. **~n"

  @doc "Install the handler; knocks go to `pid`."
  def install(pid) do
    _ = :logger.remove_handler(__MODULE__)
    :logger.add_handler(__MODULE__, __MODULE__, %{level: :error, config: %{pid: pid}})
  end

  @doc false
  # :logger handler callback
  def log(event, %{config: %{pid: pid}}) do
    case node_of(event) do
      nil -> :ok
      node -> send(pid, {:knock, node})
    end

    :ok
  end

  @doc """
  The refused node in a log event, or nil. The event reaches handlers as OTP logged it (`{format, args}` or
  an `error_logger` report) or, with Elixir's Logger translating OTP reports (the default), as text.
  """
  def node_of(%{msg: {format, [node]}}) when is_atom(node) and is_list(format),
    do: match_format(format, node)

  def node_of(%{msg: {:report, %{format: format, args: [node]}}}) when is_atom(node),
    do: match_format(format, node)

  def node_of(%{msg: {:string, text}}) do
    case Regex.run(
           ~r/Connection attempt from node :?"?([^\s"]+)"? rejected\. Invalid challenge reply/,
           IO.chardata_to_string(text)
         ) do
      [_, name] -> String.to_atom(name)
      nil -> nil
    end
  end

  def node_of(_event), do: nil

  defp match_format(format, node), do: if(to_charlist(format) == @format, do: node)
end
