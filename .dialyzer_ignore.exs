# Mint 1.8+ exposes Mint.HTTP.t/0 as an open union of the still-@opaque
# Mint.HTTP1.t / Mint.HTTP2.t structs. Dialyzer treats every hand-off of a
# connection back to Mint's own API as an opaque-term violation at the call
# site, types that call as failing, and cascades no-return / unreachable
# warnings across the transport and the proxy path that folds its result.
#
# The identical code is Dialyzer-clean against Mint 1.7.x, so these are an
# upstream tooling regression rather than a defect; the transport is exercised
# by the test suite. Remove these filters once Mint publishes a Dialyzer-clean
# public connection type.
[
  {"lib/philter/transport.ex", :call_with_opaque},
  {"lib/philter/transport.ex", :no_return},
  {"lib/philter/transport.ex", :unused_fun},
  {"lib/philter.ex", :pattern_match, 689}
]
