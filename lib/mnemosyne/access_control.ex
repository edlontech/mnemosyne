defmodule Mnemosyne.AccessControl do
  @moduledoc """
  Embedded Cedar authorization for repository-scoped memory access.

  Cedar memory entity UIDs identify authorization scope rather than an actual
  memory node. The UID ID is a JSON array of repository ID, audience scope,
  and node type. Audience scope is `["repo"]` or
  `["groups", encoded_group_id, ...]`, where each group ID is itself the JSON
  encoding of `[organization, group]`. Consequently, same-type memories in
  the same repository and audience always evaluate identically.
  """

  alias Mnemosyne.Errors.Invalid.AccessError

  @schema """
  namespace Mnemosyne {
    entity User = { repos: Set<String>, groups: Set<String> };
    entity Memory = { repo: String, shared: Bool, audience: Set<String>, node_type: String };
    action "read" appliesTo { principal: [User], resource: [Memory], context: {} };
    action "ingest" appliesTo { principal: [User], resource: [Memory], context: {} };
  }
  """

  @default_policy """
  permit(
    principal is Mnemosyne::User,
    action == Mnemosyne::Action::"read",
    resource is Mnemosyne::Memory
  ) when {
    resource.shared || principal.groups.containsAny(resource.audience)
  };

  permit(
    principal is Mnemosyne::User,
    action == Mnemosyne::Action::"ingest",
    resource is Mnemosyne::Memory
  ) when {
    resource.shared || principal.groups.containsAll(resource.audience)
  };
  """

  @required_modules [
    ExCedar.Authorizer,
    ExCedar.Entities,
    ExCedar.Entity,
    ExCedar.EntityUid,
    ExCedar.PolicySet,
    ExCedar.Request,
    ExCedar.Schema,
    ExCedar.Validator
  ]

  @compile {:no_warn_undefined, @required_modules}

  @enforce_keys [:policy_set, :schema]
  defstruct [:policy_set, :schema]

  @type t :: %__MODULE__{policy_set: reference(), schema: reference()}
  @type audience :: :repo | [{String.t(), String.t()}]

  @doc "Compiles and validates a default or custom policy; nil and false disable authorization."
  @spec new(nil | false | keyword()) :: {:ok, nil | t()} | {:error, AccessError.t()}
  def new(config)
  def new(nil), do: {:ok, nil}
  def new(false), do: {:ok, nil}

  def new(config) when is_list(config) do
    with {:ok, source} <- policy_source(config),
         :ok <- dependency_available(),
         {:ok, schema} <-
           safe_call(fn -> ExCedar.Schema.compile(@schema) end, :schema_compile_failed),
         {:ok, policy_set} <-
           safe_call(fn -> ExCedar.PolicySet.compile(source) end, :policy_compile_failed),
         {:ok, %{validated?: true}} <- validate_policy(policy_set, schema) do
      {:ok, %__MODULE__{policy_set: policy_set, schema: schema}}
    end
  end

  def new(_config), do: error(:invalid_config)

  @doc "Checks trusted repository membership independently of the configured Cedar policy."
  @spec member(t() | nil, map() | nil, String.t()) :: :ok | {:error, AccessError.t()}
  def member(nil, _auth, _repo_id), do: :ok

  def member(config, auth, repo_id) do
    with {:ok, _auth} <- validate_membership(config, auth, repo_id), do: :ok
  end

  @doc "Decides scope access, returning false for a denied audience and errors for evaluation failures."
  @spec allowed?(t() | nil, map() | nil, String.t(), atom(), map()) ::
          {:ok, boolean()} | {:error, AccessError.t()}
  def allowed?(nil, _auth, _repo_id, _action, _resource), do: {:ok, true}

  def allowed?(config, auth, repo_id, action, resource) do
    with {:ok, auth} <- validate_membership(config, auth, repo_id),
         :ok <- validate_action(action),
         {:ok, resource} <- validate_resource(resource) do
      case resource do
        :deny -> {:ok, false}
        attributes -> cedar_allowed?(config, auth, repo_id, action, attributes)
      end
    end
  end

  @doc "Requires an allowed decision, returning an AccessError on denial or evaluation failure."
  @spec authorize(t() | nil, map() | nil, String.t(), atom(), map()) ::
          :ok | {:error, AccessError.t()}
  def authorize(config, auth, repo_id, action, resource) do
    case allowed?(config, auth, repo_id, action, resource) do
      {:ok, true} -> :ok
      {:ok, false} -> error(:forbidden)
      {:error, %AccessError{}} = failure -> failure
    end
  end

  @doc "Validates and canonicalizes a repo-wide or organization-qualified group audience."
  @spec normalize_audience(term()) :: {:ok, audience()} | {:error, AccessError.t()}
  def normalize_audience(:repo), do: {:ok, :repo}

  def normalize_audience(groups) when is_list(groups) and groups != [] do
    if proper_group_list?(groups) do
      {:ok, groups |> Enum.uniq() |> Enum.sort()}
    else
      error(:invalid_audience)
    end
  end

  def normalize_audience(_audience), do: error(:invalid_audience)

  defp policy_source(config) do
    if valid_policy_options?(config),
      do: normalize_policy(Keyword.get(config, :policy, :membership_and_audience)),
      else: error(:invalid_config)
  end

  defp valid_policy_options?(config) do
    Keyword.keyword?(config) and Enum.all?(config, fn {key, _value} -> key == :policy end) and
      length(Keyword.get_values(config, :policy)) <= 1
  end

  defp normalize_policy(:membership_and_audience), do: {:ok, @default_policy}

  defp normalize_policy(source) when is_binary(source) do
    if nonblank?(source), do: {:ok, source}, else: error(:invalid_config)
  end

  defp normalize_policy(_invalid), do: error(:invalid_config)

  defp dependency_available do
    if Enum.all?(@required_modules, &Code.ensure_loaded?/1),
      do: :ok,
      else: error(:dependency_unavailable)
  end

  defp validate_membership(
         %__MODULE__{policy_set: policy_set, schema: schema},
         auth,
         repo_id
       )
       when is_reference(policy_set) and is_reference(schema) do
    with :ok <- validate_nonblank(repo_id, :invalid_repo_id),
         {:ok, auth} <- validate_auth(auth) do
      if repo_id in auth.repos, do: {:ok, auth}, else: error(:not_repo_member)
    end
  end

  defp validate_membership(_config, _auth, _repo_id), do: error(:invalid_config)

  defp validate_auth(auth) when is_map(auth) do
    with {:ok, principal} <- Map.fetch(auth, :principal),
         true <- nonblank?(principal),
         {:ok, repos} <- Map.fetch(auth, :repos),
         true <- proper_nonblank_list?(repos),
         groups <- Map.get(auth, :groups, []),
         true <- proper_group_list?(groups) do
      {:ok,
       %{
         principal: principal,
         repos: Enum.uniq(repos),
         groups: Enum.uniq(groups)
       }}
    else
      _invalid -> error(:invalid_auth)
    end
  end

  defp validate_auth(_auth), do: error(:invalid_auth)

  defp validate_action(action) when action in [:read, :ingest], do: :ok
  defp validate_action(_action), do: error(:invalid_action)

  defp validate_resource(%{id: id, node_type: node_type} = resource)
       when is_atom(node_type) and not is_nil(node_type) do
    with :ok <- validate_nonblank(id, :invalid_resource) do
      resource_attributes(id, node_type, Map.get(resource, :audience))
    end
  end

  defp validate_resource(_resource), do: error(:invalid_resource)

  defp resource_attributes(id, node_type, :repo) do
    {:ok, %{id: id, shared: true, audience: [], node_type: Atom.to_string(node_type)}}
  end

  defp resource_attributes(id, node_type, audience) when is_list(audience) do
    case normalize_audience(audience) do
      {:ok, ^audience} ->
        {:ok,
         %{
           id: id,
           shared: false,
           audience: Enum.map(audience, &encode_group/1),
           node_type: Atom.to_string(node_type)
         }}

      _invalid ->
        {:ok, :deny}
    end
  end

  defp resource_attributes(_id, _node_type, _audience), do: {:ok, :deny}

  defp cedar_allowed?(config, auth, repo_id, action, resource) do
    resource_uid = resource_uid(repo_id, resource)

    with {:ok, entities} <- build_entities(auth, repo_id, resource_uid, resource),
         {:ok, decision} <-
           authorize_cedar(config, auth.principal, action, resource_uid, entities) do
      case decision do
        %{errors: [], decision: :allow} -> {:ok, true}
        %{errors: [], decision: :deny} -> {:ok, false}
        %{errors: [_ | _]} -> error(:evaluation_failed)
        _invalid -> error(:authorization_failed)
      end
    end
  end

  defp build_entities(auth, repo_id, resource_uid, resource) do
    safe_call(
      fn ->
        user =
          struct(ExCedar.Entity,
            uid: ExCedar.EntityUid.new("Mnemosyne::User", auth.principal),
            attributes: %{
              "repos" => auth.repos,
              "groups" => Enum.map(auth.groups, &encode_group/1)
            },
            parents: []
          )

        memory =
          struct(ExCedar.Entity,
            uid: ExCedar.EntityUid.new("Mnemosyne::Memory", resource_uid),
            attributes: %{
              "repo" => repo_id,
              "shared" => resource.shared,
              "audience" => resource.audience,
              "node_type" => resource.node_type
            },
            parents: []
          )

        ExCedar.Entities.from_list([user, memory])
      end,
      :authorization_failed
    )
  end

  defp resource_uid(repo_id, resource) do
    audience_scope =
      if resource.shared,
        do: ["repo"],
        else: ["groups" | resource.audience]

    JSON.encode!([repo_id, audience_scope, resource.node_type])
  end

  defp authorize_cedar(config, principal, action, resource_uid, entities) do
    safe_call(
      fn ->
        request =
          struct(ExCedar.Request,
            principal: ExCedar.EntityUid.new("Mnemosyne::User", principal),
            action: ExCedar.EntityUid.new("Mnemosyne::Action", Atom.to_string(action)),
            resource: ExCedar.EntityUid.new("Mnemosyne::Memory", resource_uid),
            context: %{}
          )

        ExCedar.Authorizer.authorize(
          config.policy_set,
          entities,
          request,
          schema: config.schema
        )
      end,
      :authorization_failed
    )
  end

  defp validate_policy(policy_set, schema) do
    case safe_call(
           fn -> ExCedar.Validator.validate(policy_set, schema) end,
           :policy_validation_failed
         ) do
      {:ok, %{validated?: true}} = valid -> valid
      _invalid -> error(:policy_validation_failed)
    end
  end

  defp safe_call(fun, reason) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      {:error, _error} -> error(reason)
    end
  rescue
    _exception -> error(reason)
  catch
    _kind, _value -> error(reason)
  end

  defp validate_nonblank(value, reason) do
    if nonblank?(value), do: :ok, else: error(reason)
  end

  defp proper_nonblank_list?([]), do: true
  defp proper_nonblank_list?([value | rest]), do: nonblank?(value) and proper_nonblank_list?(rest)
  defp proper_nonblank_list?(_improper), do: false

  defp encode_group({org, group}), do: JSON.encode!([org, group])

  defp proper_group_list?([]), do: true

  defp proper_group_list?([{org, group} | rest]) do
    nonblank?(org) and nonblank?(group) and proper_group_list?(rest)
  end

  defp proper_group_list?(_improper), do: false

  defp nonblank?(value),
    do: is_binary(value) and String.valid?(value) and String.trim(value) != ""

  defp error(reason), do: {:error, AccessError.exception(reason: reason)}
end
