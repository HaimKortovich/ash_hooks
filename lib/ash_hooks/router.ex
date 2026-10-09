defmodule AshHooks.Router do
  @moduledoc """
  A generated Plug router for inbound AshHooks declarations.

  The router discovers inbound declarations from the configured Ash domains:

      defmodule MyAppWeb.Webhooks do
        use AshHooks.Router,
          domains: [MyApp.Api],
          prefix: "/api/webhooks",
          open_api: "/openapi.json",
          context: {MyAppWeb.Webhooks, :context, []}
      end

  Mount it with `forward "/api/webhooks", MyAppWeb.Webhooks`. The host
  application remains responsible for authenticating or resolving tenant
  context. The optional `context` callback receives the connection and route
  metadata and must return a context map for `AshHooks.Ingress`.

  Staff secret retrieval is not mounted here. When configured on an inbound
  declaration, AshHooks adds a generic AshJsonApi action route to the resource;
  the host's normal authenticated AshJsonApi pipeline protects it.
  """

  @doc false
  defmacro __using__(opts) do
    unless Code.ensure_loaded?(Plug.Router) do
      raise CompileError,
        description: "AshHooks.Router requires the optional :plug dependency"
    end

    opts = Macro.expand_literals(opts, __CALLER__)

    opts =
      Keyword.update(opts, :context, nil, fn
        {:{}, _, _} = context ->
          {context, _bindings} = Code.eval_quoted(context, [], __CALLER__)
          context

        context ->
          context
      end)

    domains = List.wrap(opts[:domain] || opts[:domains])
    routes = routes(domains, opts)
    opts_ast = Macro.escape(opts)
    domains_ast = Macro.escape(domains)
    routes_ast = Macro.escape(routes)

    quote do
      use Plug.Router

      @ash_hooks_opts unquote(opts_ast)
      @ash_hooks_domains unquote(domains_ast)
      @ash_hooks_routes unquote(routes_ast)

      def domains, do: @ash_hooks_domains
      def routes, do: @ash_hooks_routes

      plug(:match)

      plug(Plug.Parsers,
        parsers: [:json],
        pass: [],
        body_reader: {AshHooks.BodyReader, :read_body, []},
        json_decoder: Jason
      )

      plug(:dispatch)

      match(_,
        to: AshHooks.Router.Controller,
        init_opts: %{
          routes: @ash_hooks_routes,
          opts: @ash_hooks_opts
        }
      )

      def spec do
        AshHooks.OpenApi.spec(Keyword.put(@ash_hooks_opts, :domains, @ash_hooks_domains))
      end

      if Code.ensure_loaded?(Phoenix.Router) &&
           function_exported?(Phoenix.Router, :__formatted_routes__, 1) do
        @behaviour Phoenix.VerifiedRoutes

        def formatted_routes(_opts), do: AshHooks.Router.formatted_routes(__MODULE__)

        def verified_route?(_opts, path),
          do: AshHooks.Router.verified_route?(__MODULE__, path)
      end
    end
  end

  @doc "Returns the generated inbound routes for the configured domains."
  def routes(domains, _opts \\ []) do
    webhook_routes =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.flat_map(fn resource ->
        resource
        |> AshHooks.Info.webhooks()
        |> Enum.filter(&match?(%AshHooks.Inbound{}, &1))
        |> Enum.map(&webhook_route(resource, &1))
      end)

    duplicates =
      webhook_routes
      |> Enum.group_by(& &1.path)
      |> Enum.filter(fn {_path, routes} -> length(routes) > 1 end)

    if duplicates != [] do
      raise ArgumentError,
            "AshHooks routes must be unique: #{duplicates |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}"
    end

    webhook_routes
  end

  @doc false
  def formatted_routes(router) do
    Enum.map(router.routes(), fn route ->
      %{verb: route.method, path: route.path, label: "#{inspect(router)} #{route.label}"}
    end)
  end

  @doc false
  def verified_route?(router, path) do
    router.routes()
    |> Enum.any?(fn route -> match_path?(path_segments(route.path), path_segments(path)) end)
  end

  @doc false
  def match_path?(route, path),
    do: match_path_segments?(path_segments(route), path_segments(path))

  @doc false
  def path_segments(path), do: path |> normalize_path() |> String.split("/", trim: true)

  defp webhook_route(resource, inbound) do
    resource_name = resource_name(resource)
    path = normalize_path(inbound.route || "/#{resource_name}/#{inbound.name}")

    %{
      kind: :webhook,
      method: "POST",
      path: path,
      resource: resource,
      inbound: inbound,
      label: "#{inspect(resource)}.#{inbound.name}"
    }
  end

  defp resource_name(resource) do
    resource
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  defp normalize_path(path) do
    path = if String.starts_with?(path, "/"), do: path, else: "/" <> path
    if path == "/", do: path, else: String.trim_trailing(path, "/")
  end

  defp match_path_segments?([], []), do: true
  defp match_path_segments?([], _), do: false
  defp match_path_segments?(["*" <> _], _), do: true
  defp match_path_segments?(_, []), do: false
  defp match_path_segments?([":" <> _ | route], [_ | path]), do: match_path_segments?(route, path)
  defp match_path_segments?([same | route], [same | path]), do: match_path_segments?(route, path)
  defp match_path_segments?(_, _), do: false
end
