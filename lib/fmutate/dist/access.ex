defmodule FMutate.Dist.Access do
  @moduledoc """
  Which sibling apps may drive this FMutate (protocol.md §5, HANDOFF §10): a pure state machine per node,
  kept by `FMutate.Dist`, which turns it into per-node distribution cookies.

      unknown ──knock──▶ pending ──allow──▶ allowed ◀──nodedown── connected
                            ▲                  │ └──────nodeup──────▶ │
                            └──────knock─── disconnected ◀─disconnect─┘ (also from allowed/pending)

    * **knock** — a node tried to connect and was refused at the handshake (it isn't allowed, so its cookie
      didn't match). It is listed as pending, waiting for the player's Allow.
    * **allow** — the player tapped Allow: the node may connect (and reconnect, across restarts) until
      disconnected.
    * **nodeup / nodedown** — an allowed node's connection came up or went away.
    * **disconnect** — the player tapped Disconnect: the connection is cut and the node is refused again
      until it knocks and is allowed anew.

  A node the table doesn't know is refused (`nodeup/2` → `:refuse`), except with `dev: true` (a build
  deployed by mob_dev, whose default cookie is the developer's): nodes that got in with that cookie are
  development tools (`tools/rpc.exs`), listed apart and never offered to the player.
  """

  @max_pending 8

  defstruct apps: %{}, dev: false, dev_nodes: MapSet.new()

  @type state :: :pending | :allowed | :connected | :disconnected
  @type t :: %__MODULE__{
          apps: %{optional(node()) => %{state: state(), since: integer()}},
          dev: boolean(),
          dev_nodes: MapSet.t(node())
        }

  @doc "A table with `allowed` nodes (from a previous run) allowed."
  @spec new([node()], keyword()) :: t()
  def new(allowed \\ [], opts \\ []) do
    apps = Map.new(allowed, &{&1, %{state: :allowed, since: 0}})
    %__MODULE__{apps: apps, dev: Keyword.get(opts, :dev, false)}
  end

  @doc "A refused connection attempt. `:ignored` for allowed or connected nodes (nothing to ask)."
  @spec knock(t(), node(), integer()) :: {:pending | :ignored, t()}
  def knock(%__MODULE__{} = access, node, now) do
    case state(access, node) do
      s when s in [nil, :pending, :disconnected] ->
        {:pending, put(access, node, :pending, now) |> trim()}

      _ ->
        {:ignored, access}
    end
  end

  @doc "The player allows a pending (or disconnected) node. Unknown nodes can't be allowed."
  @spec allow(t(), node(), integer()) :: {:ok, t()} | {:error, :unknown}
  def allow(%__MODULE__{} = access, node, now) do
    case state(access, node) do
      nil -> {:error, :unknown}
      s when s in [:pending, :disconnected] -> {:ok, put(access, node, :allowed, now)}
      _ -> {:ok, access}
    end
  end

  @doc "A connection came up: `:accept` (allowed), `:dev` (development tool) or `:refuse`."
  @spec nodeup(t(), node(), integer()) :: {:accept | :dev | :refuse, t()}
  def nodeup(%__MODULE__{} = access, node, now) do
    case state(access, node) do
      s when s in [:allowed, :connected] -> {:accept, put(access, node, :connected, now)}
      nil when access.dev -> {:dev, %{access | dev_nodes: MapSet.put(access.dev_nodes, node)}}
      _ -> {:refuse, access}
    end
  end

  @doc "A connection went away."
  @spec nodedown(t(), node(), integer()) :: t()
  def nodedown(%__MODULE__{} = access, node, now) do
    access = %{access | dev_nodes: MapSet.delete(access.dev_nodes, node)}
    if state(access, node) == :connected, do: put(access, node, :allowed, now), else: access
  end

  @doc "The player cuts a node off."
  @spec disconnect(t(), node(), integer()) :: {:ok, t()} | {:error, :unknown}
  def disconnect(%__MODULE__{} = access, node, now) do
    case state(access, node) do
      nil -> {:error, :unknown}
      _ -> {:ok, put(access, node, :disconnected, now)}
    end
  end

  @doc "Whether calls from `node` are served (allowed or connected)."
  @spec permitted?(t(), node()) :: boolean()
  def permitted?(%__MODULE__{} = access, node), do: state(access, node) in [:allowed, :connected]

  @doc "The node's state, nil when unknown."
  @spec state(t(), node()) :: state() | nil
  def state(%__MODULE__{apps: apps}, node), do: get_in(apps, [node, :state])

  @doc "Nodes that may connect (to keep across restarts)."
  @spec allowed(t()) :: [node()]
  def allowed(%__MODULE__{apps: apps}),
    do: for({n, %{state: s}} <- apps, s in [:allowed, :connected], do: n) |> Enum.sort()

  @doc "Every known node with its state, connected first, then by name."
  @spec list(t()) :: [%{node: node(), state: state(), since: integer()}]
  def list(%__MODULE__{apps: apps}) do
    order = %{connected: 0, pending: 1, allowed: 2, disconnected: 3}

    apps
    |> Enum.map(fn {node, info} -> Map.put(info, :node, node) end)
    |> Enum.sort_by(&{order[&1.state], &1.node})
  end

  defp put(access, node, state, now), do: put_in(access.apps[node], %{state: state, since: now})

  # anyone on the phone can knock (no cookie needed to be refused): keep only the latest few
  defp trim(access) do
    pending = for {n, %{state: :pending, since: t}} <- access.apps, do: {t, n}

    if length(pending) > @max_pending do
      drop =
        pending
        |> Enum.sort()
        |> Enum.take(length(pending) - @max_pending)
        |> Enum.map(&elem(&1, 1))

      %{access | apps: Map.drop(access.apps, drop)}
    else
      access
    end
  end
end
