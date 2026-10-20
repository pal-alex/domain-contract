defmodule DomainContract.Owned do
  @moduledoc "Private helpers and hooks inherit their public owner's dependency restrictions."
  defmacro __using__(owner: owner) do
    owner = Macro.expand(owner, __CALLER__)

    quote do
      @domain_contract_owner unquote(owner)
      Module.register_attribute(__MODULE__, :domain_contract_calls, accumulate: true)
      require DomainContract
      require DomainContract.UI
      @before_compile DomainContract.Owned
    end
  end

  @doc false
  def owner(env), do: Module.get_attribute(env.module, :domain_contract_owner) || env.module

  def record(env, target, surface, name) do
    target = Macro.expand(target, env)
    name = Macro.expand(name, env)

    if is_atom(target) and (is_atom(name) or is_binary(name)) do
      Module.put_attribute(
        env.module,
        :domain_contract_calls,
        {target, to_string(surface), to_string(name), env.line}
      )
    end
  end

  def validate(env, artifact) do
    for {target, surface, name, line} <-
          Module.get_attribute(env.module, :domain_contract_calls) || [] do
      provider =
        if Atom.to_string(target) == artifact["module"] and surface == "notifications" do
          artifact
        else
          reference = Enum.find(artifact["consumes"], &(&1["module"] == Atom.to_string(target)))

          unless reference,
            do:
              raise(CompileError,
                file: env.file,
                line: line,
                description: "undeclared dependency #{inspect(target)} for #{inspect(env.module)}"
              )

          reference["definition"]
        end

      unless Enum.any?(provider[surface], &(&1["name"] == name)),
        do:
          raise(CompileError,
            file: env.file,
            line: line,
            description: "undeclared #{surface} #{inspect(target)}.#{name}"
          )
    end

    :ok
  end

  defmacro __before_compile__(env) do
    owner = owner(env)
    validate(env, DomainContract.Reference.resolve(owner))

    quote do
      Module.register_attribute(__MODULE__, :domain_contract_owner_metadata, persist: true)
      @domain_contract_owner_metadata unquote(owner)
    end
  end
end
