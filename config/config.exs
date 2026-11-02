import Config
config :spark, formatter: [remove_parens?: true]

# Browser build (playground/build.sh). Reactor checks step behaviours through
# module attributes, so BEAM attribute chunks must not be stripped.
config :popcorn, strip: false
