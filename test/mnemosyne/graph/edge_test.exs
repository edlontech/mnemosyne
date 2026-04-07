defmodule Mnemosyne.Graph.EdgeTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Graph.Edge

  describe "types/0" do
    test "returns all four edge types" do
      types = Edge.types()

      assert :membership in types
      assert :hierarchical in types
      assert :provenance in types
      assert :sibling in types
      assert length(types) == 4
    end
  end

  describe "empty_links/0" do
    test "returns map with four empty MapSets" do
      links = Edge.empty_links()

      assert map_size(links) == 4

      for type <- [:membership, :hierarchical, :provenance, :sibling] do
        assert %MapSet{} = links[type]
        assert MapSet.size(links[type]) == 0
      end
    end
  end
end
