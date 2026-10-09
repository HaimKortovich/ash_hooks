defmodule AshHooks.Inbound.Validator do
  @moduledoc false

  alias AshHooks.Inbound.{Attribute, Event}

  @spec validate(AshHooks.Inbound.t(), Event.t(), map()) :: {:ok, map()} | {:error, term()}
  def validate(inbound, %Event{} = event, payload) when is_map(payload) do
    attributes = inbound.attributes ++ event.attributes

    Enum.reduce_while(attributes, {:ok, %{}}, fn %Attribute{} = attribute, {:ok, values} ->
      case value_for(payload, attribute.name) do
        :missing ->
          missing(attribute, values)

        {:present, nil} when attribute.allow_nil? ->
          {:cont, {:ok, Map.put(values, attribute.name, nil)}}

        {:present, nil} ->
          {:halt, {:error, invalid(attribute, "must not be nil")}}

        {:present, value} ->
          case cast(attribute, value) do
            {:ok, cast} -> {:cont, {:ok, Map.put(values, attribute.name, cast)}}
            {:error, reason} -> {:halt, {:error, invalid(attribute, reason)}}
          end
      end
    end)
  end

  def validate(_inbound, _event, _payload), do: {:error, :malformed_payload}

  defp value_for(payload, name) do
    cond do
      Map.has_key?(payload, name) ->
        {:present, Map.fetch!(payload, name)}

      Map.has_key?(payload, Atom.to_string(name)) ->
        {:present, Map.fetch!(payload, Atom.to_string(name))}

      true ->
        :missing
    end
  end

  defp missing(%Attribute{default: default} = attribute, values) when not is_nil(default) do
    case cast(attribute, default) do
      {:ok, default} -> {:cont, {:ok, Map.put(values, attribute.name, default)}}
      {:error, reason} -> {:halt, {:error, invalid(attribute, reason)}}
    end
  end

  defp missing(%Attribute{allow_nil?: true} = attribute, values),
    do: {:cont, {:ok, Map.put(values, attribute.name, nil)}}

  defp missing(attribute, _values),
    do: {:halt, {:error, invalid(attribute, "is required")}}

  defp cast(%Attribute{type: type, constraints: constraints}, value) do
    with {:ok, constraints} <- Ash.Type.init(type, constraints || []),
         {:ok, cast} <- normalize_cast(Ash.Type.cast_input(type, value, constraints)),
         {:ok, cast} <- Ash.Type.apply_constraints(type, cast, constraints) do
      {:ok, cast}
    else
      :error -> {:error, "is invalid"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_cast({:ok, value}), do: {:ok, value}
  defp normalize_cast(:error), do: :error
  defp normalize_cast({:error, reason}), do: {:error, reason}

  defp invalid(%Attribute{name: name}, reason), do: {:invalid_attribute, name, reason}
end
