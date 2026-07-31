# WebSockex's own handle_cast/2 is a no_return by design (it always raises
# on an unexpected cast). Not ours to fix, and not worth failing the gate.
[
  {"deps/websockex/lib/websockex.ex", :no_return}
]
