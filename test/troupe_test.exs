defmodule TroupeTest do
  use ExUnit.Case
  doctest Troupe

  test "greets the world" do
    assert Troupe.hello() == :world
  end
end
