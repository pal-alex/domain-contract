defmodule DomainContract.UI do
  @moduledoc """
  Phoenix contracts with native attr/slot declarations as the only prop source.
  Mount participants in their parent LiveView process. Delivery is local and
  ephemeral; successful dispatch acknowledges acceptance, not completed handling.
  Remove addressed participants with unmount/2 when the parent removes them.
  All registrations disappear with the LiveView process. Iframe protocols are separate.
  """
  unless Code.ensure_loaded?(Phoenix.LiveView) do
    @compile {:no_warn_undefined, Phoenix.LiveView}
  end

  alias DomainContract.Info
  alias DomainContract.Reference
  alias DomainContract.Runtime
  @participants {__MODULE__, :participants}
  @token {__MODULE__, :token}

  defmacro __using__(options) do
    quote do
      use DomainContract
      @domain_contract_ui true
      @domain_contract_ui_entry unquote(options[:entry])
      @domain_contract_prop_modes unquote(options[:prop_modes] || [])
      @before_compile DomainContract.UI
    end
  end

  @doc false
  def compile_props(module, artifact) do
    if Module.get_attribute(module, :domain_contract_ui) do
      components = Module.get_attribute(module, :__components__) || %{}
      entry = Module.get_attribute(module, :domain_contract_ui_entry)
      public = if entry, do: Map.take(components, [entry]), else: Map.drop(components, [:render])

      if map_size(public) > 1,
        do: raise(ArgumentError, "one contracted public component per module; specify entry:")

      props = Enum.flat_map(public, fn {_, c} -> c.attrs end)
      slots = Enum.flat_map(public, fn {_, c} -> c.slots end)
      modes = Module.get_attribute(module, :domain_contract_prop_modes)

      props =
        Enum.map(props, fn attr ->
          type =
            case attr.type do
              {:struct, _} -> "map"
              type when is_atom(type) -> to_string(type)
            end

          type = if attr.opts[:values], do: ["enum", attr.opts[:values]], else: type

          prop = %{
            "name" => to_string(attr.name),
            "type" => type,
            "required" => attr.required,
            "mode" => to_string(Keyword.get(modes, attr.name, :initial))
          }

          if Keyword.has_key?(attr.opts, :default),
            do: Map.put(prop, "default", attr.opts[:default]),
            else: prop
        end)

      Map.merge(artifact, %{
        "kind" => "ui",
        "props" => props,
        "slots" => Enum.map(slots, &%{"name" => to_string(&1.name), "required" => &1.required})
      })
    else
      artifact
    end
  end

  defmacro __before_compile__(env) do
    if Module.defines?(env.module, {:update, 2}, :def) do
      Module.make_overridable(env.module, [{:update, 2}])

      quote do
        def update(%{__domain_contract__: envelope}, socket),
          do: {:ok, DomainContract.UI.receive_message(__MODULE__, envelope, socket)}

        def update(assigns, socket), do: super(assigns, socket)
      end
    end
  end

  defmacro command(address, name, payload) do
    owner = DomainContract.Owned.owner(__CALLER__)

    case address do
      {target, _id} -> DomainContract.Owned.record(__CALLER__, target, :commands, name)
      _ -> :ok
    end

    quote do
      DomainContract.UI.dispatch_command(
        unquote(owner),
        unquote(address),
        unquote(name),
        unquote(payload)
      )
    end
  end

  defmacro emit(socket, name, payload) do
    owner = DomainContract.Owned.owner(__CALLER__)
    DomainContract.Owned.record(__CALLER__, owner, :notifications, name)

    quote do
      DomainContract.UI.dispatch_event(
        unquote(owner),
        unquote(socket),
        unquote(name),
        unquote(payload)
      )
    end
  end

  @doc "Attaches relay delivery to a parent LiveView and registers its public owner."
  def on_mount(:default, _params, _session, socket) do
    socket = Phoenix.LiveView.attach_hook(socket, __MODULE__, :handle_info, &relay/2)
    socket = mount(socket, socket.view, nil, :view)
    {:cont, socket}
  end

  @doc "Registers one active addressed participant in the current LiveView process."
  def mount(socket, module, id, kind \\ :component) when kind in [:component, :view, :context] do
    contract = Reference.resolve(module)
    token()

    Process.put(
      @participants,
      Map.put(participants(), {module, id}, %{contract: contract, kind: kind})
    )

    socket
  end

  def unmount(module, id),
    do: Process.put(@participants, Map.delete(participants(), {module, id}))

  def dispatch_command(owner, {module, id}, name, payload) do
    with {:ok, ref} <- Runtime.dependency(owner, module),
         {:ok, message} <- message(ref["definition"], "commands", name),
         :ok <- Runtime.validate_type(message["payload"], payload, ref["definition"]["entities"]),
         {:ok, target} <- Map.fetch(participants(), {module, id}),
         :ok <- DomainContract.Compatibility.satisfies(target.contract, ref["definition"]) do
      send(self(), {__MODULE__, token(), {module, id}, {:command, to_string(name), payload}})
      :ok
    else
      :error -> {:error, :unmounted}
      error -> error
    end
  end

  def dispatch_event(owner, socket, name, payload) do
    contract = Reference.resolve(owner)

    with true <- Enum.any?(participants(), fn {{module, _}, _} -> module == owner end),
         {:ok, event} <- message(contract, "notifications", name),
         :ok <- Runtime.validate_type(event["payload"], payload, contract["entities"]) do
      participants()
      |> Enum.each(fn {address, target} ->
        subscriptions =
          Enum.filter(
            target.contract["subscriptions"],
            &(&1["module"] == contract["module"] and &1["name"] == to_string(name))
          )

        Enum.each(subscriptions, fn subscription ->
          required = subscription["definition"]

          unless DomainContract.Compatibility.subset?(
                   event["payload"],
                   required["payload"],
                   contract["entities"],
                   required["entities"]
                 ),
                 do: raise(ArgumentError, "incompatible active notification subscription")

          send(
            self(),
            {__MODULE__, token(), address, {:notification, owner, to_string(name), payload}}
          )
        end)
      end)

      {:ok, socket}
    else
      false -> {:error, :unmounted_emitter}
      error -> error
    end
  end

  def relay({__MODULE__, secret, address, message}, socket) do
    if secret != token(), do: raise(ArgumentError, "untrusted UI contract envelope")

    case Map.fetch(participants(), address) do
      {:ok, %{kind: :component}} ->
        {module, id} = address
        Phoenix.LiveView.send_update(module, id: id, __domain_contract__: {secret, message})
        {:halt, socket}

      {:ok, _} ->
        {module, _} = address
        {:halt, receive_message(module, {secret, message}, socket)}

      :error ->
        {:halt, socket}
    end
  end

  def relay(_, socket), do: {:cont, socket}

  def receive_message(module, {secret, {:command, name, payload}}, socket) do
    if secret != token(), do: raise(ArgumentError, "untrusted UI contract envelope")
    contract = Reference.resolve(module)
    {:ok, command} = message(contract, "commands", name)
    :ok = Runtime.validate_type(command["payload"], payload, contract["entities"])
    module.handle_command(name, payload, socket)
  end

  def receive_message(module, {secret, {:notification, emitter, name, payload}}, socket) do
    if secret != token(), do: raise(ArgumentError, "untrusted UI contract envelope")
    contract = Reference.resolve(module)

    subscription =
      Enum.find(
        contract["subscriptions"],
        &(&1["module"] == Atom.to_string(emitter) and &1["name"] == name)
      ) || raise ArgumentError, "undeclared subscription"

    definition = subscription["definition"]
    :ok = Runtime.validate_type(definition["payload"], payload, definition["entities"])
    module.handle_notification(emitter, name, payload, socket)
  end

  def validate_props(module, props, phase \\ :initial) when phase in [:initial, :controlled] do
    contract = Info.canonical(module)
    props = Map.new(props, fn {k, v} -> {to_string(k), v} end)
    declared = contract["props"]
    unknown = Map.keys(props) -- Enum.map(declared, & &1["name"])

    if unknown != [],
      do: {:error, {:invalid_props, unknown}},
      else:
        Enum.reduce_while(declared, :ok, fn prop, _ ->
          result =
            cond do
              Map.has_key?(props, prop["name"]) ->
                Runtime.validate_type(prop["type"], props[prop["name"]], contract["entities"])

              phase == :initial and prop["required"] ->
                {:error, {:missing_prop, prop["name"]}}

              true ->
                :ok
            end

          if result == :ok, do: {:cont, :ok}, else: {:halt, result}
        end)
  end

  defp message(contract, key, name) do
    case Enum.find(contract[key], &(&1["name"] == to_string(name))) do
      nil -> {:error, {:invalid_contract, :unknown_message}}
      message -> {:ok, message}
    end
  end

  defp participants, do: Process.get(@participants, %{})

  defp token do
    case Process.get(@token) do
      nil ->
        token = make_ref()
        Process.put(@token, token)
        token

      token ->
        token
    end
  end
end
