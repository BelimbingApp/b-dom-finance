defmodule Bilimbi.Finance.Sst.Text do
  @moduledoc false

  @doc "Trimmed text, or nil when nothing is left."
  def blank_to_nil(nil), do: nil

  def blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
