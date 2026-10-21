defmodule DomainContract.UIPhoenixTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Plug.Test, only: [init_test_session: 2]
  @endpoint __MODULE__.Endpoint

  defmodule Counter do
    use Phoenix.LiveComponent
    use DomainContract.UI, entry: :live

    contract do
      version(1)
      responsibility("Owns a bounded mounted counter.")
      command(:increment, payload: %{amount: :integer})
      emit(:changed, payload: %{value: :integer})
    end

    attr(:id, :string, required: true)

    def live(assigns) do
      ~H"<.live_component module={__MODULE__} id={@id} />"
    end

    def update(assigns, socket) do
      socket = socket |> assign(assigns) |> assign_new(:count, fn -> 0 end)
      socket = DomainContract.UI.mount(socket, __MODULE__, socket.assigns.id)
      {:ok, socket}
    end

    def handle_command("increment", %{amount: amount}, socket) do
      socket = assign(socket, :count, socket.assigns.count + amount)
      {:ok, socket} = DomainContract.UI.emit(socket, :changed, %{value: socket.assigns.count})
      socket
    end

    def render(assigns), do: ~H"<span id={@id}>{@count}</span>"
  end

  defmodule Harness do
    use Phoenix.LiveView
    use DomainContract.UI
    on_mount(DomainContract.UI)

    contract do
      version(1)
      responsibility("Owns an active pair of counters and their notification projection.")
      consumes(Counter)
      subscribe(Counter, :changed)
    end

    def mount(_, _, socket), do: {:ok, assign(socket, :last, 0)}

    def handle_event("increment", _, socket) do
      :ok = DomainContract.UI.command({Counter, "counter-b"}, :increment, %{amount: 2})
      {:noreply, socket}
    end

    def handle_notification(Counter, "changed", %{value: value}, socket),
      do: assign(socket, :last, value)

    def render(assigns) do
      ~H"""
      <div>
        <Counter.live id="counter-a" />
        <Counter.live id="counter-b" />
        <button id="increment" phx-click="increment">Increment B</button>
        <output id="last">{@last}</output>
      </div>
      """
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :domain_contract
    socket("/live", Phoenix.LiveView.Socket)
    plug(Plug.Session, store: :cookie, key: "_contract_test", signing_salt: "contract")
  end

  setup_all do
    Application.put_env(:domain_contract, Endpoint,
      secret_key_base: String.duplicate("a", 64),
      live_view: [signing_salt: "contract"],
      pubsub_server: DomainContract.TestPubSub
    )

    start_supervised!({Phoenix.PubSub, name: DomainContract.TestPubSub})
    start_supervised!(Endpoint)
    :ok
  end

  setup do
    :ok =
      DomainContract.SchemaStore.replace(
        self(),
        DomainContract.Schemas.index(
          Enum.map([Counter, Harness], &DomainContract.Info.canonical/1)
        )
      )

    :ok
  end

  test "real Phoenix lifecycle relays addressed commands and subscription-only delivery" do
    conn = Phoenix.ConnTest.build_conn() |> init_test_session(%{})
    {:ok, view, _} = live_isolated(conn, Harness)
    assert has_element?(view, "#counter-a", "0")
    view |> element("#increment") |> render_click()
    assert has_element?(view, "#counter-a", "0")
    assert has_element?(view, "#counter-b", "2")
    assert has_element?(view, "#last", "2")
  end
end
