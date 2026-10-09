defmodule AshHooks.Inbound.Event do
  @moduledoc """
  A typed inbound event declaration.

  Event attributes are validated with Ash types before the declared action is
  invoked. The event name is derived from its wire type, so the type is only
  written once in the DSL.
  """

  defstruct [
    :name,
    :type,
    :action,
    :record,
    attributes: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          type: String.t(),
          action: atom() | {module(), atom()},
          record: atom() | nil,
          attributes: [AshHooks.Inbound.Attribute.t()],
          __spark_metadata__: term()
        }

  @doc false
  def transform(%__MODULE__{type: type} = event) when is_binary(type) do
    name = type |> String.replace(".", "_") |> Macro.underscore() |> String.to_atom()

    {:ok, %{event | name: name}}
  end

  def transform(event), do: {:ok, event}
end
