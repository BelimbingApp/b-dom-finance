defmodule Bilimbi.Finance.Payroll.Reason do
  @moduledoc false
  # A change's or reversal's reason as the facade keeps it: trimmed, and nil
  # when blank.

  def trim(nil), do: nil

  def trim(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def trim(other), do: other
end
