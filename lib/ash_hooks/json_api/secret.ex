defmodule AshHooks.JsonApi.Secret do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  @doc false
  def run(input, _opts, context) do
    organization_id = input.arguments.organization_id
    inbound = inbound_name(input.action.name)
    resolver = resolver(input.resource, inbound)

    if tenant_matches?(organization_id, context.tenant) do
      with {:ok, secret} <- resolve(resolver, organization_id, inbound, context),
           true <- is_binary(secret) and secret != "" do
        {:ok, %{organization_id: organization_id, webhook_secret: secret}}
      else
        false -> {:error, :invalid_webhook_secret}
        {:error, _reason} -> {:error, :webhook_secret_unavailable}
      end
    else
      {:error, :organization_not_authorized}
    end
  end

  defp resolver(resource, name) do
    resource
    |> AshHooks.Info.webhooks()
    |> Enum.find(&(match?(%AshHooks.Inbound{}, &1) and to_string(&1.name) == to_string(name)))
    |> case do
      %AshHooks.Inbound{secret_resolver: resolver} -> resolver
      _ -> nil
    end
  end

  defp inbound_name(action) do
    action
    |> to_string()
    |> String.trim_leading("get_")
    |> String.trim_trailing("_webhook_secret")
  end

  defp resolve({module, function, extra}, organization_id, inbound, context),
    do: normalize(apply(module, function, [organization_id, inbound, context | List.wrap(extra)]))

  defp resolve(function, organization_id, inbound, context) when is_function(function, 3),
    do: normalize(function.(organization_id, inbound, context))

  defp resolve(_resolver, _organization_id, _inbound, _context),
    do: {:error, :invalid_resolver}

  defp normalize({:ok, secret}), do: {:ok, secret}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(secret), do: {:ok, secret}

  defp tenant_matches?(_organization_id, nil), do: true

  defp tenant_matches?(organization_id, tenant),
    do: to_string(organization_id) == to_string(tenant)
end
