defmodule AshHooks.Inbound do
  @moduledoc """
  Configuration for one inbound webhook declaration.

  Values are built by the `AshHooks` DSL and exposed through
  `AshHooks.Info.inbound/2`; applications do not construct this struct
  directly.
  """

  defstruct [
    :name,
    :provider,
    :secret,
    :event_id,
    :identity,
    :route,
    :signature_header,
    :secret_route,
    :secret_resolver,
    :replay_window_seconds,
    attributes: [],
    events: [],
    entities: [],
    __spark_metadata__: nil
  ]

  @typedoc "A compiled inbound webhook declaration."
  @type t :: %__MODULE__{
          name: atom(),
          provider: module() | nil,
          secret: term(),
          event_id: (map() | list() -> term()) | nil,
          identity: atom() | nil,
          route: String.t() | nil,
          signature_header: String.t(),
          secret_route: String.t() | false,
          secret_resolver: term() | nil,
          replay_window_seconds: non_neg_integer() | nil,
          attributes: [AshHooks.Inbound.Attribute.t()],
          events: [AshHooks.Inbound.Event.t()],
          entities: list(),
          __spark_metadata__: term()
        }

  @doc "Returns the event declaration matching a parsed atom or wire type."
  @spec event(t(), atom() | String.t()) :: AshHooks.Inbound.Event.t() | nil
  def event(%__MODULE__{events: events}, type) when is_atom(type),
    do: Enum.find(events, &(&1.name == type))

  def event(%__MODULE__{events: events}, type) when is_binary(type),
    do: Enum.find(events, &(&1.type == type or Atom.to_string(&1.name) == type))

  def event(_inbound, _type), do: nil
end
