ExUnit.start()

# Start a Finch pool for all tests
{:ok, _} = Finch.start_link(name: Philter.TestFinch)
Application.put_env(:philter, :finch_name, Philter.TestFinch)

# The SSRF egress guard is on by default and blocks loopback. Bypass binds to
# 127.0.0.1 (reached via the "localhost" upstream URL), so allow-list both here
# in one place: existing proxy tests still exercise the guard, taking the
# allow-list path to reach Bypass. Do NOT disable the guard suite-wide.
Application.put_env(:philter, :allowed_hosts, ["127.0.0.1", "localhost"])
