defmodule AshHooks.RouterTest do
  use ExUnit.Case, async: false

  defmodule Provider do
    @behaviour AshHooks.Provider

    @impl true
    def verify_signature(raw_body, context, secret),
      do:
        AshHooks.Provider.default_verify_signature(
          raw_body,
          context.signature,
          secret,
          :hmac_sha256
        )

    @impl true
    def parse_event_type(%{"type" => "quote_completed"}), do: {:ok, :quote_completed}
    def parse_event_type(_payload), do: {:error, :unknown_event_type}

    @impl true
    def handle_event(_event_type, _payload), do: {:error, :legacy_handler_called}
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource AshHooks.RouterTest.Ledger
    end
  end

  defmodule Ledger do
    use Ash.Resource,
      domain: AshHooks.RouterTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("router_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute :account_id, :string, allow_nil?: false
    end

    actions do
      defaults [:read]

      action :complete, :map do
        argument :execution_id, :string, allow_nil?: false
        argument :quote_id, :string, allow_nil?: false
        argument :note, :string

        run fn input, _context ->
          {:ok, input.arguments}
        end
      end
    end

    webhooks do
      inbound :provider_events do
        provider(AshHooks.RouterTest.Provider)
        secret {AshHooks.RouterTest, :secret, []}
        identity(:execution_id)
        attribute :execution_id, :string, allow_nil?: false

        event "quote_completed" do
          action :complete
          attribute :quote_id, :string, allow_nil?: false
          attribute :note, :string
        end
      end
    end
  end

  defmodule Router do
    use AshHooks.Router,
      domains: [AshHooks.RouterTest.Domain],
      prefix: "/api/webhooks",
      open_api: "/openapi.json"
  end

  defmodule Address do
    use Ash.TypedStruct

    typed_struct do
      field :city, :string, allow_nil?: false
      field :postal_code, :integer, allow_nil?: false
    end
  end

  defmodule Applicant do
    use Ash.TypedStruct

    typed_struct do
      field :name, :string, allow_nil?: false
      field :address, Address, allow_nil?: false
    end
  end

  defmodule SignedSignature do
    use Ash.TypedStruct

    typed_struct do
      field :method, :string, allow_nil?: false
      field :signature_id, :string, allow_nil?: false
    end
  end

  defmodule DrawnSignature do
    use Ash.TypedStruct

    typed_struct do
      field :method, :string, allow_nil?: false
      field :image_url, :string, allow_nil?: false
    end
  end

  defmodule SchemaDomain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource AshHooks.RouterTest.SchemaResource
    end
  end

  defmodule SchemaResource do
    @signature_constraints [
      types: [
        signed: [type: SignedSignature, tag: :method, tag_value: "signed"],
        drawn: [type: DrawnSignature, tag: :method, tag_value: "drawn"]
      ]
    ]

    use Ash.Resource,
      domain: AshHooks.RouterTest.SchemaDomain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshHooks]

    attributes do
      uuid_primary_key :id
    end

    actions do
      action :complete, :map do
        argument :applicant, Applicant, allow_nil?: false
        argument :signature, :union, constraints: @signature_constraints, allow_nil?: false

        run fn input, _context ->
          {:ok, input.arguments}
        end
      end
    end

    webhooks do
      inbound :provider_events do
        provider(AshHooks.RouterTest.Provider)
        secret {AshHooks.RouterTest, :secret, []}

        event "application.completed" do
          action :complete
          attribute :applicant, Applicant, allow_nil?: false
          attribute :signature, :union, constraints: @signature_constraints, allow_nil?: false
        end
      end
    end
  end

  defmodule ApiDomain do
    use Ash.Domain,
      otp_app: nil,
      validate_config_inclusion?: false,
      extensions: [AshJsonApi.Domain]

    resources do
      resource AshHooks.RouterTest.SecretResource
    end
  end

  defmodule SecretResource do
    use Ash.Resource,
      domain: AshHooks.RouterTest.ApiDomain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshHooks, AshJsonApi.Resource]

    attributes do
      uuid_primary_key :id
    end

    json_api do
      type "webhook-secret"

      routes do
        base("/")
      end
    end

    actions do
      defaults [:read]
    end

    webhooks do
      inbound :provider_events do
        provider(AshHooks.RouterTest.Provider)
        secret {AshHooks.RouterTest, :secret, []}
        secret_route("/organizations/:organization_id/webhooks/provider_events/secret")
        secret_resolver({AshHooks.RouterTest, :resolve_secret, []})
      end
    end
  end

  defmodule ApiRouter do
    use AshJsonApi.Router,
      domain: AshHooks.RouterTest.ApiDomain,
      prefix: "/api"
  end

  alias AshHooks.Test.Repo

  @table "router_test_ledgers"
  @secret "test-secret"

  setup do
    Repo.query!("DELETE FROM #{@table}")
    :ok
  end

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      external_event_id TEXT NOT NULL,
      external_event_type TEXT,
      payload TEXT NOT NULL,
      payload_digest TEXT NOT NULL,
      status TEXT NOT NULL,
      fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT,
      error_class TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_identity ON #{@table} (provider, external_event_id, account_id)"
    )

    on_exit(fn -> Repo.query!("DROP TABLE IF EXISTS #{@table}") end)
    :ok
  end

  test "generated routes ingest a signed typed webhook through Plug" do
    body = ~s({"type":"quote_completed","execution_id":"exec-http","quote_id":"quote-http"})

    conn =
      Plug.Test.conn(:post, "/ledger/provider_events", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("webhook-signature", sign(body))
      |> Plug.Conn.put_private(:ash_hooks_scope, %{"account_id" => "acct-1"})
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "accepted"}

    assert {:ok, [delivery]} =
             AshHooks.RouterTest.Ledger
             |> Ash.Query.do_filter(provider: :provider_events, external_event_id: "exec-http")
             |> Ash.read(tenant: nil, authorize?: false)

    assert delivery.status == :processed
  end

  test "invalid signatures are rejected by the generated route" do
    body = ~s({"type":"quote_completed","execution_id":"exec-invalid","quote_id":"q"})

    conn =
      Plug.Test.conn(:post, "/ledger/provider_events", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("webhook-signature", "bad")
      |> Plug.Conn.put_private(:ash_hooks_scope, %{"account_id" => "acct-1"})
      |> Router.call(Router.init([]))

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_signature"}
  end

  test "openapi exposes inbound webhooks and typed event schemas" do
    spec = AshHooks.OpenApi.spec(domains: Router.domains(), prefix: "/api/webhooks")

    assert spec["openapi"] == "3.1.0"

    assert spec["webhooks"]["Ledger.provider_events"]["post"]["x-ash-hooks-direction"] ==
             "inbound"

    assert spec["webhooks"]["Ledger.provider_events"]["post"]["security"] == [
             %{"webhookSignature" => []}
           ]

    schema_ref =
      spec["webhooks"]["Ledger.provider_events"]["post"]["requestBody"]["content"][
        "application/json"
      ][
        "schema"
      ]

    assert schema_ref["$ref"] =~ "Payload"

    quote_completed =
      spec["components"]["schemas"]
      |> Enum.find_value(fn {name, schema} ->
        if String.ends_with?(name, "QuoteCompleted"), do: schema
      end)

    assert quote_completed["properties"]["note"]["anyOf"]

    assert Enum.any?(
             Map.keys(spec["components"]["schemas"]),
             &String.ends_with?(&1, "QuoteCompleted")
           )
  end

  test "event schemas use AshJsonApi for nested attributes and union variants" do
    spec = AshHooks.OpenApi.spec(domains: [SchemaDomain])

    {_, event_schema} =
      Enum.find(spec["components"]["schemas"], fn {name, _schema} ->
        String.ends_with?(name, "ApplicationCompleted")
      end)

    applicant = event_schema["properties"]["applicant"]

    assert applicant["type"] == "object"
    assert applicant["properties"]["name"]["type"] == "string"
    assert applicant["properties"]["address"]["properties"]["city"]["type"] == "string"

    signature = event_schema["properties"]["signature"]
    assert length(signature["oneOf"]) == 2

    assert Enum.any?(signature["oneOf"], fn variant ->
             variant["properties"]["method"]["const"] == "signed"
           end)

    assert Enum.any?(signature["oneOf"], fn variant ->
             variant["properties"]["method"]["const"] == "drawn"
           end)
  end

  test "secret retrieval is a generated authenticated AshJsonApi action route" do
    routes = AshJsonApi.Resource.Info.routes(SecretResource, ApiDomain)

    assert Enum.any?(routes, fn route ->
             route.method == :get and
               route.route == "/organizations/:organization_id/webhooks/provider_events/secret" and
               route.action == :get_provider_events_webhook_secret
           end)

    conn =
      Plug.Test.conn(
        :get,
        "/organizations/org-1/webhooks/provider_events/secret"
      )
      |> Ash.PlugHelpers.set_tenant("org-1")
      |> ApiRouter.call(ApiRouter.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "secret-org-1"
  end

  defp sign(body), do: :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

  def secret, do: {:ok, @secret}

  def resolve_secret(organization_id, _inbound, _context),
    do: {:ok, "secret-#{organization_id}"}
end
