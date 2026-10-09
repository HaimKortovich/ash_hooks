defmodule AshHooks.Verifiers.InboundEvents do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Verifier.get_entities([:webhooks])
    |> Enum.filter(&match?(%AshHooks.Inbound{}, &1))
    |> Enum.each(&verify_inbound!(resource, &1))

    :ok
  end

  defp verify_inbound!(resource, inbound) do
    attribute_names = Enum.map(inbound.attributes, & &1.name)

    if length(attribute_names) != length(Enum.uniq(attribute_names)) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :attributes],
        message: "inbound attributes must have unique names"
    end

    verify_identity!(resource, inbound, attribute_names)

    event_types = Enum.map(inbound.events, & &1.type)

    if length(event_types) != length(Enum.uniq(event_types)) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :events],
        message: "inbound event wire types must be unique"
    end

    Enum.each(inbound.events, &verify_event!(resource, inbound, &1, attribute_names))
  end

  defp verify_identity!(_resource, %{identity: nil}, _attribute_names), do: :ok

  defp verify_identity!(resource, %{identity: identity} = inbound, attribute_names) do
    unless identity in attribute_names do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :identity],
        message:
          "identity #{inspect(identity)} must reference an attribute declared on the inbound webhook"
    end

    attribute = Enum.find(inbound.attributes, &(&1.name == identity))

    if attribute.allow_nil? do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :identity],
        message: "identity attribute #{inspect(identity)} must set allow_nil?: false"
    end
  end

  defp verify_event!(resource, inbound, event, common_names) do
    event_names = Enum.map(event.attributes, & &1.name)

    if length(event_names) != length(Enum.uniq(event_names)) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :event, event.name],
        message: "event attributes must have unique names"
    end

    overlap = MapSet.intersection(MapSet.new(common_names), MapSet.new(event_names))

    if MapSet.size(overlap) > 0 do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :event, event.name],
        message:
          "event attributes repeat shared inbound attributes: #{inspect(MapSet.to_list(overlap))}"
    end

    {action_resource, action_name} = action_target!(resource, inbound, event)

    case Ash.Resource.Info.action(action_resource, action_name) do
      nil ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
          message: "action #{inspect(action_name)} is not defined on #{inspect(action_resource)}"

      %{type: action_type} = action when action_type in [:action, :update] ->
        verify_action_inputs!(
          resource,
          action_resource,
          action_name,
          action,
          inbound,
          event,
          common_names
        )

      action ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
          message:
            "action #{inspect(action_name)} on #{inspect(action_resource)} must be a generic action, got #{inspect(action.type)}"
    end
  end

  defp action_target!(resource, inbound, event) do
    case event.action do
      action when is_atom(action) ->
        {resource, action}

      {action_resource, action} when is_atom(action_resource) and is_atom(action) ->
        {action_resource, action}

      invalid ->
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
          message: "action must be an atom or a {resource, action} tuple, got #{inspect(invalid)}"
    end
  end

  defp verify_action_inputs!(
         resource,
         action_resource,
         action_name,
         action,
         inbound,
         event,
         _common_names
       ) do
    accepted = Ash.Resource.Info.action_inputs(action_resource, action_name)
    attributes = inbound.attributes ++ event.attributes

    verify_record!(resource, action_resource, inbound, event, action)

    action_attributes =
      if action.type == :update and event.record,
        do: Enum.reject(attributes, &(&1.name == event.record)),
        else: attributes

    action_attributes
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.each(fn attribute ->
      unless MapSet.member?(accepted, attribute) do
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
          message:
            "action #{inspect(action_name)} on #{inspect(action_resource)} does not accept inbound attribute #{inspect(attribute)}"
      end
    end)

    Enum.each(action.arguments, fn argument ->
      attribute = Enum.find(attributes, &(&1.name == argument.name))

      if required_argument?(argument) and is_nil(attribute) do
        raise Spark.Error.DslError,
          module: resource,
          path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
          message:
            "action #{inspect(action_name)} on #{inspect(action_resource)} requires input #{inspect(argument.name)}, " <>
              "but the inbound event does not declare it"
      end

      if attribute do
        verify_argument_type!(
          resource,
          action_resource,
          action_name,
          inbound,
          event,
          argument,
          attribute
        )
      end
    end)
  end

  defp verify_record!(_resource, _action_resource, _inbound, %{record: nil}, %{type: :action}),
    do: :ok

  defp verify_record!(resource, _action_resource, inbound, %{record: record}, %{type: :action})
       when not is_nil(record) do
    raise Spark.Error.DslError,
      module: resource,
      path: [:webhooks, :inbound, inbound.name, :event, record, :record],
      message: "record can only be used with an Ash update action"
  end

  defp verify_record!(resource, action_resource, inbound, event, %{type: :update}) do
    record = event.record
    attributes = inbound.attributes ++ event.attributes

    with record when is_atom(record) <- record,
         %{name: ^record} = attribute <- Enum.find(attributes, &(&1.name == record)),
         [primary_key] <- Ash.Resource.Info.primary_key(action_resource),
         :ok <- verify_record_type(action_resource, primary_key, attribute) do
      :ok
    else
      nil ->
        raise_record_error(resource, inbound, event, "update actions require `record :attribute`")

      record when is_atom(record) ->
        raise_record_error(
          resource,
          inbound,
          event,
          "record attribute #{inspect(record)} is not declared"
        )

      _ ->
        raise_record_error(
          resource,
          inbound,
          event,
          "record requires a resource with exactly one primary-key attribute"
        )
    end
  end

  defp verify_record!(_resource, _action_resource, _inbound, _event, _action), do: :ok

  defp verify_record_type(resource, primary_key, attribute) do
    primary_key_type = Ash.Resource.Info.attribute(resource, primary_key).type

    if Ash.Type.get_type!(primary_key_type) == Ash.Type.get_type!(attribute.type),
      do: :ok,
      else: {:error, :record_type_mismatch}
  end

  defp raise_record_error(resource, inbound, event, message) do
    raise Spark.Error.DslError,
      module: resource,
      path: [:webhooks, :inbound, inbound.name, :event, event.name, :record],
      message: message
  end

  defp required_argument?(%{allow_nil?: false, default: nil}), do: true
  defp required_argument?(_argument), do: false

  defp verify_argument_type!(
         resource,
         action_resource,
         action_name,
         inbound,
         event,
         argument,
         attribute
       ) do
    if Ash.Type.get_type!(argument.type) != Ash.Type.get_type!(attribute.type) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
        message:
          "inbound attribute #{inspect(attribute.name)} has type #{inspect(attribute.type)}, " <>
            "but action #{inspect(action_name)} on #{inspect(action_resource)} expects #{inspect(argument.type)}"
    end

    if required_argument?(argument) and attribute.allow_nil? and is_nil(attribute.default) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, inbound.name, :event, event.name, :action],
        message:
          "required action input #{inspect(argument.name)} for #{inspect(action_resource)} cannot be supplied by a nullable " <>
            "inbound attribute"
    end
  end
end
