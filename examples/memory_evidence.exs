# Memory evidence: active loop state stays flat while history grows.
#
#   mix run examples/memory_evidence.exs
#
# Runs a ReAct-shaped loop (observe -> append to a bounded scratchpad) for
# N iterations, each producing a ~1 KiB observation, and samples at every
# iteration boundary (the maximum over all iterations is reported):
#
#   * frame words   - :erts_debug.size of the Troupe.Runtime.Frame carried
#                     between iterations
#   * state bytes   - :erlang.external_size of the loop state handed to the
#                     next iteration (what the definition chose to carry)
#   * heap words    - run process heap right after a full GC (live data)
#   * binary bytes  - off-heap binaries the run process still references
#
# History (events) and payloads go to a Troupe.Store.Memory agent, a
# separate process, whose memory is reported for contrast. The last column
# is the size the final frame would have if every frame embedded the
# previous one (the cumulative-nesting anti-pattern).

defmodule MemoryEvidence do
  @blob String.duplicate("x", 1024)

  def definition(iterations, keep) do
    {:ok, definition} =
      Troupe.Definition.from_map(%{
        "schema_version" => 1,
        "id" => "memory_evidence",
        "version" => "1.0.0",
        "nodes" => [
          %{
            "id" => "agent",
            "kind" => "loop",
            "max_iterations" => iterations,
            "state" => %{"object" => %{"scratchpad" => %{"value" => []}}},
            "nodes" => [
              %{
                "id" => "observe",
                "kind" => "action",
                "capability" => %{"name" => "list.append_window", "version" => "~> 1.0"},
                "args" => %{
                  "list" => %{"loop" => "state", "of" => "agent", "path" => ["scratchpad"]},
                  "item" => %{
                    "object" => %{
                      "iteration" => %{"loop" => "index", "of" => "agent"},
                      "observation" => %{"value" => @blob}
                    }
                  },
                  "keep" => %{"value" => keep}
                }
              }
            ],
            "next_state" => %{"object" => %{"scratchpad" => %{"result" => "observe"}}}
          }
        ],
        "output" => %{"result" => "agent"}
      })

    definition
  end

  def handle(_event, _measurements, %{frame: frame, run_id: run_id}, {table, store}) do
    {:ok, state} = Troupe.Store.fetch_payload(store, run_id, frame.state_key)
    :erlang.garbage_collect()
    {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
    {:binary, binaries} = Process.info(self(), :binary)
    binary_bytes = binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    :ets.insert(table, {frame.index, :erts_debug.size(frame), :erlang.external_size(state), heap, binary_bytes})
  end

  def measure(iterations, keep) do
    table = :ets.new(:samples, [:public, :ordered_set])
    store = Troupe.Store.Memory.new()
    handler = "memory-evidence-#{iterations}-#{keep}"
    :telemetry.attach(handler, [:troupe, :frame], &__MODULE__.handle/4, {table, store})

    {:ok, run} =
      Troupe.run(definition(iterations, keep), %{},
        store: store,
        async?: false,
        grant: Troupe.Grant.new!(["list.append_window"])
      )

    :telemetry.detach(handler)
    samples = :ets.tab2list(table)
    :ets.delete(table)
    {:memory, store_bytes} = Process.info(store.pid, :memory)
    stats = Troupe.Store.stats(store, run.id)
    Agent.stop(store.pid)

    max = fn position -> samples |> Enum.map(&elem(&1, position)) |> Enum.max() end

    %{
      iterations: iterations,
      keep: keep,
      frame_words: max.(1),
      state_bytes: max.(2),
      heap_words: max.(3),
      binary_bytes: max.(4),
      events: stats.events,
      payloads: stats.payloads,
      store_bytes: store_bytes,
      nested_bytes: nested_bytes(iterations)
    }
  end

  # Size of the last frame if every frame embedded its predecessor.
  defp nested_bytes(iterations) do
    0..(iterations - 1)
    |> Enum.reduce(nil, fn index, previous -> %{index: index, observation: @blob, previous: previous} end)
    |> :erlang.external_size()
  end
end

IO.puts(
  "| iterations | keep | frame words | state bytes | run heap words | run binary bytes | history events | payloads | store bytes | nested-frame bytes |"
)

IO.puts("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

for {iterations, keep} <- [{10, 3}, {100, 3}, {1000, 3}, {1000, 1000}] do
  r = MemoryEvidence.measure(iterations, keep)

  IO.puts(
    "| #{r.iterations} | #{r.keep} | #{r.frame_words} | #{r.state_bytes} | #{r.heap_words} | #{r.binary_bytes} | #{r.events} | #{r.payloads} | #{r.store_bytes} | #{r.nested_bytes} |"
  )
end
