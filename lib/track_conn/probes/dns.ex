defmodule TrackConn.Probes.Dns do
  @moduledoc """
  DNS resolution probe.

  Measures how long it takes to turn a hostname into an IP address. This is a
  distinct failure mode from raw connectivity: you can have a perfectly healthy
  link to the internet while name resolution is broken or slow (a misconfigured
  or overloaded DNS server). Separating the two is what lets us tell a user
  "the internet is fine, but your DNS is the problem — try 1.1.1.1".

  Uses Erlang's built-in resolver (`:inet.gethostbyname`) so there is no
  external dependency.
  """

  @behaviour TrackConn.Probe

  @default_timeout 3000

  def run(hostname, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    host = to_charlist(hostname)

    task = Task.async(fn -> timed_resolve(host) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} ->
        result

      _ ->
        %{
          ok?: false,
          ms: nil,
          address: nil,
          raw: "timed out after #{timeout}ms",
          error: "timeout"
        }
    end
  end

  defp timed_resolve(host) do
    start = System.monotonic_time(:microsecond)

    case :inet.gethostbyname(host) do
      {:ok, {:hostent, _name, _aliases, _type, _len, [addr | _]}} ->
        ms = (System.monotonic_time(:microsecond) - start) / 1000
        ip = addr |> :inet.ntoa() |> to_string()
        %{ok?: true, ms: Float.round(ms, 1), address: ip, raw: "resolved to #{ip}", error: nil}

      {:error, reason} ->
        %{
          ok?: false,
          ms: nil,
          address: nil,
          raw: "error: #{inspect(reason)}",
          error: to_string(reason)
        }
    end
  rescue
    e -> %{ok?: false, ms: nil, address: nil, raw: Exception.message(e), error: "exception"}
  end
end
