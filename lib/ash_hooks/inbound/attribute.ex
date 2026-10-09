defmodule AshHooks.Inbound.Attribute do
  @moduledoc """
  A typed attribute declared for an inbound webhook envelope or event.
  """

  defstruct [
    :name,
    :type,
    :allow_nil?,
    :default,
    :constraints,
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          type: term(),
          allow_nil?: boolean(),
          default: term(),
          constraints: keyword(),
          __spark_metadata__: term()
        }
end
