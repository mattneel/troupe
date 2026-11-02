# Used by "mix format"
#
# Keep in sync with Troupe.Workflow.Source.locals_without_parens/0
# (test/troupe/source_test.exs checks this).
locals_without_parens = [
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

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:reactor],
  plugins: [Spark.Formatter],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
