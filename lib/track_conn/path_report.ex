defmodule TrackConn.PathReport do
  @moduledoc """
  Interprets a raw `mtr` result (from `TrackConn.Probes.Mtr`) into something a
  human can act on: per-hop zone labels, *honest* loss interpretation, where
  latency is introduced, and a plain-English verdict naming the culprit hop.

  ## The one rule that matters: phantom loss

  Intermediate routers often rate-limit or ignore the ICMP "TTL expired"
  replies that traceroute relies on. That shows up as high loss at *that* hop
  while later hops show none — which is physically impossible if the loss were
  real (the packet that reached hop N+1 must have passed hop N). So:

  > **Loss is only real if it persists to the destination.**

  The true end-to-end loss is the loss at the final hop. A hop reporting more
  loss than the destination is exhibiting *phantom* loss and is flagged benign,
  so we never blame a hop that's actually fine.
  """

  # end-to-end loss above which we consider the path genuinely lossy
  @loss_threshold 2.0

  @doc "Analyze a `Probes.Mtr.run/2` result into a report for the UI."
  def analyze(%{ok?: false} = r) do
    %{
      ok?: false,
      error: r.error,
      raw: r.raw,
      target: r.target,
      hops: [],
      status: :unknown,
      headline: error_headline(r.error),
      detail: r.raw
    }
  end

  def analyze(%{ok?: true, hops: hops, target: target} = r) do
    end_loss = end_to_end_loss(hops)
    loss_onset = real_loss_onset(hops, end_loss)
    {jump_hop, jump_ms} = biggest_latency_jump(hops)
    total_ms = total_latency(hops)
    isp_domain = first_isp_domain(hops)

    enriched =
      hops
      |> Enum.map(&enrich(&1, hops, isp_domain, end_loss, loss_onset, jump_hop))
      |> mark_isp_edge()

    status = status_for(end_loss)

    %{
      ok?: true,
      target: target,
      raw: r.raw,
      hops: enriched,
      status: status,
      end_loss: end_loss,
      total_ms: total_ms,
      headline: headline(status, loss_onset, target, end_loss),
      detail: detail(status, loss_onset, jump_hop, jump_ms, total_ms, target)
    }
  end

  # --- per-hop enrichment -------------------------------------------------

  defp enrich(hop, hops, isp_domain, end_loss, loss_onset, jump_hop) do
    responded = hop.host != "???" and hop.host != nil
    phantom = responded and hop.loss_pct > end_loss + @loss_threshold

    Map.merge(hop, %{
      responded?: responded,
      zone: zone(hop, hops, isp_domain),
      phantom_loss?: not responded or phantom,
      loss_onset?: hop.count == loss_onset,
      latency_jump?: hop.count == jump_hop,
      note: note(responded, phantom, hop.count == loss_onset)
    })
  end

  defp note(false, _, _), do: "no response (normal — this router hides from traceroute)"
  defp note(true, true, _), do: "phantom loss — not a real problem (later hops are clean)"
  defp note(true, false, true), do: "packet loss begins here and continues to the destination"
  defp note(true, false, _), do: nil

  # --- zone classification ------------------------------------------------

  # Zones are inferred from the reverse-DNS *registrable domain*. The first
  # public hop with a hostname defines "your ISP's domain"; hops sharing it are
  # your ISP, and public hops on a *different* domain (or bare IPs) near the end
  # are transit/CDN — we don't claim those are your provider.
  defp zone(hop, hops, isp_domain) do
    cond do
      not responded?(hop.host) -> :unknown
      private?(hop.host) -> :local
      hop.count == max_count(hops) -> :destination
      isp_domain && registrable_domain(hop.host) == isp_domain -> :isp
      true -> :transit
    end
  end

  # The earliest hop classified as :isp is the ISP edge (entry to their network).
  defp mark_isp_edge(hops) do
    case Enum.find_index(hops, &(&1.zone == :isp)) do
      nil -> hops
      idx -> List.update_at(hops, idx, &Map.put(&1, :zone, :isp_edge))
    end
  end

  # Registrable domain of the first responding, public, *named* hop.
  defp first_isp_domain(hops) do
    Enum.find_value(hops, fn h ->
      if responded?(h.host) and not private?(h.host), do: registrable_domain(h.host)
    end)
  end

  # "a.b.edge.example-isp.net" -> "example-isp.net"; bare IPs and nameless hops -> nil.
  # Simple last-two-labels heuristic (good for the common .com/.net ISP domains).
  defp registrable_domain(host) do
    cond do
      is_nil(host) or not String.contains?(host, ".") -> nil
      ip?(host) -> nil
      true -> host |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
    end
  end

  defp ip?(host), do: match?({:ok, _}, host |> to_charlist() |> :inet.parse_address())

  defp responded?(host), do: host != "???" and host != nil

  defp private?(host) do
    String.ends_with?(host || "", [".mshome.net", ".local"]) or
      private_ip?(host)
  end

  defp private_ip?(host) do
    case host |> to_string() |> to_charlist() |> :inet.parse_address() do
      {:ok, {10, _, _, _}} -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {169, 254, _, _}} -> true
      _ -> false
    end
  end

  defp max_count([]), do: 0
  defp max_count(hops), do: hops |> Enum.map(& &1.count) |> Enum.max()

  # --- loss / latency math ------------------------------------------------

  # End-to-end loss = loss at the last hop that actually responded.
  defp end_to_end_loss(hops) do
    hops
    |> Enum.filter(&responded?(&1.host))
    |> List.last()
    |> case do
      nil -> 100.0
      hop -> hop.loss_pct
    end
  end

  # Earliest hop where loss is significant AND stays significant through the
  # end — i.e. genuinely persistent loss, not a phantom blip.
  defp real_loss_onset(_hops, end_loss) when end_loss <= @loss_threshold, do: nil

  defp real_loss_onset(hops, end_loss) do
    floor_loss = end_loss * 0.5

    hops
    |> Enum.filter(&responded?(&1.host))
    |> Enum.find(fn hop ->
      downstream = Enum.filter(hops, &(&1.count >= hop.count and responded?(&1.host)))
      hop.loss_pct >= floor_loss and Enum.all?(downstream, &(&1.loss_pct >= floor_loss))
    end)
    |> case do
      nil -> nil
      hop -> hop.count
    end
  end

  # Biggest positive jump in average latency between consecutive responding hops.
  defp biggest_latency_jump(hops) do
    responding = Enum.filter(hops, &(responded?(&1.host) and is_number(&1.avg) and &1.avg > 0))

    responding
    |> Enum.zip(tl(responding) ++ [nil])
    |> Enum.reduce({nil, 0.0}, fn
      {_prev, nil}, acc ->
        acc

      {prev, curr}, {_bh, bj} = acc ->
        delta = curr.avg - prev.avg
        if delta > bj, do: {curr.count, delta}, else: acc
    end)
  end

  defp total_latency(hops) do
    hops
    |> Enum.filter(&(responded?(&1.host) and is_number(&1.avg)))
    |> List.last()
    |> case do
      nil -> nil
      hop -> hop.avg
    end
  end

  # --- verdict copy -------------------------------------------------------

  defp status_for(end_loss) when end_loss >= 100, do: :down
  defp status_for(end_loss) when end_loss > @loss_threshold, do: :degraded
  defp status_for(_), do: :healthy

  defp headline(:healthy, _onset, target, _loss),
    do: "Clean path to #{target} — no real packet loss along the route"

  defp headline(:degraded, onset, target, loss) when not is_nil(onset),
    do: "#{fmt(loss)}% packet loss to #{target} starts at hop #{onset}"

  defp headline(:degraded, _onset, target, loss),
    do: "#{fmt(loss)}% packet loss reaching #{target}"

  defp headline(:down, _onset, target, _loss),
    do: "The path to #{target} is broken — packets aren't getting through"

  defp detail(:healthy, _onset, jump_hop, jump_ms, total_ms, target) do
    base = "Every hop to #{target} delivers your packets."

    cond do
      total_ms && jump_hop && jump_ms > 5 ->
        base <>
          " Total latency is #{fmt(total_ms)}ms; the largest single increase (#{fmt(jump_ms)}ms) is at hop #{jump_hop} — usually just the physical distance to your ISP's network, not a fault."

      total_ms ->
        base <> " Total round-trip latency is #{fmt(total_ms)}ms."

      true ->
        base
    end
  end

  defp detail(status, onset, _jump_hop, _jump_ms, _total_ms, target)
       when status in [:degraded, :down] do
    where =
      if onset,
        do:
          "Loss first appears at hop #{onset} and persists all the way to #{target}, so that hop (and everything past it) is where your connection is actually breaking.",
        else: "Loss is reaching #{target} but no single hop stands out as the origin."

    "#{where} Hops *before* it are clean — note that any single hop showing loss while later hops don't is just a router ignoring traceroute, not a real problem."
  end

  defp error_headline("mtr is not installed"), do: "Deep diagnostic needs mtr"
  defp error_headline(_), do: "Deep diagnostic couldn't run"

  defp fmt(n) when is_float(n), do: Float.round(n, 1)
  defp fmt(n), do: n
end
