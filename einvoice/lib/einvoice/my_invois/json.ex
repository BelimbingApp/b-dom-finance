defmodule Bilimbi.Finance.Einvoice.MyInvois.Json do
  @moduledoc """
  Order-preserving, minified JSON for UBL documents.

  The authority hashes and signs a document's exact bytes, so an object's
  key order and a number's written form must survive a decode and an
  encode. Objects are `Jason.OrderedObject`s and numbers are written as
  their decimal text, never through a float: `1500.0` stays `1500.0`.
  """

  @doc "An ordered object from `{key, value}` pairs, leaving out nil values and empty lists."
  @spec object([{String.t(), term()}]) :: Jason.OrderedObject.t()
  def object(pairs) do
    %Jason.OrderedObject{values: Enum.reject(pairs, fn {_key, value} -> empty?(value) end)}
  end

  @doc """
  The UBL JSON form of a basic value: `[{"_": value, attribute: ...}]`, or
  nil when the value is nil. Decimals and integers are written as numbers.
  """
  @spec value(term(), [{String.t(), term()}]) :: [Jason.OrderedObject.t()] | nil
  def value(value, attributes \\ [])
  def value(nil, _attributes), do: nil
  def value(value, attributes), do: [object([{"_", number(value)} | attributes])]

  @doc "Writes a decimal as a JSON number in its own decimal text."
  @spec number(term()) :: term()
  def number(%Decimal{} = value), do: Jason.Fragment.new(Decimal.to_string(value, :normal))
  def number(value), do: value

  @doc "Minified JSON bytes."
  @spec encode!(term()) :: binary()
  def encode!(term), do: Jason.encode!(term)

  @doc "Decodes JSON keeping key order and each number's decimal text."
  @spec decode!(binary()) :: term()
  def decode!(json) when is_binary(json) do
    json
    |> Jason.decode!(objects: :ordered_objects, floats: :decimals)
    |> numbers_as_text()
  end

  defp numbers_as_text(%Jason.OrderedObject{values: values}),
    do: %Jason.OrderedObject{values: Enum.map(values, fn {k, v} -> {k, numbers_as_text(v)} end)}

  defp numbers_as_text(list) when is_list(list), do: Enum.map(list, &numbers_as_text/1)
  defp numbers_as_text(%Decimal{} = value), do: number(value)
  defp numbers_as_text(value), do: value

  @doc "The value under `key` in an ordered object, or nil."
  @spec get(Jason.OrderedObject.t(), String.t()) :: term()
  def get(%Jason.OrderedObject{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {^key, value} -> value
      nil -> nil
    end
  end

  @doc "The object without `keys`."
  @spec drop(Jason.OrderedObject.t(), [String.t()]) :: Jason.OrderedObject.t()
  def drop(%Jason.OrderedObject{values: values}, keys),
    do: %Jason.OrderedObject{values: Enum.reject(values, fn {key, _} -> key in keys end)}

  @doc "The object with `pairs` appended after its existing keys."
  @spec append(Jason.OrderedObject.t(), [{String.t(), term()}]) :: Jason.OrderedObject.t()
  def append(%Jason.OrderedObject{values: values}, pairs),
    do: %Jason.OrderedObject{values: values ++ pairs}

  @doc "The object with `key`'s value replaced by `fun.(value)`."
  @spec update!(Jason.OrderedObject.t(), String.t(), (term() -> term())) ::
          Jason.OrderedObject.t()
  def update!(%Jason.OrderedObject{values: values} = object, key, fun) do
    unless List.keymember?(values, key, 0), do: raise(KeyError, key: key, term: object)

    %Jason.OrderedObject{
      values: Enum.map(values, fn {k, v} -> if k == key, do: {k, fun.(v)}, else: {k, v} end)
    }
  end

  defp empty?(nil), do: true
  defp empty?([]), do: true
  defp empty?(_value), do: false
end
