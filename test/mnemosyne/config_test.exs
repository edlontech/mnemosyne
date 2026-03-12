defmodule Mnemosyne.ConfigTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.Config

  @valid_config %{
    llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
    embedding: %{model: "text-embedding-3-small", opts: %{dimensions: 1536}}
  }

  describe "Zoi parsing" do
    test "parses a valid config with all fields" do
      input =
        Map.put(@valid_config, :overrides, %{
          summarize: %{model: "gpt-4o-mini", opts: %{temperature: 0.3}}
        })

      assert {:ok, %Config{} = config} = Zoi.parse(Config.t(), input)
      assert config.llm.model == "gpt-4o"
      assert config.llm.opts == %{temperature: 0.7}
      assert config.embedding.model == "text-embedding-3-small"
      assert config.embedding.opts == %{dimensions: 1536}
      assert %{summarize: override} = config.overrides
      assert override.model == "gpt-4o-mini"
    end

    test "defaults overrides to empty map" do
      assert {:ok, %Config{} = config} = Zoi.parse(Config.t(), @valid_config)
      assert config.overrides == %{}
    end

    test "defaults opts to empty map when not provided" do
      input = %{
        llm: %{model: "gpt-4o"},
        embedding: %{model: "text-embedding-3-small"}
      }

      assert {:ok, %Config{} = config} = Zoi.parse(Config.t(), input)
      assert config.llm.opts == %{}
      assert config.embedding.opts == %{}
    end

    test "returns error when llm model is missing" do
      input = %{
        llm: %{opts: %{}},
        embedding: %{model: "text-embedding-3-small"}
      }

      assert {:error, _errors} = Zoi.parse(Config.t(), input)
    end

    test "returns error when embedding model is missing" do
      input = %{
        llm: %{model: "gpt-4o"},
        embedding: %{opts: %{}}
      }

      assert {:error, _errors} = Zoi.parse(Config.t(), input)
    end

    test "returns error when llm section is missing entirely" do
      input = %{embedding: %{model: "text-embedding-3-small"}}
      assert {:error, _errors} = Zoi.parse(Config.t(), input)
    end
  end

  describe "resolve/2" do
    setup do
      {:ok, config} =
        Zoi.parse(Config.t(), %{
          llm: %{model: "gpt-4o", opts: %{temperature: 0.7}},
          embedding: %{model: "text-embedding-3-small"},
          overrides: %{
            summarize: %{model: "gpt-4o-mini", opts: %{temperature: 0.3}},
            extract: %{model: "gpt-4o-mini"}
          }
        })

      %{config: config}
    end

    test "returns llm defaults when no override exists", %{config: config} do
      result = Config.resolve(config, :unknown_step)
      assert result == %{model: "gpt-4o", opts: %{temperature: 0.7}}
    end

    test "overrides both model and opts for a step", %{config: config} do
      result = Config.resolve(config, :summarize)
      assert result.model == "gpt-4o-mini"
      assert result.opts == %{temperature: 0.3}
    end

    test "overrides model only, keeping base opts", %{config: config} do
      result = Config.resolve(config, :extract)
      assert result.model == "gpt-4o-mini"
      assert result.opts == %{temperature: 0.7}
    end
  end

  describe "resolve_embedding/1" do
    test "returns embedding model and opts" do
      {:ok, config} = Zoi.parse(Config.t(), @valid_config)
      result = Config.resolve_embedding(config)
      assert result == %{model: "text-embedding-3-small", opts: %{dimensions: 1536}}
    end
  end
end
