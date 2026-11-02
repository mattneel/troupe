defmodule Troupe.Workflow.Source do
  @moduledoc """
  Reads and writes the `Troupe.Workflow` DSL as source text without compiling
  or evaluating it.

      {:ok, definition} = Troupe.Workflow.Source.parse(File.read!("lib/troupe/examples/greeting.ex"))
      definition == Troupe.Examples.Greeting.definition()   #=> true

      Troupe.Workflow.Source.to_source(definition)           #=> "workflow do\\n  id \\"greeting\\" ..."

  `parse/1` accepts a `workflow do ... end` block, optionally wrapped in
  `defmodule ... do use Troupe.Workflow ... end`. `Code.string_to_quoted/2`
  parses it, with every atom encoded as a string so untrusted source cannot
  create atoms. A `Macro` walk then accepts only DSL forms and literals:
  sections, entities, options, the `Troupe.Workflow.Helpers` expression
  helpers, and plain literals. Anything else is rejected with its line;
  nothing is executed. The result goes through `Troupe.Definition.from_map/1`,
  the same path as the compiled DSL and JSON, so all three produce the same
  definition.

  This is what the browser playground uses for Elixir authoring, and it is
  safe for loading DSL text from untrusted sources on a server.
  """

  alias Troupe.Definition
  alias Troupe.Definition.{Action, Branch, Case, Loop}
  alias Troupe.{Error, Expr}

  @helpers ~w(input result loop_state loop_index secret value object list)

  @typedoc "Maps definition JSON pointers (e.g. `/nodes/1`) to source lines."
  @type lines :: %{String.t() => pos_integer()}

  @doc "Parses DSL source into a validated definition."
  @spec parse(String.t()) :: {:ok, Definition.t()} | {:error, [Error.t()]}
  def parse(source) do
    case parse_with_lines(source) do
      {:ok, definition, _lines} -> {:ok, definition}
      {:error, errors, _lines} -> {:error, errors}
    end
  end

  @doc """
  Like `parse/1`, also returning the source line of each node and field, so
  validation errors (which carry JSON pointers) can be shown on their lines.
  Errors raised while reading the source have `details["line"]`.
  """
  @spec parse_with_lines(String.t()) ::
          {:ok, Definition.t(), lines()} | {:error, [Error.t()], lines()}
  def parse_with_lines(source) when is_binary(source) do
    encoder = fn name, _meta -> {:ok, {:troupe_atom, name}} end

    case Code.string_to_quoted(source, static_atoms_encoder: encoder, existing_atoms_only: false) do
      {:ok, ast} ->
        try do
          {portable, lines} = ast |> workflow_block() |> workflow()
          locate(Definition.from_map(portable), lines)
        catch
          {:troupe_source_error, line, message} -> {:error, [source_error(message, line)], %{}}
        end

      {:error, {meta, message, token}} ->
        line = Keyword.get(meta, :line, 1)
        {:error, [source_error("syntax error: #{format_message(message)}#{token}", line)], %{}}
    end
  end

  defp locate({:ok, definition}, lines), do: {:ok, definition, lines}

  defp locate({:error, errors}, lines) do
    {:error, Enum.map(errors, &put_line(&1, line_for(&1.path, lines))), lines}
  end

  defp put_line(error, nil), do: error
  defp put_line(error, line), do: %{error | details: Map.put(error.details, "line", line)}

  @doc "The source line for a JSON pointer: its own line or its closest located ancestor's."
  @spec line_for(String.t() | nil, lines()) :: pos_integer() | nil
  def line_for(nil, lines), do: Map.get(lines, "")

  def line_for(path, lines) do
    case Map.fetch(lines, path) do
      {:ok, line} ->
        line

      :error when path == "" ->
        nil

      :error ->
        parent = path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
        line_for(parent, lines)
    end
  end

  defp format_message({prefix, suffix}), do: "#{prefix}#{suffix}"
  defp format_message(message), do: message

  defp source_error(message, line),
    do: Error.new(:invalid_definition, "line #{line}: #{message}", details: %{"line" => line})

  defp fail!(meta_or_line, message) do
    line = if is_list(meta_or_line), do: Keyword.get(meta_or_line, :line, 1), else: meta_or_line
    throw({:troupe_source_error, line, message})
  end

  # -- module wrapper ---------------------------------------------------------

  defp workflow_block({:__block__, _meta, forms}) do
    case Enum.filter(forms, &workflow_call?/1) do
      [workflow] -> workflow
      [] -> wrapped(forms)
      [_first, second | _rest] -> fail!(meta(second), "only one workflow block is allowed")
    end
  end

  defp workflow_block(form) do
    if workflow_call?(form), do: form, else: wrapped([form])
  end

  defp wrapped([{name, meta, [_module, [do: body]]}]) do
    if name?(name, "defmodule"),
      do: module_body(body),
      else: fail!(meta, "expected a workflow do ... end block")
  end

  defp wrapped([form | _rest]), do: fail!(meta(form), "expected a workflow do ... end block")
  defp wrapped([]), do: fail!(1, "the source is empty; expected a workflow do ... end block")

  defp module_body(body) do
    forms = statements(body)

    Enum.each(forms, fn form ->
      unless workflow_call?(form) or use_workflow?(form) or moduledoc?(form) do
        fail!(
          meta(form),
          "only `use Troupe.Workflow`, @moduledoc and the workflow block are allowed in the module"
        )
      end
    end)

    case Enum.filter(forms, &workflow_call?/1) do
      [workflow] -> workflow
      [] -> fail!(1, "the module has no workflow do ... end block")
      [_first, second | _rest] -> fail!(meta(second), "only one workflow block is allowed")
    end
  end

  defp workflow_call?({name, _meta, [[do: _body]]}), do: name?(name, "workflow")
  defp workflow_call?(_form), do: false

  defp use_workflow?({name, _meta, [{:__aliases__, _alias_meta, parts}]}),
    do: name?(name, "use") and Enum.map(parts, &name_string/1) == ["Troupe", "Workflow"]

  defp use_workflow?(_form), do: false

  defp moduledoc?({:@, _meta, [{name, _doc_meta, [_doc]}]}), do: name?(name, "moduledoc")
  defp moduledoc?(_form), do: false

  # -- workflow section -------------------------------------------------------

  @workflow_options ~w(id version description inputs output)

  defp workflow({_name, _meta, [[do: body]]} = form) do
    {options, entities} = section(statements(body), @workflow_options)

    {nodes, lines} = entity_list(entities, "/nodes")

    portable =
      %{
        "schema_version" => Definition.schema_version(),
        "id" => option_value(options, "id", &string!/2),
        "version" => option_value(options, "version", &string!/2),
        "inputs" => options |> option_value("inputs", &inputs!/2) |> List.wrap(),
        "nodes" => nodes,
        "output" => option_value(options, "output", &expr!/2)
      }
      |> put_optional("description", option_value(options, "description", &string!/2))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    lines =
      options
      |> Enum.reduce(lines, fn {key, {_value, meta}}, acc ->
        Map.put(acc, "/" <> key, line(meta))
      end)
      |> Map.put("", line(meta(form)))

    {portable, lines}
  end

  # Splits statements into `name value` options (allowed names) and entity
  # calls; options become %{name => {ast_value, meta}}.
  defp section(forms, allowed), do: Enum.reduce(forms, {%{}, []}, &section_form(&1, &2, allowed))

  defp section_form({name, meta, args} = form, {options, entities}, allowed) when is_list(args) do
    key = name_string(name)

    cond do
      key in allowed and match?([_value], args) ->
        {put_option(options, key, hd(args), meta), entities}

      key in ~w(action branch loop match default arg) ->
        {options, entities ++ [form]}

      true ->
        fail!(meta, "unexpected `#{key}`; allowed here: #{Enum.join(allowed, ", ")}")
    end
  end

  defp section_form(form, _acc, _allowed), do: fail!(meta(form), "unexpected #{describe(form)}")

  defp put_option(options, key, value, meta) do
    if Map.has_key?(options, key), do: fail!(meta, "`#{key}` is set more than once")
    Map.put(options, key, {value, meta})
  end

  defp option_value(options, key, fun) do
    case Map.fetch(options, key) do
      {:ok, {value, meta}} -> fun.(value, meta)
      :error -> nil
    end
  end

  # -- entities ---------------------------------------------------------------

  defp entity_list(forms, pointer) do
    forms
    |> Enum.with_index()
    |> Enum.map_reduce(%{}, fn {form, index}, lines ->
      node_pointer = "#{pointer}/#{index}"
      {node, node_lines} = entity(form, node_pointer)
      {node, lines |> Map.merge(node_lines) |> Map.put(node_pointer, line(meta(form)))}
    end)
  end

  @action_options ~w(max_attempts description)
  @branch_options ~w(on description)
  @loop_options ~w(max_iterations state next_state until description)

  defp entity({name, meta, args}, pointer) do
    case name_string(name) do
      "action" -> action(args, meta, pointer)
      "branch" -> branch(args, meta, pointer)
      "loop" -> loop(args, meta, pointer)
      other -> fail!(meta, "`#{other}` is not allowed here; expected action, branch or loop")
    end
  end

  defp action(args, meta, pointer) do
    {positional, inline, body} = call_parts(args, meta)

    [id, capability, version] =
      case positional do
        [_id, _capability, _version] = three ->
          three

        _other ->
          fail!(
            meta,
            ~s(action needs an id, a capability name and a version: action :id, "name", "~> 1.0")
          )
      end

    {options, children} = section(body, @action_options)
    options = merge_inline(options, inline, @action_options, meta)

    {args_map, lines} = Enum.reduce(children, {%{}, %{}}, &action_arg(&1, &2, pointer))

    node =
      %{
        "id" => name!(id, meta),
        "kind" => "action",
        "capability" => %{
          "name" => string!(capability, meta),
          "version" => string!(version, meta)
        },
        "args" => args_map,
        "max_attempts" => option_value(options, "max_attempts", &literal!/2) || 1
      }
      |> put_optional("description", option_value(options, "description", &string!/2))

    {node, lines}
  end

  defp action_arg({child, meta, child_args}, {args, lines}, pointer) do
    case {name_string(child), child_args} do
      {"arg", [arg_name, value]} ->
        key = name!(arg_name, meta)
        if Map.has_key?(args, key), do: fail!(meta, "argument `#{key}` is given more than once")

        {Map.put(args, key, expr!(value, meta)),
         Map.put(lines, "#{pointer}/args/#{key}", line(meta))}

      {other, _args} ->
        fail!(meta, "`#{other}` is not allowed in an action; use arg :name, expression")
    end
  end

  defp branch(args, meta, pointer) do
    {positional, inline, body} = call_parts(args, meta)
    id = single_id(positional, meta, "branch")
    {options, children} = section(body, @branch_options)
    options = merge_inline(options, inline, @branch_options, meta)

    {cases, defaults} = Enum.split_with(children, &(name_string(elem(&1, 0)) == "match"))

    Enum.each(defaults, fn {child, child_meta, _args} ->
      unless name_string(child) == "default",
        do: fail!(child_meta, "a branch may only contain match and default blocks")
    end)

    if defaults |> tl_or_empty() |> Enum.any?(),
      do: fail!(meta(Enum.at(defaults, 1)), "a branch has at most one default block")

    {case_maps, lines} =
      cases
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {form, index}, lines ->
        case_pointer = "#{pointer}/cases/#{index}"
        {map, case_lines} = branch_case(form, case_pointer, :match)
        {map, lines |> Map.merge(case_lines) |> Map.put(case_pointer, line(meta(form)))}
      end)

    {default, lines} =
      case defaults do
        [form] ->
          {map, default_lines} = branch_case(form, pointer <> "/default", :default)

          {map,
           lines |> Map.merge(default_lines) |> Map.put(pointer <> "/default", line(meta(form)))}

        [] ->
          {nil, lines}
      end

    node =
      %{
        "id" => id,
        "kind" => "branch",
        "on" => option_value(options, "on", &expr!/2),
        "cases" => case_maps
      }
      |> put_optional("default", default)
      |> put_optional("description", option_value(options, "description", &string!/2))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {node, lines}
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_head | tail]), do: tail

  defp branch_case({_name, meta, args}, pointer, mode) do
    {positional, inline, body} = call_parts(args, meta)
    {options, children} = section(body, ["output"])
    options = merge_inline(options, inline, ["output"], meta)
    {nodes, lines} = entity_list(children, pointer <> "/nodes")

    match =
      case {mode, positional} do
        {:match, [value]} ->
          %{"match" => literal!(value, meta)}

        {:default, []} ->
          %{}

        {:match, _other} ->
          fail!(meta, "match needs exactly one literal value: match \"value\" do ... end")

        {:default, _other} ->
          fail!(meta, "default takes no value")
      end

    map =
      match
      |> Map.put("nodes", nodes)
      |> put_optional("output", option_value(options, "output", &expr!/2))

    {map, lines}
  end

  defp loop(args, meta, pointer) do
    {positional, inline, body} = call_parts(args, meta)
    id = single_id(positional, meta, "loop")
    {options, children} = section(body, @loop_options)
    options = merge_inline(options, inline, @loop_options, meta)
    {nodes, lines} = entity_list(children, pointer <> "/nodes")

    node =
      %{
        "id" => id,
        "kind" => "loop",
        "max_iterations" => option_value(options, "max_iterations", &literal!/2),
        "state" => option_value(options, "state", &expr!/2),
        "nodes" => nodes,
        "next_state" => option_value(options, "next_state", &expr!/2)
      }
      |> put_optional("until", option_value(options, "until", &expr!/2))
      |> put_optional("description", option_value(options, "description", &string!/2))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {node, lines}
  end

  defp single_id([id], meta, _kind), do: name!(id, meta)

  defp single_id(_args, meta, kind),
    do: fail!(meta, "#{kind} needs exactly one id: #{kind} :name do ... end")

  # Splits `name a, b, opt: v do ... end` into positional args, inline
  # keyword options and body statements.
  defp call_parts(args, meta) do
    {body, rest} =
      case List.last(args) do
        [{:do, body}] -> {statements(body), Enum.drop(args, -1)}
        _other -> fail!(meta, "missing do ... end block")
      end

    case List.last(rest) do
      [_pair | _more] = keyword ->
        if keyword?(keyword), do: {Enum.drop(rest, -1), keyword, body}, else: {rest, [], body}

      _other ->
        {rest, [], body}
    end
  end

  defp keyword?(list), do: Enum.all?(list, &match?({{:troupe_atom, _name}, _value}, &1))

  defp merge_inline(options, inline, allowed, meta) do
    Enum.reduce(inline, options, fn {key, value}, acc ->
      key = name_string(key)

      unless key in allowed,
        do: fail!(meta, "unknown option `#{key}`; allowed: #{Enum.join(allowed, ", ")}")

      Map.put(acc, key, {value, meta})
    end)
  end

  # -- inputs -----------------------------------------------------------------

  defp inputs!(ast, meta) do
    unless is_list(ast) and keyword?(ast),
      do: fail!(meta, "inputs must be a keyword list, e.g. inputs name: :string")

    Enum.map(ast, fn {name, spec} -> input!(name_string(name), spec, meta) end)
  end

  defp input!(name, {:troupe_atom, type}, _meta), do: %{"name" => name, "type" => type}

  defp input!(name, options, meta) when is_list(options) do
    unless keyword?(options), do: fail!(meta, "input #{name}: options must be a keyword list")
    Enum.reduce(options, %{"name" => name}, &input_option!(&1, &2, name, meta))
  end

  defp input!(name, _spec, meta),
    do: fail!(meta, "input #{name}: expected a type atom or a keyword list")

  defp input_option!({key, value}, acc, name, meta) do
    case name_string(key) do
      "type" -> Map.put(acc, "type", name!(value, meta))
      "required" -> Map.put(acc, "required", literal!(value, meta))
      "default" -> Map.put(acc, "default", literal!(value, meta))
      "description" -> Map.put(acc, "description", string!(value, meta))
      other -> fail!(meta, "input #{name}: unknown option `#{other}`")
    end
  end

  # -- expressions ------------------------------------------------------------

  defp expr!({name, call_meta, args} = ast, meta) when is_list(args) do
    helper = name_string(name)

    if helper in @helpers do
      helper_call(helper, args, call_meta)
    else
      fail!(
        call_meta || meta,
        "#{describe(ast)} is not an expression helper; use #{Enum.join(@helpers, ", ")}"
      )
    end
  end

  defp expr!(ast, meta),
    do:
      fail!(
        meta,
        "expected an expression helper such as input(:name) or value(1), got #{describe(ast)}"
      )

  defp helper_call("input", [name | path], meta),
    do: with_path(%{"input" => name!(name, meta)}, path, meta)

  defp helper_call("result", [node | path], meta),
    do: with_path(%{"result" => name!(node, meta)}, path, meta)

  defp helper_call("loop_state", [loop | path], meta),
    do: with_path(%{"loop" => "state", "of" => name!(loop, meta)}, path, meta)

  defp helper_call("loop_index", [loop], meta),
    do: %{"loop" => "index", "of" => name!(loop, meta)}

  defp helper_call("secret", [name], meta), do: %{"secret" => string!(name, meta)}
  defp helper_call("value", [literal], meta), do: %{"value" => literal!(literal, meta)}

  defp helper_call("object", [fields], meta) do
    pairs =
      case fields do
        {:%{}, _map_meta, pairs} -> pairs
        list when is_list(list) -> list
        _other -> fail!(meta, "object expects a keyword list or a map of expressions")
      end

    %{
      "object" =>
        Map.new(pairs, fn {key, value} -> {key_string!(key, meta), expr!(value, meta)} end)
    }
  end

  defp helper_call("list", [items], meta) when is_list(items),
    do: %{"list" => Enum.map(items, &expr!(&1, meta))}

  defp helper_call(helper, args, meta),
    do: fail!(meta, "#{helper}/#{length(args)} is not a valid use of the #{helper} helper")

  defp with_path(map, [], _meta), do: map

  defp with_path(map, [path], meta) do
    segments = if is_list(path), do: path, else: [path]

    Map.put(
      map,
      "path",
      Enum.map(segments, fn
        segment when is_integer(segment) and segment >= 0 ->
          segment

        segment when is_binary(segment) ->
          segment

        {:troupe_atom, segment} ->
          segment

        other ->
          fail!(
            meta,
            "path segments must be atoms, strings or non-negative integers, got #{describe(other)}"
          )
      end)
    )
  end

  defp with_path(_map, _extra, meta),
    do: fail!(meta, "too many arguments; a path is one list, e.g. result(:node, [:field])")

  # -- literals ---------------------------------------------------------------

  defp literal!(value, _meta)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp literal!({:troupe_atom, name}, meta),
    do: fail!(meta, "the atom :#{name} is not portable data; use the string \"#{name}\"")

  defp literal!({:-, _op_meta, [number]}, _meta) when is_number(number), do: -number

  defp literal!({:%{}, _map_meta, pairs}, meta),
    do: Map.new(pairs, fn {key, value} -> {key_string!(key, meta), literal!(value, meta)} end)

  defp literal!(list, meta) when is_list(list), do: Enum.map(list, &literal!(&1, meta))

  defp literal!({:__block__, _block_meta, [value]}, meta), do: literal!(value, meta)

  defp literal!(ast, meta),
    do:
      fail!(
        meta,
        "#{describe(ast)} is not a literal; only strings, numbers, booleans, nil, lists and maps are allowed"
      )

  defp key_string!(key, _meta) when is_binary(key), do: key
  defp key_string!({:troupe_atom, key}, _meta), do: key

  defp key_string!(key, meta),
    do: fail!(meta, "object keys must be atoms or strings, got #{describe(key)}")

  defp string!(value, _meta) when is_binary(value), do: value
  defp string!(value, meta), do: fail!(meta, "expected a string, got #{describe(value)}")

  defp name!({:troupe_atom, name}, _meta), do: name
  defp name!(name, _meta) when is_binary(name), do: name

  defp name!(value, meta),
    do: fail!(meta, "expected a name such as :shout, got #{describe(value)}")

  # -- AST helpers ------------------------------------------------------------

  defp statements({:__block__, _meta, forms}), do: forms
  defp statements(nil), do: []
  defp statements(form), do: [form]

  defp name?(name, expected), do: name_string(name) == expected

  defp name_string({:troupe_atom, name}), do: name
  defp name_string(name) when is_atom(name), do: Atom.to_string(name)
  defp name_string(_other), do: nil

  defp meta({_name, meta, _args}) when is_list(meta), do: meta
  defp meta(_form), do: [line: 1]

  defp line(meta), do: Keyword.get(meta, :line, 1)

  defp describe({{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, function]}, _meta, _args}),
    do:
      "the call `#{Enum.map_join(parts, ".", &name_string/1)}.#{name_string(function)}(...)` (source is never evaluated)"

  defp describe({{:., _dot_meta, _target}, _meta, _args}),
    do: "a remote call (source is never evaluated)"

  defp describe({name, _meta, args}) when is_list(args) do
    case name_string(name) do
      nil -> "this expression"
      call -> "`#{call}(...)`"
    end
  end

  defp describe({:troupe_atom, name}), do: ":#{name}"

  defp describe({name, _meta, context}) when is_atom(context),
    do: "the variable `#{name_string(name)}`"

  defp describe(value) when is_binary(value), do: inspect(value)

  defp describe(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: inspect(value)

  defp describe(value) when is_list(value), do: "a list"
  defp describe(_value), do: "this expression"

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  # -- rendering --------------------------------------------------------------

  @locals_without_parens [
    id: 1,
    version: 1,
    description: 1,
    inputs: 1,
    output: 1,
    action: 3,
    action: 4,
    arg: 2,
    max_attempts: 1,
    branch: 1,
    branch: 2,
    on: 1,
    match: 1,
    match: 2,
    default: 1,
    loop: 1,
    loop: 2,
    max_iterations: 1,
    state: 1,
    next_state: 1,
    until: 1
  ]

  @doc "Formatter `locals_without_parens` for the DSL."
  @spec locals_without_parens() :: keyword()
  def locals_without_parens, do: @locals_without_parens

  @doc """
  Renders a definition as formatted DSL source (a bare `workflow do ... end`
  block). `parse(to_source(definition))` returns `{:ok, definition}`.
  """
  @spec to_source(Definition.t()) :: String.t()
  def to_source(%Definition{} = definition) do
    header =
      [
        ["id ", inspect(definition.id)],
        ["version ", inspect(definition.version)],
        definition.description && ["description ", inspect(definition.description)],
        definition.inputs != [] && ["inputs ", inputs_source(definition.inputs)],
        ["output ", expr_source(definition.output)]
      ]
      |> Enum.filter(& &1)

    body = Enum.map(definition.nodes, &node_source/1)

    [
      "workflow do\n",
      Enum.intersperse(header, "\n"),
      "\n\n",
      Enum.intersperse(body, "\n\n"),
      "\nend\n"
    ]
    |> IO.iodata_to_binary()
    |> Code.format_string!(locals_without_parens: @locals_without_parens)
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp inputs_source(inputs), do: Enum.map_join(inputs, ", ", &input_source/1)

  defp input_source(input) do
    options =
      [
        {"type", ":#{input.type}"},
        input.default != nil && {"default", literal_source(input.default)},
        (not input.required and input.default == nil) && {"required", "false"},
        input.description && {"description", inspect(input.description)}
      ]
      |> Enum.filter(& &1)

    case options do
      [{"type", type}] -> "#{key_source(input.name)} #{type}"
      options -> "#{key_source(input.name)} [#{Enum.map_join(options, ", ", &option_source/1)}]"
    end
  end

  defp option_source({key, value}), do: "#{key}: #{value}"

  defp node_source(%Action{} = action) do
    options =
      [
        action.max_attempts != 1 && "max_attempts #{action.max_attempts}",
        action.description && "description #{inspect(action.description)}"
      ]
      |> Enum.filter(& &1)

    args =
      action.args
      |> Enum.sort()
      |> Enum.map(fn {key, expr} -> "arg #{atom_source(key)}, #{expr_source(expr)}" end)

    [
      "action #{atom_source(action.id)}, #{inspect(action.capability.name)}, #{inspect(action.capability.version)} do\n",
      Enum.intersperse(options ++ args, "\n"),
      "\nend"
    ]
  end

  defp node_source(%Branch{} = branch) do
    options = [
      branch.description && "description #{inspect(branch.description)}",
      "on #{expr_source(branch.on)}"
    ]

    cases = Enum.map(branch.cases, &case_source(&1, "match #{literal_source(&1.match)}"))
    default = if branch.default, do: [case_source(branch.default, "default")], else: []

    [
      "branch #{atom_source(branch.id)} do\n",
      Enum.intersperse(Enum.filter(options, & &1) ++ cases ++ default, "\n\n"),
      "\nend"
    ]
  end

  defp node_source(%Loop{} = loop) do
    options =
      [
        loop.description && "description #{inspect(loop.description)}",
        "max_iterations #{loop.max_iterations}",
        "state #{expr_source(loop.state)}",
        "next_state #{expr_source(loop.next_state)}",
        loop.until && "until #{expr_source(loop.until)}"
      ]
      |> Enum.filter(& &1)

    [
      "loop #{atom_source(loop.id)} do\n",
      Enum.intersperse(options, "\n"),
      "\n\n",
      Enum.intersperse(Enum.map(loop.nodes, &node_source/1), "\n\n"),
      "\nend"
    ]
  end

  defp case_source(%Case{} = branch_case, opener) do
    nodes = Enum.map(branch_case.nodes, &node_source/1)

    [
      opener,
      " do\n",
      "output #{expr_source(branch_case.output)}",
      Enum.map(nodes, &["\n\n", &1]),
      "\nend"
    ]
  end

  defp expr_source({:input, name, path}), do: call_source("input", [atom_source(name)], path)
  defp expr_source({:result, id, path}), do: call_source("result", [atom_source(id)], path)

  defp expr_source({:loop, :state, of, path}),
    do: call_source("loop_state", [atom_source(of)], path)

  defp expr_source({:loop, :index, of, _path}), do: "loop_index(#{atom_source(of)})"
  defp expr_source({:secret, name}), do: "secret(#{inspect(name)})"
  defp expr_source({:value, value}), do: "value(#{literal_source(value)})"

  defp expr_source({:object, fields}) do
    fields = Enum.sort(fields)

    if Enum.all?(fields, fn {key, _expr} -> identifier?(key) end),
      do:
        "object(" <>
          Enum.map_join(fields, ", ", fn {key, expr} -> "#{key}: #{expr_source(expr)}" end) <> ")",
      else:
        "object(%{" <>
          Enum.map_join(fields, ", ", fn {key, expr} ->
            "#{inspect(key)} => #{expr_source(expr)}"
          end) <> "})"
  end

  defp expr_source({:list, items}),
    do: "list([" <> Enum.map_join(items, ", ", &expr_source/1) <> "])"

  defp call_source(name, args, []), do: "#{name}(#{Enum.join(args, ", ")})"

  defp call_source(name, args, path) do
    segments =
      Enum.map_join(path, ", ", fn segment ->
        if is_integer(segment), do: "#{segment}", else: atom_source(segment)
      end)

    "#{name}(#{Enum.join(args, ", ")}, [#{segments}])"
  end

  # Literals keep string keys so they render back to the same plain data.
  defp literal_source(value) when is_map(value),
    do:
      "%{" <>
        Enum.map_join(Enum.sort(value), ", ", fn {key, item} ->
          "#{inspect(key)} => #{literal_source(item)}"
        end) <> "}"

  defp literal_source(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ", ", &literal_source/1) <> "]"

  defp literal_source(value), do: inspect(value)

  defp atom_source(name), do: if(identifier?(name), do: ":" <> name, else: ":" <> inspect(name))
  defp key_source(name), do: if(identifier?(name), do: name <> ":", else: inspect(name) <> ":")

  defp identifier?(name), do: Regex.match?(~r/^[a-z_][a-zA-Z0-9_]*$/, name)

  @doc false
  @spec expr_to_source(Expr.t()) :: String.t()
  def expr_to_source(expr), do: expr_source(expr)
end
