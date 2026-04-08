defmodule Mnemosyne.ExtractionProfileTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.ExtractionProfile

  describe "struct construction" do
    test "builds with all fields" do
      profile = %ExtractionProfile{
        name: :test,
        domain_context: "Test domain",
        overlays: %{get_semantic: "semantic overlay"},
        value_function_overrides: %{semantic: %{base_floor: 0.1}}
      }

      assert profile.name == :test
      assert profile.domain_context == "Test domain"
      assert profile.overlays == %{get_semantic: "semantic overlay"}
      assert profile.value_function_overrides == %{semantic: %{base_floor: 0.1}}
    end

    test "defaults overlays to empty map" do
      profile = %ExtractionProfile{name: :minimal}
      assert profile.overlays == %{}
    end

    test "defaults value_function_overrides to empty map" do
      profile = %ExtractionProfile{name: :minimal}
      assert profile.value_function_overrides == %{}
    end

    test "defaults domain_context to nil" do
      profile = %ExtractionProfile{name: :minimal}
      assert profile.domain_context == nil
    end

    test "enforces name field" do
      assert_raise ArgumentError, fn ->
        struct!(ExtractionProfile, %{})
      end
    end
  end

  describe "coding/0" do
    test "returns profile with :coding name" do
      assert %ExtractionProfile{name: :coding} = ExtractionProfile.coding()
    end

    test "has domain_context set" do
      profile = ExtractionProfile.coding()
      assert is_binary(profile.domain_context)
      assert profile.domain_context =~ "Software engineering"
    end

    test "has expected overlay keys" do
      profile = ExtractionProfile.coding()
      assert Map.has_key?(profile.overlays, :get_semantic)
      assert Map.has_key?(profile.overlays, :get_procedural)
      assert Map.has_key?(profile.overlays, :get_reward)
    end

    test "has procedural value_function_overrides" do
      profile = ExtractionProfile.coding()
      assert %{procedural: %{base_floor: 0.15}} = profile.value_function_overrides
    end
  end

  describe "research/0" do
    test "returns profile with :research name" do
      assert %ExtractionProfile{name: :research} = ExtractionProfile.research()
    end

    test "has domain_context set" do
      profile = ExtractionProfile.research()
      assert is_binary(profile.domain_context)
      assert profile.domain_context =~ "Knowledge work"
    end

    test "has expected overlay keys" do
      profile = ExtractionProfile.research()
      assert Map.has_key?(profile.overlays, :get_semantic)
      assert Map.has_key?(profile.overlays, :get_procedural)
      assert Map.has_key?(profile.overlays, :get_reward)
    end

    test "has semantic and procedural value_function_overrides" do
      profile = ExtractionProfile.research()

      assert %{semantic: %{base_floor: 0.15}, procedural: %{base_floor: 0.05}} =
               profile.value_function_overrides
    end
  end

  describe "customer_support/0" do
    test "returns profile with :customer_support name" do
      assert %ExtractionProfile{name: :customer_support} = ExtractionProfile.customer_support()
    end

    test "has domain_context set" do
      profile = ExtractionProfile.customer_support()
      assert is_binary(profile.domain_context)
      assert profile.domain_context =~ "Customer"
    end

    test "has expected overlay keys" do
      profile = ExtractionProfile.customer_support()
      assert Map.has_key?(profile.overlays, :get_semantic)
      assert Map.has_key?(profile.overlays, :get_procedural)
      assert Map.has_key?(profile.overlays, :get_reward)
    end

    test "has procedural value_function_overrides" do
      profile = ExtractionProfile.customer_support()
      assert %{procedural: %{base_floor: 0.12}} = profile.value_function_overrides
    end
  end

  describe "custom profiles" do
    test "can be built with arbitrary overlays" do
      profile = %ExtractionProfile{
        name: :custom,
        domain_context: "Custom domain",
        overlays: %{
          custom_step: "Custom overlay text",
          another_step: "Another overlay"
        },
        value_function_overrides: %{
          semantic: %{threshold: 0.5, top_k: 10}
        }
      }

      assert profile.name == :custom
      assert map_size(profile.overlays) == 2
      assert profile.overlays[:custom_step] == "Custom overlay text"
    end
  end
end
