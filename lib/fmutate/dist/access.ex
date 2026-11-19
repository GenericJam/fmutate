defmodule FMutate.Dist.Access do
  @moduledoc """
  Which sibling apps may drive this FMutate (protocol.md §5, HANDOFF §10): a pure state machine per node,
  kept by `FMutate.Dist`, which turns it into per-node distribution cookies.

      unknown ──knock──▶ pending ──allow──▶ allowed ◀──nodedown── connected
                            ▲                  │ └──────nodeup──────▶ │
                            └──────knock─── disconnected ◀─disconnect─┘ (also from allowed/pending)

    * **knock** — a sibling registered its node name through the content provider (`FMutate.Dist.Requests`):
      its still-binary name is listed as pending, waiting for the player's Allow. It becomes an atom only
      when the player allows it.
    * **allow** — the player tapped Allow: the validated pending name becomes a node atom and may connect
      (and reconnect, across restarts) until disconnected.
    * **nodeup / nodedown** — an allowed node's connection came up or went away.
    * **disconnect** — the player tapped Disconnect: the connection is cut and the node is refused again
      until it registers and is allowed anew.
    * **pair** — the player allowed the app on the Pair screen (`FMutate.Pairing`, protocol §1): the node is
      allowed straight away, with its own cookie from the pairing.
    * **forget** — a pairing was revoked (Disconnect, or the app unpaired itself): the node is dropped from the
      table; only pairing again lets it back in.

  A node the table doesn't know is refused (`nodeup/2` → `:refuse`), except with `dev: true` (a build
  deployed by mob_dev, whose default cookie is the developer's): nodes that got in with that cookie are
  development tools (`tools/rpc.exs`), listed apart and never offered to the player.
  """

  @max_pending 8

  defstruct apps: %{}, dev: false, dev_nodes: MapSet.new()

  @type state :: :pending | :allowed | :connected | :disconnected
  @type node_ref :: node() | String.t()
  @type t :: %__MODULE__{
          apps: %{optional(node_ref()) => %{state: state(), since: integer()}},
          dev: boolean(),
          dev_nodes: MapSet.t(node())
        }

  @doc "A table with `allowed` nodes (from a previous run) allowed."
  @spec new([node()], keyword()) :: t()
  def new(allowed \\ [], opts \\ []) do
    apps = Map.new(allowed, &{&1, %{state: :allowed, since: 0}})
    %__MODULE__{apps: apps, dev: Keyword.get(opts, :dev, false)}
  end

  @doc """
  A registered sibling asks to connect. Fresh names remain binaries; an existing node atom is reused without
  creating one. `:ignored` for allowed or connected nodes.
  """
  @spec knock(t(), node_ref(), integer()) :: {:pending | :ignored, t()}
  def knock(%__MODULE__{} = access, node, now) do
    key = key(access, node)

    case state(access, key) do
      s when s in [nil, :pending, :disconnected] ->
        {:pending, put(access, key, :pending, now) |> trim()}

      _ ->
        {:ignored, access}
    end
  end

  @doc """
  Allows a pending (or disconnected) node. A binary pending name is atomized here, after the player's tap.
  Returns the node atom used by distribution. Unknown nodes can't be allowed.
  """
  @spec allow(t(), node_ref(), integer()) :: {:ok, t(), node()} | {:error, :unknown}
  def allow(%__MODULE__{} = access, node, now) do
    key = key(access, node)

    case state(access, key) do
      nil ->
        {:error, :unknown}

      state when state in [:pending, :disconnected] ->
        atom = node_atom(key)
        apps = Map.delete(access.apps, key)
        {:ok, put(%{access | apps: apps}, atom, :allowed, now), atom}

      _ ->
        {:ok, access, node_atom(key)}
    end
  end

  @doc "A node the player paired (Pair screen): allowed, or kept connected if it already is."
  @spec pair(t(), node(), integer()) :: t()
  def pair(%__MODULE__{} = access, node, now) do
    access = %{access | apps: Map.delete(access.apps, Atom.to_string(node))}
    if state(access, node) == :connected, do: access, else: put(access, node, :allowed, now)
  end

  @doc "Drops a node whose pairing was revoked."
  @spec forget(t(), node()) :: t()
  def forget(%__MODULE__{} = access, node),
    do: %{access | apps: access.apps |> Map.delete(node) |> Map.delete(Atom.to_string(node))}

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

  @doc "The node reference's state, nil when unknown."
  @spec state(t(), node_ref()) :: state() | nil
  def state(%__MODULE__{apps: apps}, node), do: get_in(apps, [node, :state])

  @doc "Nodes that may connect (to keep across restarts)."
  @spec allowed(t()) :: [node()]
  def allowed(%__MODULE__{apps: apps}),
    do: for({n, %{state: s}} <- apps, s in [:allowed, :connected], do: n) |> Enum.sort()

  @doc "Every known node reference with its state, connected first, then by name."
  @spec list(t()) :: [%{node: node_ref(), state: state(), since: integer()}]
  def list(%__MODULE__{apps: apps}) do
    order = %{connected: 0, pending: 1, allowed: 2, disconnected: 3}

    apps
    |> Enum.map(fn {node, info} -> Map.put(info, :node, node) end)
    |> Enum.sort_by(&{order[&1.state], to_string(&1.node)})
  end

  defp put(access, node, state, now), do: put_in(access.apps[node], %{state: state, since: now})

  defp key(%__MODULE__{apps: apps}, node) when is_atom(node) do
    name = Atom.to_string(node)
    if Map.has_key?(apps, name), do: name, else: node
  end

  defp key(%__MODULE__{apps: apps}, name) when is_binary(name) do
    case existing_atom(name) do
      node when is_atom(node) and is_map_key(apps, node) -> node
      _ -> name
    end
  end

  defp node_atom(node) when is_atom(node), do: node
  defp node_atom(name) when is_binary(name), do: String.to_atom(name)

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  # any signed sibling can register any number of names: keep only the latest few binaries
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
