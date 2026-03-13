defmodule Mnemosyne.Adapters.BumblebeeEmbeddingTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Adapters.BumblebeeEmbedding
  alias Mnemosyne.Embedding.Response

  describe "embed/2" do
    test "returns response with vector from serving" do
      serving = build_serving([[0.1, 0.2, 0.3]])

      assert {:ok,
              %Response{
                vectors: [v],
                model: "test-model",
                usage: %{}
              }} = BumblebeeEmbedding.embed("hello", serving: serving, model: "test-model")

      assert_in_delta Enum.at(v, 0), 0.1, 0.001
      assert_in_delta Enum.at(v, 1), 0.2, 0.001
      assert_in_delta Enum.at(v, 2), 0.3, 0.001
    end

    test "works without model opt" do
      serving = build_serving([[1.0, 2.0]])

      assert {:ok, %Response{model: nil}} =
               BumblebeeEmbedding.embed("hello", serving: serving)
    end

    test "returns error when serving raises" do
      serving = build_failing_serving()

      assert {:error, %RuntimeError{}} =
               BumblebeeEmbedding.embed("hello", serving: serving)
    end
  end

  describe "embed_batch/2" do
    test "returns response with multiple vectors" do
      serving = build_serving([[0.1, 0.2], [0.3, 0.4]])

      assert {:ok, %Response{vectors: [v1, v2], model: "e5"}} =
               BumblebeeEmbedding.embed_batch(["a", "b"], serving: serving, model: "e5")

      assert_in_delta Enum.at(v1, 0), 0.1, 0.001
      assert_in_delta Enum.at(v2, 0), 0.3, 0.001
    end

    test "handles single item batch" do
      serving = build_serving([[1.0]])

      assert {:ok, %Response{vectors: [_v]}} =
               BumblebeeEmbedding.embed_batch(["a"], serving: serving)
    end
  end

  describe "embed/2 with process-based serving" do
    test "works with a named serving process" do
      serving = build_serving([[0.5, 0.6]])
      name = :"test_serving_#{System.unique_integer([:positive])}"
      start_supervised!({Nx.Serving, serving: serving, name: name})

      assert {:ok, %Response{vectors: [v], model: "proc"}} =
               BumblebeeEmbedding.embed("hello", serving: name, model: "proc")

      assert_in_delta Enum.at(v, 0), 0.5, 0.001
    end
  end

  defp build_serving(expected_vectors) do
    tensor = Nx.tensor(expected_vectors)

    Nx.Serving.new(fn _opts ->
      fn %Nx.Batch{} -> tensor end
    end)
    |> Nx.Serving.client_preprocessing(fn input ->
      texts = List.wrap(input)
      batch = texts |> Enum.map(fn _ -> Nx.tensor([0]) end) |> Nx.Batch.stack()
      {batch, texts}
    end)
    |> Nx.Serving.client_postprocessing(fn {result, _server_info}, texts ->
      texts
      |> Enum.with_index()
      |> Enum.map(fn {_text, i} -> %{embedding: result[i]} end)
    end)
  end

  defp build_failing_serving do
    Nx.Serving.new(fn _opts ->
      fn %Nx.Batch{} -> raise RuntimeError, "serving failed" end
    end)
    |> Nx.Serving.client_preprocessing(fn input ->
      {Nx.Batch.stack([Nx.tensor([0])]), input}
    end)
  end
end
