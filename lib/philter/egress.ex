defmodule Philter.Egress do
  @moduledoc """
  Egress filtering to defend against Server-Side Request Forgery (SSRF).

  This module resolves a hostname to IP addresses and validates that none of
  them fall inside private, loopback, link-local or otherwise internal network
  ranges before a caller is allowed to connect. It is transport-agnostic: it
  has no dependency on Finch/Mint or on `Philter.Config`. Policy is supplied
  entirely through `resolve_and_validate/2` options.

  ## Why resolve here?

  Validating the hostname string is not enough: an attacker can point a public
  DNS name at an internal IP (a "DNS rebinding" style attack). We therefore
  resolve the name ourselves and hand the caller the exact IPs to connect to,
  so the transport connects to an address we have already validated rather than
  re-resolving the name.

  ## Blocked ranges

  IPv4:

    * `0.0.0.0/8` (this-network)
    * `10.0.0.0/8` (RFC1918)
    * `100.64.0.0/10` (CGNAT)
    * `127.0.0.0/8` (loopback)
    * `169.254.0.0/16` (link-local, cloud metadata)
    * `172.16.0.0/12` (RFC1918)
    * `192.168.0.0/16` (RFC1918)
    * `240.0.0.0/4` (reserved, includes the broadcast address)

  IPv6:

    * `::` (unspecified)
    * `::1` (loopback)
    * `fc00::/7` (unique local addresses)
    * `fe80::/10` (link-local)

  IPv4-mapped (`::ffff:a.b.c.d`) and NAT64 (`64:ff9b::a.b.c.d`) IPv6 forms are
  unwrapped to their embedded IPv4 address and re-checked against the IPv4
  ranges, so a translated form of a blocked address cannot slip through.
  """

  import Bitwise

  @type reason :: :no_addresses | :dns_timeout | {:blocked, :inet.ip_address()}

  @default_dns_timeout 5_000

  # {network_tuple, prefix_length} pairs. The prefix length drives a bitmask so
  # ranges like 172.16.0.0/12 are matched by mask, never by octet equality.
  @ipv4_blocks [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{240, 0, 0, 0}, 4}
  ]

  @doc """
  Resolves `host` and validates the resulting addresses against the block set.

  Returns `{:ok, addrs}` with every validated address in resolution order (the
  transport should try them in order; they are deliberately not reduced to a
  single address). Returns `{:error, reason}` otherwise.

  ## Options

    * `:block_private_networks` - block internal ranges. Default `true`.
    * `:allowed_hosts` - list of host strings that bypass the block check
      entirely (the escape hatch). Comparison is case-insensitive and ignores a
      single trailing dot. Default `[]`.
    * `:resolver` - a 2-arity function `(charlist_host, family)` returning
      `{:ok, [ip]} | {:error, term}`, matching `:inet.getaddrs/2`. Default
      `&:inet.getaddrs/2`. Note the host is passed as a charlist.
    * `:dns_timeout` - milliseconds to bound resolution. Default `5_000`.

  ## Error reasons

    * `:no_addresses` - both address families failed or returned nothing.
    * `:dns_timeout` - resolution exceeded `:dns_timeout`.
    * `{:blocked, ip}` - `ip` fell inside a blocked range. This is intended for
      server logs only; never expose it to end users.

  ## Escape hatch

  If the normalised `host` is a member of the normalised `:allowed_hosts`, the
  block check is skipped but the name is still resolved so the caller receives
  IPs to connect to, even if those IPs are private.
  """
  @spec resolve_and_validate(String.t(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, reason()}
  def resolve_and_validate(host, opts \\ []) when is_binary(host) do
    block? = Keyword.get(opts, :block_private_networks, true)
    allowed_hosts = Keyword.get(opts, :allowed_hosts, [])
    resolver = Keyword.get(opts, :resolver, &:inet.getaddrs/2)
    timeout = Keyword.get(opts, :dns_timeout, @default_dns_timeout)

    allow_listed? = allow_listed?(host, allowed_hosts)

    with {:ok, addrs} <- resolve(host, resolver, timeout) do
      cond do
        allow_listed? -> {:ok, addrs}
        block? -> check_blocked(addrs)
        true -> {:ok, addrs}
      end
    end
  end

  @doc """
  Returns `true` if `ip` falls inside a blocked (internal) range.

  IPv4-mapped and NAT64 IPv6 addresses are unwrapped to their embedded IPv4
  address before checking, so translated forms of blocked addresses are caught.
  """
  @spec blocked?(:inet.ip_address()) :: boolean()
  def blocked?({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: ipv4_blocked?(embedded_v4(g, h))
  def blocked?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}), do: ipv4_blocked?(embedded_v4(g, h))
  def blocked?({0, 0, 0, 0, 0, 0, g, h}), do: ipv4_blocked?(embedded_v4(g, h))
  def blocked?({_, _, _, _, _, _, _, _} = v6), do: ipv6_blocked?(v6)
  def blocked?({_, _, _, _} = v4), do: ipv4_blocked?(v4)

  # Resolution, bounded by a Task so a tarpit nameserver cannot hang the caller.

  defp resolve(host, resolver, timeout) do
    task = Task.async(fn -> resolve_all(host, resolver) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, addrs}} -> {:ok, addrs}
      {:ok, {:error, reason}} -> {:error, reason}
      {:exit, _reason} -> {:error, :no_addresses}
      nil -> {:error, :dns_timeout}
    end
  end

  defp resolve_all(host, resolver) do
    charlist = String.to_charlist(host)

    addrs =
      [:inet, :inet6]
      |> Enum.flat_map(fn family -> safe_getaddrs(resolver, charlist, family) end)

    case addrs do
      [] -> {:error, :no_addresses}
      list -> {:ok, list}
    end
  end

  defp safe_getaddrs(resolver, host, family) do
    case resolver.(host, family) do
      {:ok, addrs} -> addrs
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  catch
    _kind, _value -> []
  end

  defp check_blocked(addrs) do
    case Enum.find(addrs, &blocked?/1) do
      nil -> {:ok, addrs}
      ip -> {:error, {:blocked, ip}}
    end
  end

  # Allowlist: downcase and strip a single trailing dot before comparing.

  defp allow_listed?(host, allowed_hosts) do
    normalised = normalise_host(host)
    Enum.any?(allowed_hosts, fn allowed -> normalise_host(allowed) == normalised end)
  end

  defp normalise_host(host) do
    host |> String.downcase() |> String.replace_suffix(".", "")
  end

  # IPv4 checks via 32-bit integer masking.

  defp ipv4_blocked?({_, _, _, _} = addr) do
    ip = v4_to_int(addr)
    Enum.any?(@ipv4_blocks, fn {net, prefix} -> in_v4_block?(ip, net, prefix) end)
  end

  defp in_v4_block?(ip, net, prefix) do
    mask = v4_mask(prefix)
    (ip &&& mask) == (v4_to_int(net) &&& mask)
  end

  defp v4_to_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp v4_mask(prefix), do: 0xFFFFFFFF <<< (32 - prefix) &&& 0xFFFFFFFF

  defp embedded_v4(g, h) do
    {g >>> 8 &&& 0xFF, g &&& 0xFF, h >>> 8 &&& 0xFF, h &&& 0xFF}
  end

  # Pure IPv6 checks via first-hextet masks.

  defp ipv6_blocked?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp ipv6_blocked?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp ipv6_blocked?({first, _, _, _, _, _, _, _}) do
    unique_local?(first) or link_local?(first)
  end

  defp unique_local?(first), do: (first &&& 0xFE00) == 0xFC00

  defp link_local?(first), do: (first &&& 0xFFC0) == 0xFE80
end
