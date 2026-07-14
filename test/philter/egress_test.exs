defmodule Philter.EgressTest do
  use ExUnit.Case, async: true

  alias Philter.Egress

  describe "blocked?/1 IPv4 boundaries" do
    # Each row: {ip_tuple, expected_blocked?, description}. Boundaries are the
    # interesting part: the first/last address inside a range and the addresses
    # immediately outside it.
    @ipv4_cases [
      # 172.16.0.0/12 (172.16.0.0 - 172.31.255.255)
      {{172, 15, 255, 255}, false, "just below 172.16.0.0/12"},
      {{172, 16, 0, 0}, true, "first of 172.16.0.0/12"},
      {{172, 31, 255, 255}, true, "last of 172.16.0.0/12"},
      {{172, 32, 0, 0}, false, "just above 172.16.0.0/12"},

      # 100.64.0.0/10 CGNAT (100.64.0.0 - 100.127.255.255)
      {{100, 63, 255, 255}, false, "just below CGNAT"},
      {{100, 64, 0, 0}, true, "first of CGNAT"},
      {{100, 127, 255, 255}, true, "last of CGNAT"},
      {{100, 128, 0, 0}, false, "just above CGNAT"},

      # 10.0.0.0/8
      {{9, 255, 255, 255}, false, "just below 10.0.0.0/8"},
      {{10, 0, 0, 0}, true, "first of 10.0.0.0/8"},
      {{10, 255, 255, 255}, true, "last of 10.0.0.0/8"},
      {{11, 0, 0, 0}, false, "just above 10.0.0.0/8"},

      # 127.0.0.0/8 loopback
      {{126, 255, 255, 255}, false, "just below loopback"},
      {{127, 0, 0, 1}, true, "loopback"},
      {{128, 0, 0, 0}, false, "just above loopback"},

      # 169.254.0.0/16 link-local / cloud metadata
      {{169, 253, 255, 255}, false, "just below link-local"},
      {{169, 254, 169, 254}, true, "cloud metadata address"},
      {{169, 255, 0, 0}, false, "just above link-local"},

      # 240.0.0.0/4 reserved (includes broadcast)
      {{239, 255, 255, 255}, false, "just below reserved"},
      {{240, 0, 0, 0}, true, "first of reserved"},
      {{255, 255, 255, 255}, true, "broadcast"},

      # this-network and public negatives
      {{0, 0, 0, 0}, true, "0.0.0.0 this-network"},
      {{1, 1, 1, 1}, false, "public 1.1.1.1"},
      {{8, 8, 8, 8}, false, "public 8.8.8.8"}
    ]

    for {ip, expected, description} <- @ipv4_cases do
      test "#{description}: #{inspect(ip)} blocked? == #{expected}" do
        assert Egress.blocked?(unquote(Macro.escape(ip))) == unquote(expected)
      end
    end
  end

  describe "blocked?/1 IPv6 boundaries" do
    @ipv6_cases [
      {{0, 0, 0, 0, 0, 0, 0, 0}, true, ":: unspecified"},
      {{0, 0, 0, 0, 0, 0, 0, 1}, true, "::1 loopback"},
      {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, true, "fc00:: first of ULA"},
      {{0xFDFF, 0xFFFF, 0, 0, 0, 0, 0, 0}, true, "fdff:ffff:: last of ULA"},
      {{0xFBFF, 0xFFFF, 0, 0, 0, 0, 0, 0}, false, "fbff:: just below ULA"},
      {{0xFE00, 0, 0, 0, 0, 0, 0, 0}, false, "fe00:: not in fe80::/10"},
      {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, true, "fe80:: first of link-local"},
      {{0xFEBF, 0xFFFF, 0, 0, 0, 0, 0, 0}, true, "febf:ffff:: last of link-local"},
      {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, false, "fec0:: just above link-local"},
      {{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}, false, "public Cloudflare v6"}
    ]

    for {ip, expected, description} <- @ipv6_cases do
      test "#{description}: blocked? == #{expected}" do
        assert Egress.blocked?(unquote(Macro.escape(ip))) == unquote(expected)
      end
    end
  end

  describe "blocked?/1 unwraps embedded IPv4" do
    test "IPv4-mapped ::ffff:169.254.169.254 is blocked" do
      # ::ffff:a9fe:a9fe
      assert Egress.blocked?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
    end

    test "IPv4-mapped ::ffff:8.8.8.8 is allowed" do
      # ::ffff:0808:0808
      refute Egress.blocked?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end

    test "NAT64 64:ff9b::169.254.169.254 is blocked" do
      assert Egress.blocked?({0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE})
    end

    test "NAT64 64:ff9b::8.8.8.8 is allowed" do
      refute Egress.blocked?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end
  end

  describe "blocked?/1 unwraps IPv4-compatible IPv6 (::a.b.c.d)" do
    # The deprecated ::a.b.c.d form embeds an IPv4 address in the low 32 bits
    # with all-zero high bits. It must be unwrapped and re-checked, or an
    # internal target reachable this way would slip through as "public".
    # Each row: {ip_tuple, expected_blocked?, description}.
    @compat_cases [
      {{0, 0, 0, 0, 0, 0, 0x7F00, 0x0001}, true, "::127.0.0.1 loopback"},
      {{0, 0, 0, 0, 0, 0, 0xA9FE, 0xA9FE}, true, "::169.254.169.254 IMDS via compat form"},
      {{0, 0, 0, 0, 0, 0, 0x0A00, 0x0001}, true, "::10.0.0.1 RFC1918"},
      # Public embedded address must still be allowed (proves we didn't over-block).
      {{0, 0, 0, 0, 0, 0, 0x0808, 0x0808}, false, "::8.8.8.8 public"},
      # Regression guard: :: and ::1 now route through 0.0.0.0/8 via this clause;
      # confirm they did not regress to allowed.
      {{0, 0, 0, 0, 0, 0, 0, 0}, true, ":: unspecified stays blocked"},
      {{0, 0, 0, 0, 0, 0, 0, 1}, true, "::1 loopback stays blocked"}
    ]

    for {ip, expected, description} <- @compat_cases do
      test "#{description}: blocked? == #{expected}" do
        assert Egress.blocked?(unquote(Macro.escape(ip))) == unquote(expected)
      end
    end
  end

  describe "blocked?/1 unwraps 6to4 (2002::/16)" do
    # 6to4 embeds the IPv4 address in the second and third hextets, so
    # 2002:AABB:CCDD:: carries AA.BB.CC.DD. An internal target tunnelled this
    # way must be unwrapped and re-checked. Each row: {ip, expected, description}.
    @sixtofour_cases [
      {{0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 0}, true, "2002::169.254.169.254 IMDS"},
      {{0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 0}, true, "2002::10.0.0.1 RFC1918"},
      {{0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0}, true, "2002::127.0.0.1 loopback"},
      # Public embedded address must still be allowed (proves we didn't over-block).
      {{0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 0}, false, "2002::8.8.8.8 public"}
    ]

    for {ip, expected, description} <- @sixtofour_cases do
      test "#{description}: blocked? == #{expected}" do
        assert Egress.blocked?(unquote(Macro.escape(ip))) == unquote(expected)
      end
    end
  end

  describe "blocked?/1 unwraps Teredo (2001:0000::/32)" do
    # Teredo embeds the client IPv4 in the last two hextets, bit-inverted (each
    # hextet XORed with 0xFFFF). Only 2001:0000::/32 is Teredo; other 2001::
    # allocations are ordinary public space. Each row: {ip, expected, description}.
    @teredo_cases [
      # 169.254.169.254 -> a9fe a9fe -> inverted 5601 5601
      {{0x2001, 0x0000, 0, 0, 0, 0, 0x5601, 0x5601}, true, "Teredo IMDS 169.254.169.254"},
      # 10.0.0.1 -> 0a00 0001 -> inverted f5ff fffe
      {{0x2001, 0x0000, 0, 0, 0, 0, 0xF5FF, 0xFFFE}, true, "Teredo 10.0.0.1 RFC1918"},
      # 8.8.8.8 -> 0808 0808 -> inverted f7f7 f7f7 (public, must stay allowed)
      {{0x2001, 0x0000, 0, 0, 0, 0, 0xF7F7, 0xF7F7}, false, "Teredo 8.8.8.8 public"},
      # A public 2001:: allocation must not be mistaken for Teredo.
      {{0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}, false, "2001:4860:: public Google v6"}
    ]

    for {ip, expected, description} <- @teredo_cases do
      test "#{description}: blocked? == #{expected}" do
        assert Egress.blocked?(unquote(Macro.escape(ip))) == unquote(expected)
      end
    end
  end

  describe "resolve_and_validate/2 with an injected resolver" do
    defp resolver_returning(family_map) do
      fn _host, family -> Map.get(family_map, family, {:error, :nxdomain}) end
    end

    test "single public answer returns {:ok, addrs}" do
      resolver = resolver_returning(%{inet: {:ok, [{93, 184, 216, 34}]}})

      assert {:ok, [{93, 184, 216, 34}]} =
               Egress.resolve_and_validate("example.com", resolver: resolver)
    end

    test "single private answer with blocking on is rejected" do
      resolver = resolver_returning(%{inet: {:ok, [{169, 254, 169, 254}]}})

      assert {:error, {:blocked, {169, 254, 169, 254}}} =
               Egress.resolve_and_validate("metadata.example", resolver: resolver)
    end

    test "any internal address in a multi-answer set rejects the whole set" do
      resolver =
        resolver_returning(%{inet: {:ok, [{93, 184, 216, 34}, {169, 254, 169, 254}]}})

      assert {:error, {:blocked, {169, 254, 169, 254}}} =
               Egress.resolve_and_validate("mixed.example", resolver: resolver)
    end

    test "block_private_networks: false allows a private answer" do
      resolver = resolver_returning(%{inet: {:ok, [{10, 0, 0, 1}]}})

      assert {:ok, [{10, 0, 0, 1}]} =
               Egress.resolve_and_validate("internal.example",
                 resolver: resolver,
                 block_private_networks: false
               )
    end

    test "combines addresses from both families in resolution order" do
      resolver =
        resolver_returning(%{
          inet: {:ok, [{93, 184, 216, 34}]},
          inet6: {:ok, [{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]}
        })

      assert {:ok, [{93, 184, 216, 34}, {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]} =
               Egress.resolve_and_validate("dual.example", resolver: resolver)
    end

    test "both families erroring returns {:error, :no_addresses}" do
      resolver = resolver_returning(%{})

      assert {:error, :no_addresses} =
               Egress.resolve_and_validate("nonexistent.example", resolver: resolver)
    end
  end

  describe "resolve_and_validate/2 allowlist escape hatch" do
    defp private_resolver do
      fn _host, :inet -> {:ok, [{10, 1, 2, 3}]} end
    end

    test "allow-listed host resolving to a private IP is permitted" do
      assert {:ok, [{10, 1, 2, 3}]} =
               Egress.resolve_and_validate("internal.example",
                 resolver: private_resolver(),
                 allowed_hosts: ["internal.example"]
               )
    end

    test "trailing dot on the queried host still matches the allowlist" do
      assert {:ok, [{10, 1, 2, 3}]} =
               Egress.resolve_and_validate("internal.example.",
                 resolver: private_resolver(),
                 allowed_hosts: ["internal.example"]
               )
    end

    test "case-insensitive host matches the allowlist" do
      assert {:ok, [{10, 1, 2, 3}]} =
               Egress.resolve_and_validate("INTERNAL.EXAMPLE",
                 resolver: private_resolver(),
                 allowed_hosts: ["internal.example"]
               )
    end

    test "allowlist entry with a trailing dot matches a plain host" do
      assert {:ok, [{10, 1, 2, 3}]} =
               Egress.resolve_and_validate("internal.example",
                 resolver: private_resolver(),
                 allowed_hosts: ["Internal.Example."]
               )
    end
  end

  describe "resolve_and_validate/2 DNS timeout guard" do
    test "a resolver that blocks past dns_timeout returns :dns_timeout promptly" do
      slow_resolver = fn _host, _family ->
        Process.sleep(5_000)
        {:ok, [{1, 1, 1, 1}]}
      end

      {elapsed_us, result} =
        :timer.tc(fn ->
          Egress.resolve_and_validate("slow.example",
            resolver: slow_resolver,
            dns_timeout: 50
          )
        end)

      assert result == {:error, :dns_timeout}
      # Returns well before the resolver's 5s sleep would elapse.
      assert elapsed_us < 1_000_000
    end
  end

  describe "resolve_and_validate/2 resolves address families concurrently" do
    test "a hung inet6 lookup does not sink an inet answer already returned" do
      resolver = fn
        _host, :inet -> {:ok, [{93, 184, 216, 34}]}
        _host, :inet6 -> Process.sleep(5_000)
      end

      {elapsed_us, result} =
        :timer.tc(fn ->
          Egress.resolve_and_validate("dual.example",
            resolver: resolver,
            dns_timeout: 100
          )
        end)

      assert result == {:ok, [{93, 184, 216, 34}]}
      # The inet answer is not held hostage by the inet6 lookup's 5s sleep.
      assert elapsed_us < 1_000_000
    end

    test "both families hanging still yields :dns_timeout" do
      resolver = fn _host, _family -> Process.sleep(5_000) end

      {elapsed_us, result} =
        :timer.tc(fn ->
          Egress.resolve_and_validate("slow.example",
            resolver: resolver,
            dns_timeout: 100
          )
        end)

      assert result == {:error, :dns_timeout}
      assert elapsed_us < 1_000_000
    end
  end

  describe "resolve_and_validate/2 with the real default resolver" do
    test "127.0.0.1 literal is blocked" do
      assert {:error, {:blocked, {127, 0, 0, 1}}} =
               Egress.resolve_and_validate("127.0.0.1")
    end

    test "127.0.0.1 literal is permitted when allow-listed" do
      assert {:ok, [{127, 0, 0, 1}]} =
               Egress.resolve_and_validate("127.0.0.1", allowed_hosts: ["127.0.0.1"])
    end
  end
end
