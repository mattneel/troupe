defmodule Troupe.Capabilities do
  @moduledoc """
  Pure, side-effect-free capabilities shipped with Troupe. They power the
  examples and the playground and run unchanged in the Popcorn browser VM.

  | Capability                    | Result                                        |
  | ----------------------------- | --------------------------------------------- |
  | `text.upcase@1.0.0`           | uppercased `text`                             |
  | `text.template@1.0.0`         | `template` with `{{key}}` replaced from `vars` |
  | `text.contains@1.0.0`         | whether `text` contains `pattern`             |
  | `math.add@1.0.0` …            | `add`, `subtract`, `multiply`, `divide`       |
  | `math.less_than@1.0.0`        | `a < b`                                       |
  | `math.abs@1.0.0`              | absolute value of `value`                     |
  | `list.append_window@1.0.0`    | `list ++ [item]`, keeping the last `keep`     |
  | `agent.scripted_policy@1.0.0` | next step of a scripted plan (an LLM stand-in) |
  """

  @doc "Modules of the standard capabilities."
  @spec modules() :: [module()]
  def modules do
    [
      __MODULE__.Text.Upcase,
      __MODULE__.Text.Template,
      __MODULE__.Text.Contains,
      __MODULE__.Math.Add,
      __MODULE__.Math.Subtract,
      __MODULE__.Math.Multiply,
      __MODULE__.Math.Divide,
      __MODULE__.Math.LessThan,
      __MODULE__.Math.Abs,
      __MODULE__.List.AppendWindow,
      __MODULE__.Agent.ScriptedPolicy
    ]
  end
end

defmodule Troupe.Capabilities.Text.Upcase do
  @moduledoc "Uppercases text."
  use Troupe.Capability,
    name: "text.upcase",
    version: "1.0.0",
    description: "Uppercases text.",
    inputs: [text: :string],
    output: :string

  @impl true
  def run(%{"text" => text}, _context), do: {:ok, String.upcase(text)}
end

defmodule Troupe.Capabilities.Text.Template do
  @moduledoc "Replaces `{{key}}` placeholders with values from `vars`."
  use Troupe.Capability,
    name: "text.template",
    version: "1.0.0",
    description: "Replaces {{key}} placeholders in template with values from vars.",
    inputs: [template: :string, vars: [type: :map, default: %{}]],
    output: :string

  @placeholder ~r/\{\{\s*([A-Za-z0-9_]+)\s*\}\}/

  @impl true
  def run(%{"template" => template, "vars" => vars}, _context) do
    missing =
      @placeholder
      |> Regex.scan(template, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(&Map.has_key?(vars, &1))
      |> Enum.uniq()

    case missing do
      [] ->
        {:ok,
         Regex.replace(@placeholder, template, fn _match, key -> text(Map.fetch!(vars, key)) end)}

      missing ->
        {:error, "template variables missing from vars: #{Enum.join(missing, ", ")}"}
    end
  end

  defp text(value) when is_binary(value), do: value

  defp text(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: to_string(value)

  defp text(value), do: Jason.encode!(value)
end

defmodule Troupe.Capabilities.Text.Contains do
  @moduledoc "Reports whether text contains a pattern."
  use Troupe.Capability,
    name: "text.contains",
    version: "1.0.0",
    description: "True when text contains pattern (case-insensitive unless case_sensitive).",
    inputs: [text: :string, pattern: :string, case_sensitive: [type: :boolean, default: false]],
    output: :boolean

  @impl true
  def run(%{"text" => text, "pattern" => pattern, "case_sensitive" => true}, _context),
    do: {:ok, String.contains?(text, pattern)}

  def run(%{"text" => text, "pattern" => pattern}, _context),
    do: {:ok, String.contains?(String.downcase(text), String.downcase(pattern))}
end

for {module, name, operator, doc} <- [
      {Troupe.Capabilities.Math.Add, "math.add", :+, "Adds a and b."},
      {Troupe.Capabilities.Math.Subtract, "math.subtract", :-, "Subtracts b from a."},
      {Troupe.Capabilities.Math.Multiply, "math.multiply", :*, "Multiplies a by b."},
      {Troupe.Capabilities.Math.LessThan, "math.less_than", :<, "True when a < b."}
    ] do
  defmodule module do
    @moduledoc doc
    use Troupe.Capability,
      name: name,
      version: "1.0.0",
      description: doc,
      inputs: [a: :number, b: :number],
      output: if(operator == :<, do: :boolean, else: :number)

    @operator operator

    @impl true
    def run(%{"a" => a, "b" => b}, _context), do: {:ok, apply(Kernel, @operator, [a, b])}
  end
end

defmodule Troupe.Capabilities.Math.Divide do
  @moduledoc "Divides a by b."
  use Troupe.Capability,
    name: "math.divide",
    version: "1.0.0",
    description: "Divides a by b; fails on division by zero.",
    inputs: [a: :number, b: :number],
    output: :number

  @impl true
  def run(%{"b" => b}, _context) when b == 0, do: {:error, "division by zero"}
  def run(%{"a" => a, "b" => b}, _context), do: {:ok, a / b}
end

defmodule Troupe.Capabilities.Math.Abs do
  @moduledoc "Absolute value."
  use Troupe.Capability,
    name: "math.abs",
    version: "1.0.0",
    description: "Absolute value of value.",
    inputs: [value: :number],
    output: :number

  @impl true
  def run(%{"value" => value}, _context), do: {:ok, abs(value)}
end

defmodule Troupe.Capabilities.List.AppendWindow do
  @moduledoc """
  Appends an item and keeps only the newest `keep` items — a bounded
  scratchpad, so loop state does not grow with iteration count.
  """
  use Troupe.Capability,
    name: "list.append_window",
    version: "1.0.0",
    description: "Appends item to list and keeps only the last keep items.",
    inputs: [list: :list, item: :any, keep: [type: :integer, default: 5]],
    output: :list

  @impl true
  def run(%{"keep" => keep}, _context) when keep < 1, do: {:error, "keep must be at least 1"}

  def run(%{"list" => list, "item" => item, "keep" => keep}, _context),
    do: {:ok, Enum.take(list ++ [item], -keep)}
end

defmodule Troupe.Capabilities.Agent.ScriptedPolicy do
  @moduledoc """
  Deterministic stand-in for an LLM policy in ReAct-style loops: returns the
  plan step at `step` as a tool decision, or an `answer` decision once the
  plan is exhausted. Lets examples and tests exercise agent loops without
  network calls.
  """
  use Troupe.Capability,
    name: "agent.scripted_policy",
    version: "1.0.0",
    description:
      "Returns plan[step] as {tool, operand, thought, done}; answers when the plan is exhausted.",
    inputs: [plan: :list, step: :integer, value: :number],
    output: :map

  @impl true
  def run(%{"plan" => plan, "step" => step, "value" => value}, _context) do
    case Enum.at(plan, step) do
      %{"tool" => tool, "operand" => operand} when is_binary(tool) and is_number(operand) ->
        {:ok, decision(tool, operand, "#{tool} #{format(value)} and #{format(operand)}", false)}

      nil ->
        {:ok, decision("answer", value, "the answer is #{format(value)}", true)}

      other ->
        {:error,
         "plan step #{step} must be {\"tool\": string, \"operand\": number}, got #{inspect(other)}"}
    end
  end

  defp decision(tool, operand, thought, done),
    do: %{"tool" => tool, "operand" => operand, "thought" => thought, "done" => done}

  defp format(number) when is_float(number), do: :erlang.float_to_binary(number, [:short])
  defp format(number), do: to_string(number)
end
