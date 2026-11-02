defmodule Troupe.Definition.Decoder do
  @moduledoc false
  # Shape decoding: portable map -> definition structs. Collects every problem
  # with its JSON pointer instead of stopping at the first one. Semantic checks
  # (scopes, references, cycles) live in Troupe.Definition.Validator.

  alias Troupe.{Definition, Error, Expr, PlainData, Schema}
  alias Troupe.Definition.{Action, Branch, CapabilityRef, Case, Input, Loop}

  @identifier ~r/^[a-z][a-z0-9_]{0,63}$/
  @workflow_id ~r/^[a-z][a-z0-9_.-]{0,127}$/
  @capability_name ~r/^[a-z][a-z0-9_]{0,63}(\.[a-z][a-z0-9_]{0,63}){0,7}$/
  @max_attempts 20
  @max_iterations 100_000
  @max_depth 16

  @type result(value) :: {value | nil, [Error.t()]}

  @spec decode(term()) :: {:ok, Definition.t()} | {:error, [Error.t()]}
  def decode(map) when is_map(map) and not is_struct(map) do
    case Map.fetch(map, "schema_version") do
      {:ok, 1} ->
        decode_workflow(map)

      {:ok, other} ->
        {:error,
         [
           Error.new(
             :unsupported_schema_version,
             "schema_version #{inspect_plain(other)} is not supported; this library reads version #{Definition.schema_version()}",
             path: "/schema_version",
             details: %{"supported" => [Definition.schema_version()]}
           )
         ]}

      :error ->
        {:error, [missing("", "schema_version")]}
    end
  end

  def decode(other),
    do:
      {:error,
       [invalid("", "a workflow definition must be an object, got #{PlainData.describe(other)}")]}

  defp decode_workflow(map) do
    keys = ~w(schema_version id version description inputs nodes output)

    {[id, version, description, inputs, nodes, output], errors} =
      gather([
        unknown_keys(map, keys, ""),
        field(map, "id", "", &pattern(&1, &2, @workflow_id, "workflow id")),
        field(map, "version", "", &semver/2),
        optional(map, "description", "", &string/2, nil),
        optional(map, "inputs", "", &inputs/2, []),
        field(map, "nodes", "", &node_list(&1, &2, 0, :non_empty)),
        field(map, "output", "", &expr/2)
      ])

    finish(errors, fn ->
      %Definition{
        id: id,
        version: version,
        description: description,
        inputs: inputs,
        nodes: nodes,
        output: output
      }
    end)
  end

  # -- inputs -----------------------------------------------------------------

  defp inputs(list, pointer) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> input(item, "#{pointer}/#{index}") end)
    |> gather()
  end

  defp inputs(other, pointer),
    do: {nil, [invalid(pointer, "must be a list, got #{PlainData.describe(other)}")]}

  defp input(map, pointer) when is_map(map) do
    {[name, type, required, default, description], errors} =
      gather([
        unknown_keys(map, ~w(name type required default description), pointer),
        field(map, "name", pointer, &identifier/2),
        field(map, "type", pointer, &type/2),
        optional(map, "required", pointer, &boolean/2, not Map.has_key?(map, "default")),
        optional(map, "default", pointer, &literal/2, nil),
        optional(map, "description", pointer, &string/2, nil)
      ])

    errors = errors ++ default_errors(type, required, default, pointer)

    finish_value(errors, fn ->
      %Input{
        name: name,
        type: type,
        required: required,
        default: default,
        description: description
      }
    end)
  end

  defp input(other, pointer),
    do: {nil, [invalid(pointer, "input must be an object, got #{PlainData.describe(other)}")]}

  defp default_errors(nil, _required, _default, _pointer), do: []
  defp default_errors(_type, _required, nil, _pointer), do: []

  defp default_errors(_type, true, _default, pointer),
    do: [invalid(pointer <> "/default", ~s(an input with a default must set "required": false))]

  defp default_errors(type, _required, default, pointer) do
    if Schema.type?(default, type),
      do: [],
      else: [
        invalid(
          pointer <> "/default",
          "default must be #{type}, got #{PlainData.describe(default)}"
        )
      ]
  end

  # -- nodes ------------------------------------------------------------------

  defp node_list(list, pointer, depth, emptiness) when is_list(list) do
    cond do
      depth > @max_depth ->
        {nil, [invalid(pointer, "nodes are nested deeper than #{@max_depth} levels")]}

      list == [] and emptiness == :non_empty ->
        {nil, [invalid(pointer, "must contain at least one node")]}

      true ->
        list
        |> Enum.with_index()
        |> Enum.map(fn {item, index} -> workflow_node(item, "#{pointer}/#{index}", depth) end)
        |> gather()
    end
  end

  defp node_list(other, pointer, _depth, _emptiness),
    do: {nil, [invalid(pointer, "must be a list of nodes, got #{PlainData.describe(other)}")]}

  defp workflow_node(map, pointer, depth) when is_map(map) do
    case Map.fetch(map, "kind") do
      {:ok, "action"} ->
        action(map, pointer)

      {:ok, "branch"} ->
        branch(map, pointer, depth)

      {:ok, "loop"} ->
        loop(map, pointer, depth)

      {:ok, other} ->
        {nil,
         [
           invalid(
             pointer <> "/kind",
             ~s(unknown node kind #{inspect_plain(other)}; expected "action", "branch" or "loop")
           )
         ]}

      :error ->
        {nil, [missing(pointer, "kind")]}
    end
  end

  defp workflow_node(other, pointer, _depth),
    do: {nil, [invalid(pointer, "node must be an object, got #{PlainData.describe(other)}")]}

  defp action(map, pointer) do
    {[id, capability, args, max_attempts, description], errors} =
      gather([
        unknown_keys(map, ~w(id kind capability args max_attempts description), pointer),
        field(map, "id", pointer, &identifier/2),
        field(map, "capability", pointer, &capability/2),
        optional(map, "args", pointer, &args/2, %{}),
        optional(map, "max_attempts", pointer, &bounded_integer(&1, &2, @max_attempts), 1),
        optional(map, "description", pointer, &string/2, nil)
      ])

    finish_value(errors, fn ->
      %Action{
        id: id,
        capability: capability,
        args: args,
        max_attempts: max_attempts,
        description: description
      }
    end)
  end

  defp branch(map, pointer, depth) do
    {[id, on, cases, default, description], errors} =
      gather([
        unknown_keys(map, ~w(id kind on cases default description), pointer),
        field(map, "id", pointer, &identifier/2),
        field(map, "on", pointer, &expr/2),
        field(map, "cases", pointer, &cases(&1, &2, depth)),
        optional(map, "default", pointer, &branch_case(&1, &2, depth, :default), nil),
        optional(map, "description", pointer, &string/2, nil)
      ])

    finish_value(errors, fn ->
      %Branch{id: id, on: on, cases: cases, default: default, description: description}
    end)
  end

  defp cases(list, pointer, depth) when is_list(list) and list != [] do
    {cases, errors} =
      list
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> branch_case(item, "#{pointer}/#{index}", depth, :match) end)
      |> gather()

    {cases, errors ++ duplicate_matches(cases, pointer)}
  end

  defp cases(_other, pointer, _depth),
    do: {nil, [invalid(pointer, "must be a non-empty list of cases")]}

  defp duplicate_matches(cases, pointer) do
    cases
    |> Enum.with_index()
    |> Enum.reject(fn {branch_case, _index} -> is_nil(branch_case) end)
    |> Enum.group_by(fn {branch_case, _index} -> branch_case.match end, fn {_case, index} ->
      index
    end)
    |> Enum.flat_map(fn
      {_match, [_single]} ->
        []

      {match, [_first | rest]} ->
        Enum.map(
          rest,
          &invalid("#{pointer}/#{&1}/match", "duplicate match #{inspect_plain(match)}")
        )
    end)
  end

  defp branch_case(map, pointer, depth, mode) when is_map(map) do
    keys = if mode == :match, do: ~w(match nodes output), else: ~w(nodes output)

    match_result =
      if mode == :match, do: field(map, "match", pointer, &literal/2), else: {nil, []}

    {[match, nodes, output], errors} =
      gather([
        unknown_keys(map, keys, pointer),
        match_result,
        optional(map, "nodes", pointer, &node_list(&1, &2, depth + 1, :may_be_empty), []),
        field(map, "output", pointer, &expr/2)
      ])

    finish_value(errors, fn ->
      %Case{match: match, default?: mode == :default, nodes: nodes, output: output}
    end)
  end

  defp branch_case(other, pointer, _depth, _mode),
    do: {nil, [invalid(pointer, "case must be an object, got #{PlainData.describe(other)}")]}

  defp loop(map, pointer, depth) do
    keys = ~w(id kind max_iterations state nodes next_state until description)

    {[id, max_iterations, state, nodes, next_state, until, description], errors} =
      gather([
        unknown_keys(map, keys, pointer),
        field(map, "id", pointer, &identifier/2),
        field(map, "max_iterations", pointer, &bounded_integer(&1, &2, @max_iterations)),
        field(map, "state", pointer, &expr/2),
        field(map, "nodes", pointer, &node_list(&1, &2, depth + 1, :non_empty)),
        field(map, "next_state", pointer, &expr/2),
        optional(map, "until", pointer, &expr/2, nil),
        optional(map, "description", pointer, &string/2, nil)
      ])

    finish_value(errors, fn ->
      %Loop{
        id: id,
        max_iterations: max_iterations,
        state: state,
        nodes: nodes,
        next_state: next_state,
        until: until,
        description: description
      }
    end)
  end

  # -- leaf decoders ----------------------------------------------------------

  defp capability(map, pointer) when is_map(map) do
    {[name, version], errors} =
      gather([
        unknown_keys(map, ~w(name version), pointer),
        field(map, "name", pointer, &pattern(&1, &2, @capability_name, "capability name")),
        field(map, "version", pointer, &requirement/2)
      ])

    finish_value(errors, fn -> %CapabilityRef{name: name, version: version} end)
  end

  defp capability(other, pointer),
    do:
      {nil,
       [
         invalid(
           pointer,
           ~s(must be {"name": ..., "version": ...}, got #{PlainData.describe(other)})
         )
       ]}

  defp args(map, pointer) when is_map(map) do
    {pairs, errors} =
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} ->
        arg_pointer = "#{pointer}/#{key}"

        case {identifier(key, arg_pointer), expr(value, arg_pointer)} do
          {{:ok, key}, {:ok, parsed}} -> {{key, parsed}, []}
          {key_result, expr_result} -> {nil, errors_of(key_result) ++ errors_of(expr_result)}
        end
      end)
      |> gather()

    finish_value(errors, fn -> Map.new(pairs) end)
  end

  defp args(other, pointer),
    do: {nil, [invalid(pointer, "must be an object, got #{PlainData.describe(other)}")]}

  defp errors_of({:ok, _value}), do: []
  defp errors_of({:error, errors}), do: errors

  defp expr(value, pointer), do: Expr.parse(value, pointer)

  defp literal(value, pointer) do
    with :ok <- PlainData.check_literal(value, pointer), do: {:ok, value}
  end

  defp identifier(value, pointer), do: pattern(value, pointer, @identifier, "identifier")

  defp pattern(value, pointer, regex, label) do
    if is_binary(value) and Regex.match?(regex, value),
      do: {:ok, value},
      else:
        error(pointer, "#{label} must match #{Regex.source(regex)}, got #{inspect_plain(value)}")
  end

  defp semver(value, pointer) when is_binary(value) do
    case Version.parse(value) do
      {:ok, _version} -> {:ok, value}
      :error -> error(pointer, "must be a semantic version like \"1.0.0\", got #{inspect(value)}")
    end
  end

  defp semver(value, pointer),
    do: error(pointer, "must be a version string, got #{PlainData.describe(value)}")

  defp requirement(value, pointer) when is_binary(value) do
    case Version.parse_requirement(value) do
      {:ok, _requirement} ->
        {:ok, value}

      :error ->
        error(pointer, "must be a version requirement like \"~> 1.0\", got #{inspect(value)}")
    end
  end

  defp requirement(value, pointer),
    do: error(pointer, "must be a version requirement string, got #{PlainData.describe(value)}")

  defp type(value, pointer) do
    case Schema.parse_type(value) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        error(
          pointer,
          "type must be one of #{Enum.join(Schema.type_names(), ", ")}, got #{inspect_plain(value)}"
        )
    end
  end

  defp string(value, _pointer) when is_binary(value), do: {:ok, value}

  defp string(value, pointer),
    do: error(pointer, "must be a string, got #{PlainData.describe(value)}")

  defp boolean(value, _pointer) when is_boolean(value), do: {:ok, value}

  defp boolean(value, pointer),
    do: error(pointer, "must be true or false, got #{PlainData.describe(value)}")

  defp bounded_integer(value, _pointer, max)
       when is_integer(value) and value >= 1 and value <= max,
       do: {:ok, value}

  defp bounded_integer(value, pointer, max),
    do: error(pointer, "must be an integer from 1 to #{max}, got #{inspect_plain(value)}")

  # -- accumulation helpers ---------------------------------------------------

  defp field(map, key, pointer, fun) do
    case Map.fetch(map, key) do
      {:ok, value} -> to_result(fun.(value, "#{pointer}/#{key}"))
      :error -> {nil, [missing(pointer, key)]}
    end
  end

  defp optional(map, key, pointer, fun, default) do
    case Map.fetch(map, key) do
      {:ok, value} -> to_result(fun.(value, "#{pointer}/#{key}"))
      :error -> {default, []}
    end
  end

  defp to_result({:ok, value}), do: {value, []}
  defp to_result({:error, errors}), do: {nil, errors}
  defp to_result({_value, errors} = result) when is_list(errors), do: result

  defp unknown_keys(map, allowed, pointer) do
    errors =
      for key <- map |> Map.keys() |> Enum.sort(), key not in allowed do
        invalid(
          "#{pointer}/#{key_segment(key)}",
          "unknown field; allowed fields are #{Enum.join(allowed, ", ")}"
        )
      end

    {:skip, errors}
  end

  defp key_segment(key) when is_binary(key), do: key
  defp key_segment(key), do: PlainData.describe(key)

  # Gathers {value, errors} pairs (dropping unknown_keys markers) into
  # {[values], errors}.
  defp gather(results) do
    {values, errors} =
      Enum.reduce(results, {[], []}, fn
        {:skip, errors}, {values, acc} -> {values, acc ++ errors}
        {value, errors}, {values, acc} -> {[value | values], acc ++ errors}
      end)

    {Enum.reverse(values), errors}
  end

  defp finish([], build), do: {:ok, build.()}
  defp finish(errors, _build), do: {:error, errors}

  defp finish_value([], build), do: {build.(), []}
  defp finish_value(errors, _build), do: {nil, errors}

  defp error(pointer, message), do: {:error, [invalid(pointer, message)]}

  defp invalid(pointer, message), do: Error.new(:invalid_definition, message, path: pointer)

  defp missing(pointer, key),
    do: invalid("#{pointer}/#{key}", "missing required field #{inspect(key)}")

  defp inspect_plain(value) when is_binary(value), do: inspect(value)

  defp inspect_plain(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: inspect(value)

  defp inspect_plain(value), do: PlainData.describe(value)
end
