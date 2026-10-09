defmodule AshHooks.OpenApi do
  @moduledoc """
  Generates an OpenAPI 3.1 document for the inbound routes created by
  `AshHooks.Router`.

  Inbound webhook operations live under the OpenAPI 3.1 `webhooks` member so
  generated clients can distinguish provider callbacks from operations the
  application calls. The request schemas are derived from the typed inbound
  event declarations, including nested typed structs and union variants.
  """

  @doc "Returns a JSON-compatible OpenAPI 3.1 map for an AshHooks router."
  def spec(opts \\ []) do
    domains = List.wrap(opts[:domain] || opts[:domains])
    routes = AshHooks.Router.routes(domains, opts)
    webhook_routes = Enum.filter(routes, &(&1.kind == :webhook))

    {webhooks, schemas, security_schemes} =
      Enum.reduce(webhook_routes, {%{}, %{}, %{}}, fn route, {webhooks, schemas, security} ->
        name = webhook_name(route)
        schema_name = event_schema_name(route)
        signature_name = security_scheme_name(route.inbound.signature_header)

        event_schemas =
          Map.new(route.inbound.events, &{event_name(route, &1), event_schema(route, &1)})

        {
          Map.put(webhooks, name, webhook_operation(route, schema_name, signature_name, opts)),
          Map.merge(schemas, Map.put(event_schemas, schema_name, request_schema(route))),
          Map.put(security, signature_name, signature_scheme(route.inbound.signature_header))
        }
      end)

    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => opts[:open_api_title] || "AshHooks Webhooks",
        "version" => opts[:open_api_version] || "1.0.0"
      },
      "servers" => servers(opts),
      "paths" => %{},
      "webhooks" => webhooks,
      "components" => %{
        "schemas" => schemas,
        "securitySchemes" => security_schemes
      }
    }
  end

  defp webhook_operation(route, schema_name, security_name, opts) do
    %{
      "post" => %{
        "operationId" => operation_id(route),
        "summary" => "Receive #{route.inbound.name} webhook",
        "description" => "Inbound provider callback handled by #{inspect(route.resource)}.",
        "x-ash-hooks-direction" => "inbound",
        "x-ash-hooks-route" => prefixed_path(opts, route.path),
        "security" => [%{security_name => []}],
        "requestBody" => %{
          "required" => true,
          "content" => %{
            "application/json" => %{
              "schema" => %{"$ref" => "#/components/schemas/#{schema_name}"}
            }
          }
        },
        "responses" => standard_responses()
      }
    }
  end

  defp event_schema_name(route), do: "#{schema_prefix(route)}Payload"

  defp event_name(route, event),
    do: "#{schema_prefix(route)}#{Macro.camelize(to_string(event.name))}"

  defp schema_prefix(route) do
    route.resource
    |> Module.split()
    |> Enum.join("")
    |> Kernel.<>("_" <> Atom.to_string(route.inbound.name))
    |> Macro.camelize()
  end

  defp event_schema(route, event) do
    attributes = route.inbound.attributes ++ event.attributes

    object_schema(attributes)
    |> Map.put("x-ash-hooks-event-type", event.type)
    |> Map.put("x-ash-hooks-action", inspect(event.action))
    |> maybe_put_record(event.record)
  end

  defp maybe_put_record(schema, nil), do: schema

  defp maybe_put_record(schema, record),
    do: Map.put(schema, "x-ash-hooks-record", Atom.to_string(record))

  defp request_schema(route) do
    case route.inbound.events do
      [] ->
        %{"type" => "object", "additionalProperties" => true}

      _ ->
        %{
          "oneOf" =>
            Enum.map(
              route.inbound.events,
              &%{"$ref" => "#/components/schemas/#{event_name(route, &1)}"}
            ),
          "x-ash-hooks-events" =>
            Enum.map(
              route.inbound.events,
              &%{"name" => Atom.to_string(&1.name), "type" => &1.type}
            )
        }
    end
  end

  defp object_schema(attributes) do
    {properties, required} =
      Enum.reduce(attributes, {%{}, []}, fn attribute, {properties, required} ->
        property = type_schema(attribute.type, attribute.constraints || [])

        property =
          if attribute.allow_nil? do
            %{"anyOf" => [%{"type" => "null"}, property]}
          else
            property
          end

        required =
          if attribute.allow_nil? == false and is_nil(attribute.default),
            do: [Atom.to_string(attribute.name) | required],
            else: required

        {Map.put(properties, Atom.to_string(attribute.name), property), required}
      end)

    %{"type" => "object", "properties" => properties}
    |> maybe_required(required)
  end

  defp maybe_required(schema, []), do: schema
  defp maybe_required(schema, required), do: Map.put(schema, "required", Enum.reverse(required))

  # AshJsonApi is the source of truth for ordinary Ash type schemas. AshHooks
  # also accepts standalone Ash.TypedStruct modules and its event DSL exposes
  # union constraints directly; those are the two shapes that AshJsonApi's
  # public attribute helper cannot receive as a resource attribute.
  defp type_schema(type, constraints) do
    normalized_type = normalize_type(type)

    try do
      schema =
        AshJsonApi.JsonSchema.attribute_schema(%{
          type: normalized_type,
          constraints: constraints
        })

      if unsupported_schema?(schema, normalized_type) do
        fallback_type_schema(normalized_type, constraints)
      else
        schema
      end
    rescue
      _ -> fallback_type_schema(normalized_type, constraints)
    end
  end

  defp normalize_type({:array, type}), do: {:array, normalize_type(type)}

  defp normalize_type(type) when is_atom(type) do
    Ash.Type.get_type!(type)
  rescue
    _ -> type
  end

  defp normalize_type(type), do: type

  defp unsupported_schema?(%{"type" => "any"}, type),
    do:
      type == Ash.Type.Union or
        is_typed_struct?(type) or
        safe_subtype_of(type) == Ash.Type.Struct or
        safe_subtype_of(type) == :union

  defp unsupported_schema?(_, _), do: false

  defp is_typed_struct?(type) when is_atom(type) do
    Code.ensure_loaded?(type) and
      function_exported?(type, :__ash_typed_struct__, 0)
  end

  defp is_typed_struct?(_), do: false

  defp fallback_type_schema({:array, type}, constraints),
    do: %{"type" => "array", "items" => type_schema(type, Keyword.get(constraints, :items, []))}

  defp fallback_type_schema(Ash.Type.Union, constraints), do: union_schema(constraints)

  defp fallback_type_schema(type, constraints) when is_atom(type) do
    cond do
      is_typed_struct?(type) -> typed_struct_schema(type, constraints)
      safe_subtype_of(type) == Ash.Type.Struct -> typed_struct_schema(type, constraints)
      safe_subtype_of(type) == :union -> union_schema(safe_subtype_constraints(type, constraints))
      type == Ash.Type.Map -> %{"type" => "object", "additionalProperties" => true}
      true -> %{"type" => "object"}
    end
  end

  defp fallback_type_schema(_, _), do: %{"type" => "object"}

  defp union_schema(constraints) do
    constraints
    |> Keyword.get(:types, [])
    |> Enum.map(fn {name, config} ->
      schema = type_schema(config[:type], config[:constraints] || [])

      if config[:tag] && Map.has_key?(schema, "properties") do
        schema
        |> Map.update(
          "properties",
          %{},
          &Map.put(&1, Atom.to_string(config[:tag]), %{"const" => config[:tag_value]})
        )
        |> Map.update(
          "required",
          [Atom.to_string(config[:tag])],
          &Enum.uniq([Atom.to_string(config[:tag]) | &1])
        )
      else
        Map.put(schema, "title", Atom.to_string(name))
      end
    end)
    |> then(&%{"oneOf" => &1})
  end

  defp typed_struct_schema(type, constraints) do
    fields =
      if Code.ensure_loaded?(Ash.TypedStruct.Info) and
           function_exported?(Ash.TypedStruct.Info, :fields, 1) do
        Ash.TypedStruct.Info.fields(type)
      else
        Keyword.get(constraints, :fields, [])
      end

    attributes =
      Enum.map(fields, fn field ->
        %AshHooks.Inbound.Attribute{
          name: field.name,
          type: field.type,
          constraints: field.constraints || [],
          allow_nil?: field.allow_nil? != false,
          default: nil
        }
      end)

    object_schema(attributes)
  rescue
    _ -> %{"type" => "object"}
  end

  defp safe_subtype_of(type) do
    if Ash.Type.NewType.new_type?(type), do: Ash.Type.NewType.subtype_of(type), else: type
  rescue
    _ -> type
  end

  defp safe_subtype_constraints(type, constraints) do
    if function_exported?(type, :subtype_constraints, 0),
      do: Keyword.merge(type.subtype_constraints(), constraints),
      else: constraints
  rescue
    _ -> constraints
  end

  defp standard_responses do
    %{
      "200" => %{"description" => "Webhook accepted."},
      "400" => %{"description" => "The payload is invalid."},
      "403" => %{"description" => "The signature is invalid."},
      "503" => %{"description" => "Webhook secret is unavailable."},
      "500" => %{"description" => "The webhook could not be processed."}
    }
  end

  defp signature_scheme(header) do
    %{
      "type" => "apiKey",
      "in" => "header",
      "name" => header,
      "description" => "Provider signature for the exact request body."
    }
  end

  defp security_scheme_name("webhook-signature"), do: "webhookSignature"

  defp security_scheme_name(header),
    do: "webhookSignature_#{Macro.underscore(header) |> String.replace(~r/[^a-zA-Z0-9_]/, "_")}"

  defp webhook_name(route),
    do: "#{route.resource |> Module.split() |> List.last()}.#{route.inbound.name}"

  defp operation_id(route), do: "receive#{Macro.camelize(webhook_name(route))}"
  defp prefixed_path(opts, path), do: Path.join(opts[:prefix] || "/", path)

  defp servers(opts),
    do: if(opts[:open_api_server], do: [%{"url" => opts[:open_api_server]}], else: [])
end
