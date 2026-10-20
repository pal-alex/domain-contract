defmodule DomainContract.Compiler.Spark do
  @moduledoc false
  defmacro __before_compile__(env) do
    previous = Module.get_attribute(env.module, :opts)

    Module.put_attribute(
      env.module,
      :opts,
      Module.get_attribute(env.module, :domain_contract_spark_options)
    )

    # Compiler callbacks receive a Macro.Env value, unlike ordinary macro arguments.
    code = apply(Spark.Dsl, :"MACRO-__before_compile__", [__CALLER__, env])

    quote do
      unquote(code)
      @opts unquote(Macro.escape(previous))
    end
  end
end
