defmodule Troupe.Runtime.Compiler do
  @moduledoc """
  Compiles a validated definition into `Reactor` structs.

    * the workflow root (and each loop iteration body) becomes one Reactor
      with a single `:scope` input holding a `Troupe.Runtime.Env`
    * every node becomes a step named by its node id; result references to
      nodes in the same Reactor become Reactor result arguments, so Reactor
      plans and schedules the dependency graph
    * branches emit the chosen case's steps at runtime via
      `Reactor.Step.Switch`; a final step named after the branch replaces it
      and yields the case output
    * loops run each iteration as a separate Reactor run (the
      `Reactor.Step.Recurse` pattern), re-emitting themselves with only a
      small `Troupe.Runtime.Frame`, so finished iterations do not accumulate
      in the outer Reactor's results
  """

  alias Reactor.{Argument, Builder}
  alias Troupe.Definition
  alias Troupe.Definition.{Action, Branch, Case, Loop, Scope}
  alias Troupe.Expr
  alias Troupe.Runtime.{ActionStep, BranchStep, IterationStep, LoopStep, ValueStep}

  @output :__troupe_output__
  @iteration :__troupe_iteration__

  @doc "Reactor for a whole workflow; returns the workflow output."
  @spec workflow(Definition.t()) :: Reactor.t()
  def workflow(%Definition{nodes: nodes, output: output}) do
    local = Scope.reactor_local(nodes)
    build(nodes, local, {@output, {ValueStep, expr: output}, Expr.result_ids(output)})
  end

  @doc "Reactor for one iteration of a loop body; returns `%{state: _, done: _}`."
  @spec iteration(Loop.t()) :: Reactor.t()
  def iteration(%Loop{} = loop) do
    local = Scope.reactor_local(loop.nodes)

    refs =
      [loop.next_state, loop.until] |> Enum.reject(&is_nil/1) |> Enum.flat_map(&Expr.result_ids/1)

    build(loop.nodes, local, {@iteration, {IterationStep, node: loop}, Enum.uniq(refs)})
  end

  defp build(nodes, local, {final_name, {final_impl, final_opts}, final_refs}) do
    {:ok, reactor} = Builder.add_input(Builder.new(), :scope)

    reactor =
      Enum.reduce(nodes, reactor, fn node, reactor ->
        {name, impl, args, opts} = spec(node, local)
        Builder.add_step!(reactor, name, impl, args, opts)
      end)

    {locals, args} = arguments(final_refs, local)

    reactor
    |> Builder.add_step!(final_name, {final_impl, Keyword.put(final_opts, :locals, locals)}, args,
      max_retries: 0
    )
    |> Builder.return!(final_name)
  end

  defp spec(%Action{} = action, local) do
    {locals, args} = arguments(Scope.external_refs(action), local)

    {action.id, {ActionStep, node: action, locals: locals}, args,
     max_retries: action.max_attempts - 1, description: action.description}
  end

  defp spec(%Branch{} = branch, local) do
    {locals, args} = arguments(Scope.external_refs(branch), local)

    matches = Enum.map(branch.cases, &{&1.match, case_steps(&1, branch, local)})
    default = branch.default && case_steps(branch.default, branch, local)

    {branch.id, {BranchStep, node: branch, locals: locals, matches: matches, default: default},
     args, max_retries: 0, description: branch.description}
  end

  defp spec(%Loop{} = loop, local) do
    {locals, args} = arguments(Scope.external_refs(loop), local)

    {loop.id, {LoopStep, node: loop, locals: locals, frame: nil}, args,
     max_retries: 0, description: loop.description}
  end

  # Steps emitted when a case is chosen: its nodes plus a step named after
  # the branch that evaluates the case output and replaces the branch step.
  defp case_steps(%Case{} = branch_case, %Branch{id: branch_id}, local) do
    {locals, args} = arguments(Expr.result_ids(branch_case.output), local)

    output =
      {branch_id, {ValueStep, expr: branch_case.output, locals: locals}, args, max_retries: 0}

    Enum.map(branch_case.nodes, &spec(&1, local)) ++ [output]
  end

  @doc false
  @spec emit({term(), Builder.impl(), [Argument.t()], keyword()}) :: Reactor.Step.t()
  def emit({name, impl, args, opts}) do
    step = Builder.new_step!(name, impl, args, opts)
    %{step | ref: make_ref()}
  end

  # Every step reads the env from the `:scope` input; references to nodes in
  # the same Reactor become result arguments named :r0, :r1, ... (bounded by
  # the definition's node limit).
  defp arguments(refs, local) do
    locals =
      refs
      |> Enum.filter(&MapSet.member?(local, &1))
      |> Enum.with_index()
      |> Enum.map(fn {id, index} -> {id, :"r#{index}"} end)

    args = [
      Argument.from_input(:scope, :scope)
      | Enum.map(locals, fn {id, key} -> Argument.from_result(key, id) end)
    ]

    {locals, args}
  end
end
