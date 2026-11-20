# A sibling app pairing with FMutate's Pair screen (protocol.md §7 "Pairing"), run from the computer with
# mob_pair's joining side, as Humdinger or Magpie would (development tool).
#
#   mise exec -- mix run --no-start tools/pair_probe.exs <adb serial> '<link from Copy link>'
#   mise exec -- mix run --no-start tools/pair_probe.exs <adb serial> <code> <pairing port>
#   mise exec -- mix run --no-start tools/pair_probe.exs --wifi '<link>'
#
# With an adb serial it reaches the phone through `adb forward`, so FMutate sees a sibling on its own phone
# (loopback): it is granted plain distribution to 127.0.0.1:9150, which is forwarded too. With --wifi it
# connects to the link's address directly, as another phone on the Wi-Fi would: FMutate grants TLS
# distribution to its Wi-Fi address and port 9250 (MobPair.Front), and the probe goes through
# MobPair.Tunnel. A typed code needs its pairing port (the probe does no mDNS); it is proven with SRP-6a.
#
# The player taps Allow on the phone. Then the probe connects with the granted cookie, calls
# `:fmutate_instance` (list_firmware), subscribes to status, and leaves the pairing in place (Disconnect it
# in I/O); `--unpair` as last argument makes it forget the pairing instead, as a sibling does.
alias MobPair.{Cert, Client, Code, Link, Transport}

Mix.Task.run("app.config")
{:ok, _} = Application.ensure_all_started(:mob_pair)

{args, unpair?} =
  case Enum.split(System.argv(), -1) do
    {rest, ["--unpair"]} -> {rest, true}
    _ -> {System.argv(), false}
  end

say = fn msg -> IO.puts("[#{Time.utc_now() |> Time.truncate(:millisecond)}] #{msg}") end

forward = fn serial, port ->
  {out, 0} = System.cmd("adb", ["-s", serial, "forward", "tcp:0", "tcp:#{port}"])
  out |> String.trim() |> String.to_integer()
end

{mode, target, auth} =
  case args do
    ["--wifi", link] ->
      {:ok, l} = Link.parse(link, services: ["fmutate"])
      {:wifi, %{service: "fmutate", host: l.host, port: l.port, inst: l.inst, fp: l.fp}, {:token, l.token}}

    [serial, link] ->
      {:ok, l} = Link.parse(link, services: ["fmutate"])
      port = forward.(serial, l.port)
      {{:adb, serial}, %{service: "fmutate", host: "127.0.0.1", port: port, inst: l.inst, fp: l.fp}, {:token, l.token}}

    [serial, code, pairing_port] ->
      {:ok, code} = Code.normalize(code)
      port = forward.(serial, String.to_integer(pairing_port))
      {{:adb, serial}, %{service: "fmutate", host: "127.0.0.1", port: port, inst: "a", fp: nil}, {:code, code}}

    _ ->
      raise "usage: see the top of tools/pair_probe.exs"
  end

{:ok, host} = :inet.gethostname()

identity = %{
  app_id: "com.genericjam.fmutate.pairprobe",
  app_name: "Pair probe",
  device_name: List.to_string(host),
  node: Transport.random_node_name("pairprobe"),
  cert: Cert.self_signed("Pair probe")
}

say.("pairing as #{identity.node} with #{target.host}:#{target.port} (#{elem(auth, 0)})")

notify = fn
  :authenticated -> say.("FMutate proved itself and took the #{elem(auth, 0)}")
  :pending -> say.("waiting for Allow on the phone")
end

record =
  case Client.pair(target, auth, identity, notify) do
    {:ok, record} ->
      say.("granted: #{record.node} at #{record.host}:#{record.dist_port} over #{record.dist_proto}")
      record

    {:error, reason} ->
      say.("refused: #{inspect(reason)}")
      System.halt(1)
  end

# through adb the loopback grant is reached on a forwarded port
record =
  case mode do
    {:adb, serial} -> %{record | dist_port: forward.(serial, record.dist_port)}
    :wifi -> record
  end

:ok = Transport.setup()

conn =
  case Transport.connect(record, self()) do
    {:ok, conn} ->
      say.("connected to #{conn.node}#{if conn.tunnel, do: " through TLS (tunnel → MobPair.Front)", else: ""}")
      conn

    {:error, reason} ->
      say.("can't connect: #{inspect(reason)}")
      System.halt(1)
  end

fmutate = {:fmutate_instance, conn.node}
say.("list_firmware: #{inspect(GenServer.call(fmutate, {:fmutate, 1, "a", {:list_firmware}}))}")
:ok = GenServer.call(fmutate, {:fmutate, 1, "a", {:subscribe, self(), [:status]}})

receive do
  {:status, status} -> say.("event {:status, #{inspect(status)}}")
after
  5_000 -> say.("no status event in 5 s")
end

if unpair? do
  say.("unpair: #{inspect(GenServer.call(fmutate, {:fmutate, 1, "a", {:unpair, identity.node}}))}")
end
