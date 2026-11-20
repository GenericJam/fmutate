defmodule FMutate.Test.FixtureServer do
  @moduledoc false
  # A local HTTP server for tests that must not touch the network: each path answers with a fixed response
  # `{status, headers, body}` or a function of the request's headers (lower-case names) returning one; others
  # 404. Every request is recorded (path and headers). One request per connection.

  def start(routes \\ %{}) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :http_bin,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    {:ok, agent} = Agent.start(fn -> %{routes: routes, requests: []} end)
    pid = spawn(fn -> accept(listen, agent) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    %{url: "http://127.0.0.1:#{port}/", agent: agent, pid: pid, listen: listen}
  end

  @doc "Stop answering: connections are refused from now on (offline)."
  def stop(server) do
    Process.exit(server.pid, :kill)
    :gen_tcp.close(server.listen)
  end

  def route(server, path, response),
    do: Agent.update(server.agent, &put_in(&1, [:routes, path], response))

  def requests(server), do: server.agent |> Agent.get(& &1.requests) |> Enum.reverse()

  defp accept(listen, agent) do
    {:ok, sock} = :gen_tcp.accept(listen)
    serve(sock, agent)
    accept(listen, agent)
  end

  defp serve(sock, agent) do
    with {:ok, {:http_request, _method, {:abs_path, path}, _}} <- :gen_tcp.recv(sock, 0, 5_000),
         {:ok, headers} <- headers(sock, %{}) do
      Agent.update(agent, &%{&1 | requests: [{path, headers} | &1.requests]})

      {status, extra, body} =
        case Agent.get(agent, & &1.routes[path]) do
          nil -> {404, [], "not found"}
          fun when is_function(fun, 1) -> fun.(headers)
          response -> response
        end

      head =
        Enum.map_join(
          [{"content-length", byte_size(body)}, {"connection", "close"} | extra],
          fn {k, v} ->
            "#{k}: #{v}\r\n"
          end
        )

      :gen_tcp.send(sock, ["HTTP/1.1 #{status} X\r\n", head, "\r\n", body])
    end

    :gen_tcp.close(sock)
  end

  defp headers(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(sock, Map.put(acc, String.downcase(to_string(name)), value))

      {:ok, :http_eoh} ->
        {:ok, acc}

      other ->
        other
    end
  end
end
