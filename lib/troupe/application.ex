defmodule Troupe.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The playground server only runs inside the Popcorn browser VM, where
    # JavaScript reaches it through Popcorn.Proxy. As a library, Troupe starts
    # no processes.
    children = if Popcorn.JS.available?(), do: [Troupe.Playground], else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Troupe.Supervisor)
  end
end
