defmodule Mnemosyne.MixProject do
  use Mix.Project

  def project do
    [
      app: :mnemosyne,
      description: description(),
      package: package(),
      version: "0.1.3",
      elixir: "~> 1.19",
      docs: docs(),
      dialyzer: [
        plt_core_path: "_plts/core"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Mnemosyne.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.post": :test,
        "coveralls.github": :test,
        "coveralls.html": :test,
        "test.integration": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8", only: :dev, runtime: false},
      {:bumblebee, "~> 0.6", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: :dev},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:exla, "~> 0.10", only: [:dev, :test]},
      {:emlx, "~> 0.2", only: [:dev, :test]},
      {:gen_state_machine, "~> 3.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:assert_eventually, "~> 1.0", only: :test},
      {:mimic, "~> 2.0", only: :test},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:recode, "~> 0.8", only: [:dev], runtime: false},
      {:scholar, "~> 0.4"},
      {:splode, "~> 0.3"},
      {:sycophant, "~> 0.1", optional: true},
      {:telemetry, "~> 1.3"},
      {:tidewave, "~> 0.5", only: :dev, runtime: false},
      {:typedstruct, "~> 0.5"},
      {:zoi, "~> 0.11"},
      {:zoi_defstruct, "~> 0.2"}
    ]
  end

  defp aliases do
    [
      "test.integration": ["test --only integration"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/edlontech/mnemosyne",
      extras: [
        {"README.md", title: "Overview"},
        {"guides/getting-started.md", title: "Getting Started"},
        {"guides/core-concepts.md", title: "Core Concepts"},
        {"guides/sessions-and-episodes.md", title: "Sessions and Episodes"},
        {"guides/retrieval-and-recall.md", title: "Retrieval and Recall"},
        {"guides/graph-maintenance.md", title: "Graph Maintenance"},
        {"guides/custom-backends.md", title: "Custom Backends"},
        {"guides/custom-adapters.md", title: "Custom Adapters"},
        {"guides/multi-repo.md", title: "Multi-Repository Isolation"},
        {"guides/notifier.md", title: "Notifier -- Real-Time Events"},
        {"LICENSE", title: "License"}
      ],
      groups_for_extras: [
        Guides: [
          "guides/getting-started.md",
          "guides/core-concepts.md",
          "guides/sessions-and-episodes.md",
          "guides/retrieval-and-recall.md",
          "guides/graph-maintenance.md",
          "guides/custom-backends.md",
          "guides/custom-adapters.md",
          "guides/multi-repo.md",
          "guides/notifier.md"
        ],
        About: [
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        "Public API": [
          Mnemosyne,
          Mnemosyne.Config
        ],
        Sessions: [
          Mnemosyne.Session
        ],
        "Graph & Nodes": [
          Mnemosyne.Graph,
          Mnemosyne.Graph.Changeset,
          Mnemosyne.Graph.Similarity,
          ~r/Mnemosyne\.Graph\.Node/
        ],
        "Graph Backends": [
          Mnemosyne.GraphBackend,
          ~r/Mnemosyne\.GraphBackends\./
        ],
        Pipeline: [
          Mnemosyne.Pipeline.Episode,
          Mnemosyne.Pipeline.Structuring,
          Mnemosyne.Pipeline.Retrieval,
          Mnemosyne.Pipeline.Reasoning,
          Mnemosyne.Pipeline.IntentMerger,
          Mnemosyne.Pipeline.SemanticConsolidator,
          Mnemosyne.Pipeline.Decay
        ],
        Behaviours: [
          Mnemosyne.LLM,
          Mnemosyne.Embedding,
          Mnemosyne.ValueFunction,
          Mnemosyne.Prompt,
          Mnemosyne.Notifier,
          Mnemosyne.Notifier.Noop
        ],
        Adapters: [
          ~r/Mnemosyne\.Adapters\./
        ],
        Infrastructure: [
          Mnemosyne.Supervisor,
          Mnemosyne.MemoryStore,
          Mnemosyne.NodeMetadata,
          Mnemosyne.Telemetry
        ],
        Errors: [
          Mnemosyne.Errors,
          ~r/Mnemosyne\.Errors\./
        ]
      ],
      nest_modules_by_prefix: [
        Mnemosyne.Errors,
        Mnemosyne.Graph.Node,
        Mnemosyne.GraphBackends,
        Mnemosyne.Adapters,
        Mnemosyne.Pipeline.Prompts
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description() do
    "A Pluggable, extensible, and performant agentic memory library for Elixir applications."
  end

  defp package() do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/edlontech/mnemosyne"},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end
end
