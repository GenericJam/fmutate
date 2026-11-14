defmodule FMutate.Library.HTTP do
  @moduledoc """
  HTTPS GETs for the library over OTP's `:httpc` and `:ssl` (both in the Mob release). Android has no
  CA bundle where `:public_key` looks, so on a device the trust store is read from the system's
  certificates (`/system/etc/security/cacerts`, one PEM per authority); on a host, the OS bundle.
  """

  @android_certs "/system/etc/security/cacerts"
  @timeout 30_000

  @doc """
  GET `url` into memory, with `extra` request headers (e.g. `[{"if-none-match", etag}]`): the body and the
  response headers (lower-case names), or `:not_modified` on a 304.
  """
  @spec get(String.t(), [{String.t(), String.t()}]) ::
          {:ok, binary, %{String.t() => String.t()}} | :not_modified | {:error, term}
  def get(url, extra \\ []) do
    req = headers() ++ for({k, v} <- extra, do: {to_charlist(k), to_charlist(v)})

    with :ok <- start() do
      case :httpc.request(:get, {to_charlist(url), req}, http_opts(url), body_format: :binary) do
        {:ok, {{_, 200, _}, resp, body}} -> {:ok, body, Map.new(resp, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)}
        {:ok, {{_, 304, _}, _, _}} -> :not_modified
        {:ok, {{_, status, _}, _, _}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  GET `url` into the file `dest`, calling `progress.(bytes_so_far, total_or_nil)` as it arrives.
  """
  @spec download(String.t(), Path.t(), (non_neg_integer, non_neg_integer | nil -> any)) :: :ok | {:error, term}
  def download(url, dest, progress) do
    opts = [sync: false, stream: :self, body_format: :binary]

    with :ok <- start(),
         {:ok, ref} <- :httpc.request(:get, {to_charlist(url), headers()}, http_opts(url), opts),
         {:ok, io} <- File.open(dest, [:write, :binary]) do
      try do
        receive_body(ref, io, 0, nil, progress)
      after
        File.close(io)
      end
    end
  end

  defp receive_body(ref, io, got, total, progress) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        total = content_length(headers)
        progress.(0, total)
        receive_body(ref, io, got, total, progress)

      {:http, {^ref, :stream, chunk}} ->
        :ok = IO.binwrite(io, chunk)
        got = got + byte_size(chunk)
        progress.(got, total)
        receive_body(ref, io, got, total, progress)

      {:http, {^ref, :stream_end, _headers}} ->
        :ok

      {:http, {^ref, {{_, status, _}, _, _}}} ->
        {:error, {:http, status}}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      @timeout ->
        :httpc.cancel_request(ref)
        {:error, :timeout}
    end
  end

  defp content_length(headers) do
    case List.keyfind(headers, ~c"content-length", 0) do
      {_, v} -> List.to_integer(v)
      nil -> nil
    end
  end

  # (a release without :inets or :ssl answers {:error, ...} here rather than taking the library down)
  defp start do
    case Application.ensure_all_started([:ssl, :inets]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:not_started, reason}}
    end
  end

  defp headers, do: [{~c"user-agent", ~c"FMutate (Android)"}]

  defp http_opts(url) do
    host = URI.parse(url).host |> to_charlist()

    [
      timeout: @timeout,
      connect_timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: cacerts(),
        server_name_indication: host,
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp cacerts do
    case :persistent_term.get({__MODULE__, :cacerts}, nil) do
      nil ->
        certs = load_cacerts()
        :persistent_term.put({__MODULE__, :cacerts}, certs)
        certs

      certs ->
        certs
    end
  end

  defp load_cacerts do
    if File.dir?(@android_certs) do
      for file <- File.ls!(@android_certs),
          {:ok, pem} = File.read(Path.join(@android_certs, file)),
          {:Certificate, der, _} <- :public_key.pem_decode(pem),
          do: der
    else
      :public_key.cacerts_get()
    end
  end
end
