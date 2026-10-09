defmodule AshHooks.Transformers.AddJsonApiSecretRoutes do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.{Extension, Transformer}

  def before?(AshJsonApi.Resource.Transformers.PrependRoutePrefix), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    inbound_declarations =
      dsl_state
      |> Extension.get_entities([:webhooks])
      |> Enum.filter(&match?(%AshHooks.Inbound{secret_route: route} when route != false, &1))

    cond do
      inbound_declarations == [] ->
        {:ok, dsl_state}

      not Code.ensure_loaded?(AshJsonApi.Resource) or
          not Map.has_key?(dsl_state, [:json_api]) ->
        raise Spark.Error.DslError,
          module: Map.get(dsl_state, :module),
          path: [:webhooks],
          message: "secret_route requires the AshJsonApi.Resource extension on the resource"

      true ->
        Enum.reduce(inbound_declarations, {:ok, dsl_state}, fn inbound, {:ok, state} ->
          add_secret_route(state, inbound)
        end)
    end
  end

  defp add_secret_route(dsl_state, inbound) do
    action_name = String.to_atom("get_#{inbound.name}_webhook_secret")

    route =
      inbound.secret_route || "/organizations/:organization_id/webhooks/#{inbound.name}/secret"

    with {:ok, organization_id} <-
           Builder.build_action_argument(:organization_id, :string, allow_nil?: false),
         {:ok, action} <-
           Builder.build_action(:action, action_name,
             returns: :map,
             arguments: [organization_id],
             run: AshHooks.JsonApi.Secret
           ),
         {:ok, state} <- add_action(dsl_state, action) do
      json_api_route =
        struct(AshJsonApi.Resource.Route, %{
          route: route,
          action: action_name,
          action_type: :action,
          default_fields: [],
          method: :get,
          controller: AshJsonApi.Controllers.GenericActionRoute,
          name: "get_#{inbound.name}_webhook_secret",
          resource: nil,
          type: :route,
          primary?: false,
          upsert?: false,
          upsert_identity: nil,
          read_action: nil,
          description: "Get the #{inbound.name} webhook secret for an organization.",
          query_params: [],
          modify_conn: nil,
          derive_sort?: true,
          derive_filter?: true,
          wrap_in_result?: false,
          relationship_arguments: [],
          metadata: nil,
          path_param_is_composite_key: nil
        })

      {:ok, Transformer.add_entity(state, [:json_api, :routes], json_api_route, type: :append)}
    end
  end

  defp add_action(dsl_state, action),
    do: {:ok, Transformer.add_entity(dsl_state, [:actions], action)}
end
