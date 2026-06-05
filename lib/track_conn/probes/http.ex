defmodule TrackConn.Probes.Http do
  @moduledoc """
  HTTP probe — the "real world experience" measurement.

  Pings tell you packets get there; this tells you whether actually *using* the
  internet works and how snappy it feels. We fetch a small, well-known endpoint
  and measure total request time and bytes received. A high time here while the
  ping segments are healthy points at congestion, bandwidth limits, or a
  specific destination rather than your local network.

  Uses OTP's built-in `:httpc` (no external HTTP dependency). TLS verification
  is disabled on purpose: we are measuring reachability/latency, not
  establishing a secure data channel, and a connectivity tool must not fail
  just because the local CA bundle is missing.
  """

  @behaviour TrackConn.Probe

  @default_timeout 8000

  def run(url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    url_cl = to_charlist(url)
    start = System.monotonic_time(:microsecond)

    request = {url_cl, [{~c"user-agent", ~c"track_conn/0.1 connectivity-probe"}]}

    http_opts = [
      timeout: timeout,
      connect_timeout: timeout,
      ssl: [verify: :verify_none]
    ]

    case :httpc.request(:get, request, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _reason}, _headers, body}} ->
        ms = (System.monotonic_time(:microsecond) - start) / 1000
        bytes = byte_size(body)

        %{
          ok?: status >= 200 and status < 400,
          ms: Float.round(ms, 1),
          status: status,
          bytes: bytes,
          raw: "HTTP #{status}, #{bytes} bytes in #{Float.round(ms, 1)}ms",
          error: nil
        }

      {:error, reason} ->
        %{
          ok?: false,
          ms: nil,
          status: nil,
          bytes: 0,
          raw: "error: #{inspect(reason)}",
          error: format_error(reason)
        }
    end
  rescue
    e ->
      %{ok?: false, ms: nil, status: nil, bytes: 0, raw: Exception.message(e), error: "exception"}
  end

  defp format_error({:failed_connect, _}), do: "connection failed"
  defp format_error(reason), do: inspect(reason)
end
