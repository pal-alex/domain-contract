defmodule DomainContract.Type do
  @moduledoc false

  # Encode types before JSON encoding erases the distinction between atom and
  # string map keys. This describes the boundary; it never rewrites values.
  def encode(fields) when is_map(fields) do
    keys = Map.keys(fields)

    mode =
      cond do
        Enum.all?(keys, &is_atom/1) -> "atoms"
        Enum.all?(keys, &is_binary/1) -> "strings"
        true -> raise ArgumentError, "contract map keys must be all atoms or all strings"
      end

    ["map", mode, Map.new(fields, fn {key, type} -> {to_string(key), encode(type)} end)]
  end

  def encode({:enum, values}), do: {:enum, values}

  def encode({:variant, choices}),
    do: ["variant", Map.new(choices, fn {tag, type} -> {to_string(tag), encode(type)} end)]

  def encode({:struct, Date}),
    do: encode({:struct, Date, date_fields()})

  def encode({:struct, Time}),
    do: encode({:struct, Time, time_fields()})

  def encode({:struct, NaiveDateTime}),
    do: encode({:struct, NaiveDateTime, Map.merge(date_fields(), time_fields())})

  def encode({:struct, DateTime}) do
    fields = Map.merge(date_fields(), time_fields())

    encode(
      {:struct, DateTime,
       Map.merge(fields, %{
         time_zone: :string,
         zone_abbr: :string,
         utc_offset: :integer,
         std_offset: :integer
       })}
    )
  end

  def encode({:struct, module, fields}),
    do: ["struct", to_string(module), encode(fields)]

  def encode({:tuple, types}), do: ["tuple", Enum.map(types, &encode/1)]
  def encode({:union, types}), do: union(types)
  def encode(["union", types]), do: union(types)

  def encode({kind, type}) when kind in [:list, :dictionary, :nullable],
    do: [to_string(kind), encode(type)]

  def encode(value), do: value

  # Imported error unions describe the same alternatives at every caller.
  # Flatten their schema once instead of multiplying it through process chains.
  defp union(types) do
    alternatives =
      types
      |> Enum.flat_map(fn type ->
        case encode(type) do
          ["union", nested] -> nested
          alternative -> [alternative]
        end
      end)
      |> Enum.uniq_by(&DomainContract.Info.normalize/1)

    ["union", alternatives]
  end

  defp date_fields,
    do: %{year: :integer, month: :integer, day: :integer, calendar: {:enum, [Calendar.ISO]}}

  defp time_fields,
    do: %{
      hour: :integer,
      minute: :integer,
      second: :integer,
      microsecond: {:tuple, [:integer, :integer]},
      calendar: {:enum, [Calendar.ISO]}
    }
end
