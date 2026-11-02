defmodule Troupe.Examples.CalculatorAgent do
  @moduledoc """
  Spark-authored ReAct-style agent loop: think (`agent.scripted_policy`, a
  deterministic LLM stand-in) → act (branch to a math tool) → observe (append
  to a bounded scratchpad). Only `{value, scratchpad}` is carried between
  iterations; the scratchpad keeps the last `keep` notes, so loop state stays
  bounded no matter how many steps the plan has.

  Its JSON twin is `examples/calculator_agent.json`.
  """

  use Troupe.Workflow

  workflow do
    id "calculator_agent"
    version "1.0.0"
    description "ReAct-style loop that applies a plan of math tools to a starting value."

    inputs start: :number,
           plan: :list,
           keep: [
             type: :integer,
             required: false,
             default: 3,
             description: "Scratchpad window size."
           ]

    output result(:agent)

    loop :agent do
      max_iterations 20
      state object(value: input(:start), scratchpad: value([]))
      next_state object(value: result(:act), scratchpad: result(:note))
      until result(:decide, [:done])

      action :decide, "agent.scripted_policy", "~> 1.0" do
        arg :plan, input(:plan)
        arg :step, loop_index(:agent)
        arg :value, loop_state(:agent, [:value])
      end

      branch :act do
        on result(:decide, [:tool])

        match "add" do
          output result(:add)

          action :add, "math.add", "~> 1.0" do
            arg :a, loop_state(:agent, [:value])
            arg :b, result(:decide, [:operand])
          end
        end

        match "multiply" do
          output result(:multiply)

          action :multiply, "math.multiply", "~> 1.0" do
            arg :a, loop_state(:agent, [:value])
            arg :b, result(:decide, [:operand])
          end
        end

        default do
          output loop_state(:agent, [:value])
        end
      end

      action :note, "list.append_window", "~> 1.0" do
        arg :list, loop_state(:agent, [:scratchpad])
        arg :item, object(thought: result(:decide, [:thought]), observation: result(:act))
        arg :keep, input(:keep)
      end
    end
  end
end
