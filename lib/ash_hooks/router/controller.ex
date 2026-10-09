if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshHooks.Router.Controller do
    @moduledoc false

    def init(options), do: options

    def call(conn, %{routes: routes, opts: opts}) do
      case Enum.find(routes, &matches?(&1, conn.method, conn.path_info)) do
        nil -> send_json(conn, 404, %{error: "not_found"})
        %{kind: :webhook} = route -> dispatch_webhook(conn, route, opts)
      end
    end

    defp dispatch_webhook(conn, route, opts) do
      route_info = route_info(route, conn)

      with {:ok, context} <- build_context(conn, route_info, opts),
           {:ok, context} <- ensure_context_defaults(conn, context, route),
           {:ok, raw_body} <- raw_body(conn),
           {:ok, _created?, _delivery} <-
             AshHooks.Ingress.ingest(
               route.resource,
               route.inbound.name,
               raw_body,
               context
             ) do
        send_json(conn, 200, %{status: "accepted"})
      else
        {:error, reason} ->
          send_json(conn, status_for_ingress_error(reason), %{error: error_code(reason)})
      end
    end

    defp build_context(conn, route_info, opts) do
      case opts[:context] do
        nil -> {:ok, %{}}
        callback -> invoke_callback(callback, [conn, route_info])
      end
    end

    defp ensure_context_defaults(conn, context, route) when is_map(context) do
      defaults = %{
        tenant:
          conn.private[:ash_hooks_tenant] || conn.assigns[:ash_hooks_tenant] ||
            conn.assigns[:tenant],
        scope: conn.private[:ash_hooks_scope] || conn.assigns[:ash_hooks_scope] || %{},
        connection:
          conn.private[:ash_hooks_connection] || conn.assigns[:ash_hooks_connection] || %{},
        signature: List.first(Plug.Conn.get_req_header(conn, route.inbound.signature_header)),
        headers: Map.new(conn.req_headers),
        method: conn.method,
        request_uri: request_uri(conn)
      }

      {:ok, Map.merge(defaults, context)}
    end

    defp ensure_context_defaults(_conn, _context, _route),
      do: {:error, :invalid_context}

    defp raw_body(%Plug.Conn{private: %{ash_hooks_raw_body: raw_body}}) when is_binary(raw_body),
      do: {:ok, raw_body}

    defp raw_body(_conn), do: {:error, :missing_raw_body}

    defp invoke_callback({module, function, extra}, args)
         when is_atom(module) and is_atom(function),
         do: normalize_callback(apply(module, function, args ++ List.wrap(extra)))

    defp invoke_callback(function, args) when is_function(function),
      do: normalize_callback(apply(function, args))

    defp invoke_callback(_callback, _args), do: {:error, :invalid_callback}

    defp normalize_callback(:ok), do: {:ok, %{}}
    defp normalize_callback({:ok, value}), do: {:ok, value}
    defp normalize_callback({:error, reason}), do: {:error, reason}
    defp normalize_callback(value) when is_map(value), do: {:ok, value}
    defp normalize_callback(_value), do: {:error, :callback_rejected}

    defp route_info(route, conn) do
      %{
        kind: route.kind,
        resource: route[:resource],
        inbound: route[:inbound],
        route: route.path,
        params: params(route.path, conn.path_info)
      }
    end

    defp params(route, path) do
      Enum.zip(AshHooks.Router.path_segments(route), path)
      |> Enum.reduce(%{}, fn
        {":" <> name, value}, acc -> Map.put(acc, name, value)
        {_literal, _value}, acc -> acc
      end)
    end

    defp matches?(route, method, path),
      do:
        route.method == method and
          AshHooks.Router.match_path?(route.path, "/" <> Enum.join(path, "/"))

    defp request_uri(conn) do
      conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)
    end

    defp status_for_ingress_error(%AshHooks.Errors.Invalid.InvalidSignature{}), do: 403
    defp status_for_ingress_error(%AshHooks.Errors.Invalid.NoWebhookSecret{}), do: 503
    defp status_for_ingress_error(%AshHooks.Errors.Invalid.MalformedPayload{}), do: 400
    defp status_for_ingress_error(%AshHooks.Errors.Invalid{}), do: 400
    defp status_for_ingress_error(:missing_raw_body), do: 400
    defp status_for_ingress_error(_reason), do: 500

    defp error_code(%{__struct__: module}),
      do: module |> Module.split() |> List.last() |> Macro.underscore()

    defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
    defp error_code(_reason), do: "ingress_failed"

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end
end
