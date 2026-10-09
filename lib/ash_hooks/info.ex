defmodule AshHooks.Info do
  @moduledoc """
  Accessors for a resource's `webhooks` declarations, read via
  `Spark.Dsl.Extension` (the ash_age pattern — no generated getter in this
  spark version).
  """

  alias Spark.Dsl.Extension

  @doc "All webhook entities (inbound + outbound) declared on `resource`."
  @spec webhooks(Ash.Resource.t()) :: [AshHooks.Inbound.t() | AshHooks.Outbound.t()]
  def webhooks(resource), do: Extension.get_entities(resource, [:webhooks])

  @doc "The inbound declaration for `provider`, if any."
  @spec inbound(Ash.Resource.t(), atom()) :: AshHooks.Inbound.t() | nil
  def inbound(resource, provider) do
    webhooks(resource) |> Enum.find(&(is_struct(&1, AshHooks.Inbound) and &1.name == provider))
  end

  @doc "Returns the typed events declared for an inbound webhook."
  @spec inbound_events(module(), atom()) :: [AshHooks.Inbound.Event.t()]
  def inbound_events(resource, name) do
    case inbound(resource, name) do
      %AshHooks.Inbound{events: events} -> events
      nil -> []
    end
  end

  @doc "Returns the inbound event matching a parsed atom or wire type."
  @spec inbound_event(module(), atom(), atom() | String.t()) :: AshHooks.Inbound.Event.t() | nil
  def inbound_event(resource, name, type) do
    case inbound(resource, name) do
      %AshHooks.Inbound{} = inbound -> AshHooks.Inbound.event(inbound, type)
      nil -> nil
    end
  end

  @doc "The outbound declaration for `event`, if any."
  @spec outbound(Ash.Resource.t(), atom()) :: AshHooks.Outbound.t() | nil
  def outbound(resource, event) do
    webhooks(resource) |> Enum.find(&(is_struct(&1, AshHooks.Outbound) and &1.name == event))
  end

  @doc """
  The configured exact-bytes payload attribute name on an
  `AshHooks.OutboundDelivery` resource (default `:payload`).
  """
  @spec payload_attribute(module()) :: atom()
  def payload_attribute(resource),
    do: Extension.get_opt(resource, [:outbound_delivery], :payload_attribute, :payload)

  @doc """
  Whether the compiled `:dispatch`/`:ingest` action accepts a
  caller-supplied `:id` (the runtimes classify created/duplicate by id
  comparison in that shape; otherwise by an identity pre-read — H2).
  Reads the accept-list transformer's PERSISTED decision, so the runtime
  and the compiled action can never disagree (composite and non-`:id`
  primary keys make a re-derived predicate diverge from the accept list).
  """
  @spec writable_id?(module()) :: boolean()
  def writable_id?(resource),
    do: Extension.get_persisted(resource, :id_accepted?) == true
end
