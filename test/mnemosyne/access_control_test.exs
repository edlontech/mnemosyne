defmodule Mnemosyne.AccessControlTest do
  use ExUnit.Case, async: true

  alias Mnemosyne.AccessControl
  alias Mnemosyne.Errors.Invalid.AccessError

  @permit_all "permit(principal, action, resource);"

  setup do
    {:ok, config} = AccessControl.new([])
    %{config: config}
  end

  test "canonicalizes group audiences without losing organization namespaces" do
    assert {:ok, [{"acme", "security"}, {"other", "security"}]} =
             AccessControl.normalize_audience([
               {"other", "security"},
               {"acme", "security"},
               {"acme", "security"}
             ])

    assert {:ok, :repo} = AccessControl.normalize_audience(:repo)
  end

  test "invalid UTF-8 cannot reach Cedar entity encoding", %{config: config} do
    assert {:error, %AccessError{}} = AccessControl.normalize_audience([{<<255>>, "security"}])

    assert {:error, %AccessError{}} =
             AccessControl.member(config, auth(principal: <<255>>), "repo-1")
  end

  test "rejects invalid audiences" do
    for audience <- [nil, [], [{"", "security"}], [{"acme", " "}], ["security"]] do
      assert {:error, %AccessError{reason: :invalid_audience}} =
               AccessControl.normalize_audience(audience)
    end

    assert {:error, %AccessError{reason: :invalid_audience}} =
             AccessControl.normalize_audience([{"acme", "security"} | :improper])
  end

  test "access control is opt-in and compiles the default policy when enabled" do
    assert {:ok, nil} = AccessControl.new(nil)
    assert {:ok, nil} = AccessControl.new(false)
    assert {:ok, %AccessControl{}} = AccessControl.new([])
    assert {:ok, %AccessControl{}} = AccessControl.new(policy: :membership_and_audience)
  end

  test "validates enabled configuration without exposing Cedar diagnostics" do
    invalid_configs = [
      true,
      [unknown: true],
      [policy: " "],
      [policy: :other],
      [policy: @permit_all, policy: @permit_all]
    ]

    for config <- invalid_configs do
      assert {:error, %AccessError{reason: :invalid_config}} = AccessControl.new(config)
    end

    assert {:error, %AccessError{reason: :policy_compile_failed} = error} =
             AccessControl.new(policy: "not Cedar policy")

    refute Exception.message(error) =~ "not Cedar policy"

    assert {:error, %AccessError{reason: :policy_validation_failed}} =
             AccessControl.new(
               policy: "permit(principal, action, resource) when { resource.unknown_attribute };"
             )
  end

  test "requires repository membership", %{config: config} do
    assert :ok = AccessControl.member(config, auth(), "repo-1")

    assert {:error, %AccessError{reason: :not_repo_member}} =
             AccessControl.member(config, auth(repos: ["repo-2"]), "repo-1")

    assert :ok = AccessControl.member(nil, :unvalidated_when_disabled, nil)
  end

  test "default reads require membership and any matching audience group", %{config: config} do
    resource = resource([{"acme", "platform"}, {"acme", "security"}])

    assert {:ok, true} =
             AccessControl.allowed?(
               config,
               auth(groups: [{"acme", "security"}]),
               "repo-1",
               :read,
               resource
             )

    assert {:ok, false} =
             AccessControl.allowed?(
               config,
               auth(groups: [{"acme", "finance"}]),
               "repo-1",
               :read,
               resource
             )

    assert {:error, %AccessError{reason: :not_repo_member}} =
             AccessControl.allowed?(
               config,
               auth(repos: ["repo-2"], groups: [{"acme", "security"}]),
               "repo-1",
               :read,
               resource
             )
  end

  test "default ingest requires all audience groups while read requires any", %{config: config} do
    resource = resource([{"acme", "platform"}, {"acme", "security"}])
    one_group = auth(groups: [{"acme", "security"}])
    both_groups = auth(groups: [{"acme", "security"}, {"acme", "platform"}])

    assert {:ok, true} = AccessControl.allowed?(config, one_group, "repo-1", :read, resource)
    assert {:ok, false} = AccessControl.allowed?(config, one_group, "repo-1", :ingest, resource)
    assert {:ok, true} = AccessControl.allowed?(config, both_groups, "repo-1", :ingest, resource)
  end

  test "repo audience is available to every repository member", %{config: config} do
    assert {:ok, true} =
             AccessControl.allowed?(config, auth(), "repo-1", :read, resource(:repo))

    assert {:ok, true} =
             AccessControl.allowed?(config, auth(), "repo-1", :ingest, resource(:repo))
  end

  test "group identities are organization-qualified", %{config: config} do
    assert {:ok, false} =
             AccessControl.allowed?(
               config,
               auth(groups: [{"other", "security"}]),
               "repo-1",
               :read,
               resource([{"acme", "security"}])
             )
  end

  test "custom policy replaces the default audience policy" do
    policy = """
    permit(principal, action, resource)
    when {
      action == Mnemosyne::Action::"read" && resource.node_type == "episodic"
    };
    """

    assert {:ok, config} = AccessControl.new(policy: policy)
    user = auth(groups: [{"acme", "security"}])

    assert {:ok, false} =
             AccessControl.allowed?(
               config,
               user,
               "repo-1",
               :read,
               resource([{"acme", "security"}])
             )

    assert {:ok, true} =
             AccessControl.allowed?(
               config,
               user,
               "repo-1",
               :read,
               resource([{"other", "finance"}], :episodic)
             )
  end

  test "forbid overrides permit" do
    policy = """
    permit(principal, action, resource);
    forbid(principal, action, resource)
    when { action == Mnemosyne::Action::"read" };
    """

    assert {:ok, config} = AccessControl.new(policy: policy)
    assert {:ok, false} = AccessControl.allowed?(config, auth(), "repo-1", :read, resource(:repo))

    assert {:ok, true} =
             AccessControl.allowed?(config, auth(), "repo-1", :ingest, resource(:repo))
  end

  test "actual memory IDs cannot distinguish resources in the same authorization scope" do
    policy = """
    permit(principal, action, resource);
    forbid(principal, action, resource)
    when { resource == Mnemosyne::Memory::"memory-2" };
    """

    assert {:ok, config} = AccessControl.new(policy: policy)
    first = resource([{"acme", "security"}])
    second = %{first | id: "memory-2"}

    assert {:ok, true} = AccessControl.allowed?(config, auth(), "repo-1", :read, first)
    assert {:ok, true} = AccessControl.allowed?(config, auth(), "repo-1", :read, second)
  end

  test "custom permit cannot bypass membership or unlabeled-memory checks" do
    assert {:ok, config} = AccessControl.new(policy: @permit_all)

    assert {:error, %AccessError{reason: :not_repo_member}} =
             AccessControl.allowed?(
               config,
               auth(repos: ["repo-2"]),
               "repo-1",
               :read,
               resource(:repo)
             )

    assert {:ok, false} =
             AccessControl.allowed?(config, auth(), "repo-1", :read, resource(nil))

    assert {:ok, false} =
             AccessControl.allowed?(
               config,
               auth(),
               "repo-1",
               :read,
               resource([{"b", "g"}, {"a", "g"}])
             )
  end

  test "evaluation diagnostics fail closed even when another policy permits" do
    policy = """
    permit(principal, action, resource);
    permit(principal, action, resource)
    when { 9223372036854775807 + 1 == 0 };
    """

    assert {:ok, config} = AccessControl.new(policy: policy)

    assert {:error, %AccessError{reason: :evaluation_failed}} =
             AccessControl.allowed?(config, auth(), "repo-1", :read, resource(:repo))
  end

  test "validates auth, repository, action, and resource", %{config: config} do
    assert {:error, %AccessError{reason: :invalid_auth}} =
             AccessControl.member(config, %{principal: "user", repos: :all}, "repo-1")

    assert {:error, %AccessError{reason: :invalid_repo_id}} =
             AccessControl.member(config, auth(), " ")

    assert {:error, %AccessError{reason: :invalid_action}} =
             AccessControl.allowed?(config, auth(), "repo-1", :delete, resource(:repo))

    assert {:error, %AccessError{reason: :invalid_resource}} =
             AccessControl.allowed?(config, auth(), "repo-1", :read, %{audience: :repo})
  end

  test "authorize returns a generic forbidden error and disabled control permits" do
    assert {:ok, true} = AccessControl.allowed?(nil, :anything, nil, :anything, :anything)
    assert :ok = AccessControl.authorize(nil, :anything, nil, :anything, :anything)

    {:ok, config} = AccessControl.new(policy: "forbid(principal, action, resource);")

    assert {:error, %AccessError{reason: :forbidden} = error} =
             AccessControl.authorize(config, auth(), "repo-1", :read, resource(:repo))

    assert Exception.message(error) == "access control error: access forbidden"
  end

  defp auth(overrides \\ []) do
    Map.merge(
      %{principal: "user-1", repos: ["repo-1"], groups: []},
      Map.new(overrides)
    )
  end

  defp resource(audience, node_type \\ :semantic) do
    %{id: "memory-1", audience: audience, node_type: node_type}
  end
end
