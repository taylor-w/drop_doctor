defmodule DropDoctorWeb.ReportLiveSSETest do
  @moduledoc """
  End-to-end smoke test of the live report stream over a *real* HTTP connection.

  The unit-level streaming logic is covered deterministically in
  `DropDoctorWeb.ReportFeedTest`; this proves the transport the engine sits
  behind actually works: the `:sse` pipeline serves `text/event-stream` (rather
  than 406-ing an EventSource's `Accept`), Bandit's chunked writes flush, and a
  freshly-connected client gets a real report snapshot.
  """
  # async: false → shared SQL sandbox, so the Bandit-spawned request process can
  # read the test's data.
  use DropDoctorWeb.ConnCase, async: false

  alias DropDoctor.Test.FakeProbes

  setup do
    # The report endpoint reads the live verdict from a monitor under the default
    # name, exactly like the dashboard and the printable report.
    start_supervised!(
      {DropDoctor.Monitor,
       name: DropDoctor.Monitor,
       persist: false,
       interval: 10_000,
       sweep_opts: [probes: FakeProbes.healthy()]}
    )

    # Serve the real endpoint on its configured test port (nothing else binds it:
    # the app's endpoint runs with `server: false` during tests).
    port = Application.get_env(:drop_doctor, DropDoctorWeb.Endpoint)[:http][:port]

    # The SSE handler blocks in its receive loop (server→client only), so a low
    # `shutdown_timeout` keeps the still-open stream from stalling suite teardown.
    start_supervised!({
      Bandit,
      plug: DropDoctorWeb.Endpoint,
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: port,
      thousand_island_options: [shutdown_timeout: 250]
    })

    {:ok, port: port}
  end

  test "GET /report/live streams an SSE snapshot of the report", %{port: port} do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 2_000)

    on_exit(fn -> :gen_tcp.close(sock) end)

    :ok =
      :gen_tcp.send(
        sock,
        "GET /report/live HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n"
      )

    # Read until a full SSE frame lands. Headers terminate with "\r\n\r\n", so a
    # bare "\n\n" only appears at the end of the `data:` event — i.e. once the
    # whole JSON payload has arrived.
    buffer = read_until(sock, "\n\n", 3_000)

    lower = String.downcase(buffer)
    assert lower =~ "http/1.1 200"
    assert lower =~ "content-type: text/event-stream"
    # No content negotiation tripped the EventSource Accept into a 406.
    refute lower =~ "406"

    # The snapshot carries the report's real dynamic sections, keyed by DOM id.
    assert buffer =~ "data:"
    assert buffer =~ "dd-verdict"
    assert buffer =~ "dd-stability"
  end

  # Accumulate from the socket until `needle` appears or the deadline passes.
  defp read_until(sock, needle, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_read_until(sock, needle, deadline, "")
  end

  defp do_read_until(sock, needle, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      acc =~ needle ->
        acc

      remaining <= 0 ->
        flunk("timed out waiting for #{inspect(needle)}; got:\n#{acc}")

      true ->
        case :gen_tcp.recv(sock, 0, min(remaining, 500)) do
          {:ok, chunk} -> do_read_until(sock, needle, deadline, acc <> chunk)
          {:error, :timeout} -> do_read_until(sock, needle, deadline, acc)
          {:error, reason} -> flunk("socket error #{inspect(reason)}; got so far:\n#{acc}")
        end
    end
  end
end
