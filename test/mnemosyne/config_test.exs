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

  describe "value_function config" do
    test "default config includes value_function with module and params" do
      {:ok, config} = Zoi.parse(Config.t(), @valid_config)

      assert is_map(config.value_function)
      assert config.value_function.module == Mnemosyne.ValueFunction.Default
      assert is_map(config.value_function.params)

      for type <- [:semantic, :procedural, :episodic, :subgoal, :tag, :source, :intent] do
        assert Map.has_key?(config.value_function.params, type),
               "expected value_function.params to have key #{type}"
      end
    end

    test "each node type has the expected default values" do
      {:ok, config} = Zoi.parse(Config.t(), @valid_config)

      semantic = config.value_function.params[:semantic]
      assert semantic.threshold == 0.0
      assert semantic.top_k == 20
      assert semantic.lambda == 0.01
      assert semantic.k == 5
      assert semantic.base_floor == 0.3
      assert semantic.beta == 1.0

      procedural = config.value_function.params[:procedural]
      assert procedural.threshold == 0.8
      assert procedural.top_k == 10

      episodic = config.value_function.params[:episodic]
      assert episodic.threshold == 0.0
      assert episodic.top_k == 30

      subgoal = config.value_function.params[:subgoal]
      assert subgoal.threshold == 0.75
      assert subgoal.top_k == 10

      tag = config.value_function.params[:tag]
      assert tag.threshold == 0.9
      assert tag.top_k == 10

      source = config.value_function.params[:source]
      assert source.threshold == 0.0
      assert source.top_k == 50

      intent = config.value_function.params[:intent]
      assert intent.threshold == 0.7
      assert intent.top_k == 10
    end

    test "partial overrides work" do
      input =
        Map.put(@valid_config, :value_function, %{
          params: %{semantic: %{threshold: 0.5}}
        })

      {:ok, config} = Zoi.parse(Config.t(), input)

      assert config.value_function.params[:semantic].threshold == 0.5
      assert config.value_function.params[:semantic].top_k == 20
      assert config.value_function.params[:semantic].lambda == 0.01
    end

    test "custom module can be specified" do
      input =
        Map.put(@valid_config, :value_function, %{
          module: MyApp.CustomValueFunction
        })

      {:ok, config} = Zoi.parse(Config.t(), input)
      assert config.value_function.module == MyApp.CustomValueFunction
    end
  end

  describe "resolve_value_function/2" do
    test "returns correct params for known node types" do
      {:ok, config} = Zoi.parse(Config.t(), @valid_config)

      params = Config.resolve_value_function(config, :semantic)
      assert params.threshold == 0.0
      assert params.top_k == 20
      assert params.lambda == 0.01
      assert params.k == 5
      assert params.base_floor == 0.3
      assert params.beta == 1.0
    end

    test "returns correct defaults for non-overridden types in a partial params map" do
      input =
        Map.put(@valid_config, :value_function, %{
          params: %{semantic: %{threshold: 0.5}}
        })

      {:ok, config} = Zoi.parse(Config.t(), input)

      params = Config.resolve_value_function(config, :procedural)
      assert params.threshold == 0.8
      assert params.top_k == 10
      assert params.lambda == 0.01
      assert params.k == 5
      assert params.base_floor == 0.3
      assert params.beta == 1.0
    end

    test "returns safe defaults for unknown node types" do
      {:ok, config} = Zoi.parse(Config.t(), @valid_config)

      params = Config.resolve_value_function(config, :unknown_type)
      assert params.threshold == 0.0
      assert params.top_k == 20
      assert params.lambda == 0.01
      assert params.k == 5
      assert params.base_floor == 0.3
      assert params.beta == 1.0
    end
  end
end
