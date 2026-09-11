# Sensitive memories and access control

Access control is opt-in per repo. Protected repos use embedded Cedar policies through the optional `ex_cedar` dependency. The default policy requires repo membership and a matching memory audience. Applications may replace the audience policy, but cannot bypass repo membership or the requirement for a valid audience.

## Trust boundary

Your application authenticates callers and constructs the `authorization:` map from current, trusted membership data. Never forward a user or agent's claimed repo/group membership directly. An agent acting for a user should receive only the permissions your application delegates to it.

Repo lifecycle/configuration, backend access, adapters, telemetry handlers, and notifier callbacks are trusted operator interfaces. This is an application-level authorization boundary, not a sandbox against arbitrary code running in the same BEAM VM or someone reading backend files. Do not expose lifecycle operations or broadcast raw notifier events to tenants. Ingestion and maintenance use the operator-configured LLM/embedding providers, which must be approved to process sensitive data.

Keep the access-control configuration on **every reopen** of a protected repo. Policies are compiled at startup, not persisted with the graph. Supply refreshed membership on each call; an in-flight recall uses the authorization snapshot supplied when it started. There is no cross-request authorization cache.

## Enable a repo

Add the optional adapter to the consuming application's dependencies:

```elixir
{:ex_cedar, "~> 0.1.2"}
```

Open the repo with the built-in policy:

```elixir
{:ok, _pid} =
  Mnemosyne.open_repo("payments-service",
    backend: {Mnemosyne.GraphBackends.InMemory, []},
    access_control: [policy: :membership_and_audience]
  )
```

Omitting `access_control` or setting it to `false` preserves the existing behavior for unlabeled repos. A repo containing labeled memories refuses to open without access control, preventing accidental exposure when that option is omitted. Supplying an audience to ingestion without enabling access control is rejected, rather than appearing to store a protected memory in an unrestricted repo.

## Audiences and trusted membership

An audience is either:

- `:repo`: all members of that repo.
- A nonempty list of `{organization_id, group_id}` tuples. Reads require membership in **any** listed group, in addition to repo membership. Group order and duplicates do not change the audience.

The default ingestion policy requires membership in **all** listed groups, so a writer cannot publish into another group's audience merely by also including their own. Any repo member can ingest repo-wide memories. The application is responsible for choosing an appropriate classification for the content; Cedar does not inspect text for secrets.

```elixir
authorization = %{
  principal: "user-42",
  repos: ["payments-service"],
  groups: [{"acme", "security"}]
}

trajectory = %Mnemosyne.Trajectory{
  source_id: "investigation-42",
  goal: "Investigate an authorization failure",
  audience: [{"acme", "security"}],
  steps: [
    %{observation: "The request failed authorization", action: "Inspect the policy"}
  ]
}

{:ok, receipt} =
  Mnemosyne.ingest("payments-service", trajectory, authorization: authorization)

{:ok, result} =
  Mnemosyne.recall("payments-service", "What caused the failure?",
    authorization: authorization
  )
```

Every protected ingestion needs an explicit audience. Authorization happens before extraction or joining an existing ingestion. The canonical audience participates in payload identity: changing it while reusing a source ID conflicts. Unlabeled trajectories retain the original fingerprint format for backward compatibility.

All generated node types, including routing tags/intents and provenance sources, inherit the trajectory's audience in `Mnemosyne.NodeMetadata`. Audiences are immutable once assigned. There is no relabeling, publishing, or per-step audience API.

## Protected reads

Pass the same `authorization:` option to:

- `recall/3`
- `latest/3`
- `get_node/3`
- `get_nodes_by_type/3`
- `get_linked_nodes/3`
- `get_metadata/3`

Missing/invalid identity or missing repo membership returns an `AccessError`. For a valid member, inaccessible nodes behave as absent: a single-node read returns `{:ok, nil}`, lists omit them, and metadata contains only accessible IDs. Returned node links omit inaccessible targets.

Recall builds an authorized graph snapshot **before** ranking and top-k selection. Hop control, refinement, provenance expansion, reasoning, touched nodes, and returned traces operate only on that snapshot. A hidden high-scoring node cannot displace an authorized candidate.

`get_graph/2` is disabled on protected repos, even with authorization. Raw `apply_changeset/3` and `delete_nodes/3` are also disabled there, preventing low-level mutation from bypassing the ingestion and immutable-audience boundary. These APIs retain their previous behavior for unrestricted repos.

## Custom Cedar policies

Use a policy source string instead of the built-in policy name:

```elixir
policy = """
permit(
  principal == Mnemosyne::User::"memory-service",
  action,
  resource
) when { resource.shared };
"""

{:ok, _pid} =
  Mnemosyne.open_repo("service-owned-memories",
    backend: {Mnemosyne.GraphBackends.InMemory, []},
    access_control: [policy: policy]
  )
```

This example permits that principal to read and ingest repo-wide memories, provided it is also a repo member. It does not permit group-restricted memories. Custom policies **replace**, rather than extend, the built-in rules. Include an `ingest` permit if writes should be allowed.

The fixed Cedar schema exposes:

| Entity | Attributes |
|---|---|
| `Mnemosyne::User` | `repos: Set<String>`, `groups: Set<String>` |
| `Mnemosyne::Memory` | `repo: String`, `shared: Bool`, `audience: Set<String>`, `node_type: String` |

Actions are `Mnemosyne::Action::"read"` and `Mnemosyne::Action::"ingest"`. All memory reads use `read`; ingestion uses node type `"trajectory"`. Request context is empty. The existing recall `context:` remains transient task context and is never authorization evidence.

Group IDs in Cedar are JSON encodings of `[organization_id, group_id]`; default rules compare these sets with `containsAny` and `containsAll`.

Cedar memory entity IDs identify `{repo, audience, node_type}`, **not actual graph node IDs**. Same-type memories with the same audience must authorize identically, allowing consolidation without changing their readership. Custom policies cannot implement individual-node exceptions through a graph node ID. See `Mnemosyne.AccessControl` for the exact scope-ID encoding.

Policies are compiled and schema-validated at repo startup. Invalid policies prevent opening the repo. Missing or malformed node audiences are denied even by a custom permit-all policy. Evaluation diagnostics and adapter failures fail closed, including when another Cedar policy otherwise permits the request.

## Legacy memories

Enabling access control hides existing nodes without an audience. To make a reviewed legacy corpus available, a trusted operator may explicitly classify **all currently unlabeled nodes** when opening the repo:

```elixir
{:ok, _pid} =
  Mnemosyne.open_repo("legacy-project",
    backend:
      {Mnemosyne.GraphBackends.InMemory,
       persistence: {Mnemosyne.GraphBackends.Persistence.DETS, path: "legacy.dets"}},
    access_control: [policy: :membership_and_audience],
    legacy_audience: [{"acme", "security"}]
  )
```

This is a first assignment, not relabeling. Already assigned audiences are untouched. Review the entire unclassified corpus before choosing an audience, since historical extraction may have combined information from multiple sources. Remove the migration option after the intended startup. It does not rewrite historical ingestion fingerprints or receipts.

## Maintenance and backends

Protected maintenance calls require trusted repo membership via `authorization:`. They are repo-wide operator operations; keep them behind an application administration boundary. Tag/intent deduplication uses the exact ingestion audience, and semantic consolidation selects pairs only within identical audiences. Unclassified semantic nodes are not merged in protected repos.

Protected maintenance and graph commits do not overlap. A maintenance request returns `AccessError` with reason `:maintenance_busy` when another maintenance task, write, or ingestion is active. An ingestion started during maintenance can extract concurrently, but its commit waits until maintenance finishes. Unrestricted repos retain their existing lane behavior.

Audiences persist with node metadata, including through DETS restarts. Custom backends must preserve `NodeMetadata.audience` during usage updates and merges, reject changes to an assigned audience, and persist ingestion metadata and receipts according to the existing commit contract. Legacy metadata without the field is treated as unclassified.

The initial implementation enumerates built-in node types through `get_nodes_by_type/2` and materializes a read-only `InMemory` snapshot, using the configured value function for ranking. It does not use a custom backend's native candidate search for protected reads. This costs O(nodes + edges) graph work per view, plus Cedar evaluations, and intentionally avoids a new backend callback protocol. Large or remote backends will need equivalent authorization-aware query support before using this path at scale.
