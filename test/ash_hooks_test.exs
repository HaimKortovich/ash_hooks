defmodule AshHooksTest do
  use ExUnit.Case, async: true
  require Spark.Test

  defmodule Subject do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshHooks]

    attributes do
      uuid_primary_key :id
    end

    webhooks do
      inbound :mock do
        secret {AshHooksTest, :secret, []}
        event_id &AshHooksTest.extract_event_id/1
      end

      outbound :thing_changed do
        signing_mode :dual
      end
    end
  end

  def secret, do: {:ok, "test-secret"}

  def extract_event_id(_payload), do: {:ok, "evt_1"}

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

  defmodule ComplexEventResource do
    @signature_constraints [
      types: [
        signed: [type: SignedSignature, tag: :method, tag_value: "signed"],
        drawn: [type: DrawnSignature, tag: :method, tag_value: "drawn"]
      ]
    ]

    use Ash.Resource,
      domain: nil,
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
        provider(AshHooks.Provider.Mock)
        secret {AshHooksTest, :secret, []}

        event "application.completed" do
          action :complete
          attribute :applicant, Applicant, allow_nil?: false
          attribute :signature, :union, constraints: @signature_constraints, allow_nil?: false
        end
      end
    end
  end

  defmodule ComplexEventDomain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource ComplexEventResource
    end
  end

  defmodule EventResource do
    use Ash.Resource,
      domain: nil,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshHooks]

    attributes do
      uuid_primary_key :id
    end

    actions do
      action :complete, :map do
        argument :execution_id, :string, allow_nil?: false
        argument :quote_id, :string, allow_nil?: false
        argument :amount, :integer, allow_nil?: false
      end
    end

    webhooks do
      inbound :provider_events do
        provider(AshHooks.Provider.Mock)
        secret {AshHooksTest, :secret, []}
        identity(:execution_id)

        attribute :execution_id, :string, allow_nil?: false

        event "quote.completed" do
          action :complete

          attribute :quote_id, :string, allow_nil?: false
          attribute :amount, :integer, allow_nil?: false
        end
      end
    end
  end

  describe "DSL sections" do
    test "inbound entity parses with its options" do
      assert [%{name: :mock}, %{name: :thing_changed}] = AshHooks.Info.webhooks(Subject)
      inbound = AshHooks.Info.webhooks(Subject) |> Enum.find(&(&1.name == :mock))
      assert {AshHooksTest, :secret, []} = inbound.secret
      assert is_function(inbound.event_id)
      assert is_nil(inbound.replay_window_seconds)
      assert is_nil(inbound.provider)
    end

    test "outbound entity parses with its options" do
      outbound = AshHooks.Info.webhooks(Subject) |> Enum.find(&(&1.name == :thing_changed))
      assert outbound.signing_mode == :dual
    end

    test "inbound events compile against the current resource" do
      inbound = AshHooks.Info.inbound(EventResource, :provider_events)

      assert inbound.identity == :execution_id
      assert [%{name: :execution_id, type: :string, allow_nil?: false}] = inbound.attributes

      assert [%{name: :quote_completed, type: "quote.completed", action: :complete}] =
               inbound.events

      assert [
               %{name: :quote_id, type: :string, allow_nil?: false},
               %{name: :amount, type: :integer, allow_nil?: false}
             ] =
               hd(inbound.events).attributes
    end

    test "inbound event attributes are cast and required values are enforced" do
      inbound = AshHooks.Info.inbound(EventResource, :provider_events)
      event = hd(inbound.events)

      assert {:ok, %{execution_id: "exec-1", quote_id: "quote-1", amount: 42}} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "execution_id" => "exec-1",
                 "quote_id" => "quote-1",
                 "amount" => "42"
               })

      assert {:error, {:invalid_attribute, :quote_id, "is required"}} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{"execution_id" => "exec-1"})

      assert {:error, {:invalid_attribute, :amount, _reason}} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "execution_id" => "exec-1",
                 "quote_id" => "quote-1",
                 "amount" => "not-a-number"
               })
    end

    test "nested Ash.TypedStruct attributes are cast recursively" do
      inbound = AshHooks.Info.inbound(ComplexEventResource, :provider_events)
      event = hd(inbound.events)

      assert {:ok,
              %{
                applicant: %Applicant{
                  name: "Jane Doe",
                  address: %Address{city: "Panama City", postal_code: 800}
                },
                signature: %Ash.Union{
                  type: :signed,
                  value: %SignedSignature{method: "signed", signature_id: "sig-1"}
                }
              }} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "applicant" => %{
                   "name" => "Jane Doe",
                   "address" => %{"city" => "Panama City", "postal_code" => "800"}
                 },
                 "signature" => %{"method" => "signed", "signature_id" => "sig-1"}
               })

      assert {:error, {:invalid_attribute, :applicant, _reason}} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "applicant" => %{"name" => "Jane Doe", "address" => %{}}
               })
    end

    test "union attributes select and validate each typed variant" do
      inbound = AshHooks.Info.inbound(ComplexEventResource, :provider_events)
      event = hd(inbound.events)

      assert {:ok, %{signature: %Ash.Union{type: :drawn, value: %DrawnSignature{}}}} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "applicant" => %{
                   "name" => "Jane Doe",
                   "address" => %{"city" => "Panama City", "postal_code" => 800}
                 },
                 "signature" => %{
                   "method" => "drawn",
                   "image_url" => "https://example.test/signature.png"
                 }
               })

      assert {:error, {:invalid_attribute, :signature, _reason}} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "applicant" => %{
                   "name" => "Jane Doe",
                   "address" => %{"city" => "Panama City", "postal_code" => 800}
                 },
                 "signature" => %{"method" => "witnessed", "signature_id" => "sig-1"}
               })
    end

    test "nested structs and unions remain valid Ash action inputs" do
      inbound = AshHooks.Info.inbound(ComplexEventResource, :provider_events)
      event = hd(inbound.events)

      assert {:ok, arguments} =
               AshHooks.Inbound.Validator.validate(inbound, event, %{
                 "applicant" => %{
                   "name" => "Jane Doe",
                   "address" => %{"city" => "Panama City", "postal_code" => "800"}
                 },
                 "signature" => %{"method" => "signed", "signature_id" => "sig-1"}
               })

      input =
        Ash.ActionInput.for_action(ComplexEventResource, :complete, arguments,
          domain: ComplexEventDomain
        )

      assert {:ok, ^arguments} = Ash.run_action(input, authorize?: false)
    end

    test "an explicit provider option parses onto the entity" do
      defmodule ExplicitProvider do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :mock do
            provider(AshHooks.Provider.Mock)
            secret {AshHooksTest, :secret, []}
          end
        end
      end

      assert [%{provider: AshHooks.Provider.Mock}] = AshHooks.Info.webhooks(ExplicitProvider)
    end
  end

  describe "typed inbound event verifier" do
    test "rejects duplicate event wire types" do
      errors =
        Spark.Test.dsl_errors do
          defmodule DuplicateEventTypes do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            actions do
              action :complete, :map do
                argument :id, :string
              end
            end

            webhooks do
              inbound :provider_events do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}
                attribute :id, :string, allow_nil?: false

                event "quote.completed" do
                  action :complete
                end

                event "quote.completed" do
                  action :complete
                end
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "wire types must be unique"
    end

    test "requires an identity to reference a non-nullable inbound attribute" do
      errors =
        Spark.Test.dsl_errors do
          defmodule InvalidIdentity do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            actions do
              action :complete, :map do
                argument :id, :string
              end
            end

            webhooks do
              inbound :provider_events do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}
                identity(:missing)
                attribute :id, :string

                event "quote.completed" do
                  action :complete
                end
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "must reference an attribute"
    end

    test "requires update actions to declare their record attribute" do
      errors =
        Spark.Test.dsl_errors do
          defmodule RecordAction do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            actions do
              update :complete do
              end
            end

            webhooks do
              inbound :provider_events do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}

                event "quote.completed" do
                  action :complete
                end
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "update actions require `record :attribute`"
    end

    test "rejects events that do not provide every required action input" do
      errors =
        Spark.Test.dsl_errors do
          defmodule MissingActionInput do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            actions do
              action :complete, :map do
                argument :quote_id, :string, allow_nil?: false
              end
            end

            webhooks do
              inbound :provider_events do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}

                event "quote.completed" do
                  action :complete
                end
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "requires input :quote_id"
    end

    test "rejects an inbound attribute whose Ash type disagrees with the action" do
      errors =
        Spark.Test.dsl_errors do
          defmodule MismatchedActionInput do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            actions do
              action :complete, :map do
                argument :amount, :integer, allow_nil?: false
              end
            end

            webhooks do
              inbound :provider_events do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}

                event "quote.completed" do
                  action :complete
                  attribute :amount, :string, allow_nil?: false
                end
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "type :string"
      assert error.message =~ "expects"
    end

    test "rejects a nullable attribute for a required action input" do
      errors =
        Spark.Test.dsl_errors do
          defmodule NullableActionInput do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            actions do
              action :complete, :map do
                argument :amount, :integer, allow_nil?: false
              end
            end

            webhooks do
              inbound :provider_events do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}

                event "quote.completed" do
                  action :complete
                  attribute :amount, :integer
                end
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "cannot be supplied by a nullable"
    end
  end

  describe "replay-window-requires-timestamp verifier (fail-closed)" do
    # Verifier errors surface through Spark's after_verify collector, not as
    # raises at the defmodule site — assert via Spark.Test.dsl_errors.
    test "a replay window on a provider with no trustworthy timestamp is rejected" do
      errors =
        Spark.Test.dsl_errors do
          defmodule WindowedNoTimestamp do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [AshHooks]

            attributes do
              uuid_primary_key :id
            end

            webhooks do
              inbound :mock do
                provider(AshHooks.Provider.Mock)
                secret {AshHooksTest, :secret, []}
                replay_window_seconds 300
              end
            end
          end
        end

      assert [{_module, [%Spark.Error.DslError{} = error]}] = errors
      assert error.message =~ "trustworthy timestamp"
    end

    test "a replay window on a provider that declares a timestamp header compiles" do
      defmodule TimestampedProvider do
        @behaviour AshHooks.Provider

        def timestamp_header, do: "x-timestamp"
        def verify_signature(_raw_body, _ctx, _secret), do: :ok
        def parse_event_type(_payload), do: {:ok, :mock}
        def handle_event(_event_type, _payload), do: {:ok, %{}}
      end

      defmodule WindowedTimestamped do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :timestamped do
            provider(TimestampedProvider)
            secret {AshHooksTest, :secret, []}
            replay_window_seconds 300
          end
        end
      end

      assert [%{replay_window_seconds: 300}] = AshHooks.Info.webhooks(WindowedTimestamped)
    end

    test "replay_window_seconds accepts a positive integer" do
      defmodule Windowed do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :hubspot do
            secret {AshHooksTest, :secret, []}
            replay_window_seconds 300
          end
        end
      end

      assert [%{replay_window_seconds: 300}] = AshHooks.Info.webhooks(Windowed)
    end
  end

  describe "parse-time validation" do
    test "literal binary secrets are rejected at compile time" do
      assert_raise Spark.Error.DslError, ~r/literal binary/, fn ->
        defmodule BadSecret do
          use Ash.Resource,
            domain: nil,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks]

          attributes do
            uuid_primary_key :id
          end

          webhooks do
            inbound :mock do
              secret "super-secret-bytes"
            end
          end
        end
      end
    end
  end

  describe "Info accessors" do
    test "inbound/outbound are type-disambiguated on name collision" do
      defmodule Collide do
        use Ash.Resource,
          domain: nil,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          inbound :thing do
            secret {AshHooksTest, :secret, []}
          end

          outbound :thing do
            signing_mode :legacy
          end
        end
      end

      assert %AshHooks.Inbound{} = AshHooks.Info.inbound(Collide, :thing)
      assert %AshHooks.Outbound{signing_mode: :legacy} = AshHooks.Info.outbound(Collide, :thing)
      assert AshHooks.Info.inbound(Collide, :nonexistent) == nil
      assert AshHooks.Info.outbound(Collide, :nonexistent) == nil
    end
  end
end
