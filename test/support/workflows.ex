defmodule Troupe.TestWorkflows do
  @moduledoc false
  # Portable maps for test workflows, built as plain data like an agent would.

  def record(id, log, value, extra \\ %{}) do
    %{
      "id" => id,
      "kind" => "action",
      "capability" => %{"name" => "test.record", "version" => "~> 1.0"},
      "args" =>
        Map.merge(
          %{"log" => %{"value" => log}, "label" => %{"value" => id}, "value" => value},
          extra
        )
    }
  end

  @doc "A chain of `count` test.record actions: step_1 -> ... -> step_count."
  def chain(count, log, opts \\ []) do
    crash_at = Keyword.get(opts, :crash_at)
    marker = Keyword.get(opts, :crash_marker)

    nodes =
      for index <- 1..count do
        value = if index == 1, do: %{"input" => "start"}, else: %{"result" => "step_#{index - 1}"}
        extra = if index == crash_at, do: %{"crash_marker" => %{"value" => marker}}, else: %{}
        record("step_#{index}", log, value, extra)
      end

    %{
      "schema_version" => 1,
      "id" => "chain_#{count}",
      "version" => "1.0.0",
      "inputs" => [%{"name" => "start", "type" => "integer"}],
      "nodes" => nodes,
      "output" => %{"result" => "step_#{count}"}
    }
  end

  def definition!(map) do
    {:ok, definition} = Troupe.Definition.from_map(map)
    definition
  end
end
