defmodule Bilimbi.Finance.Einvoice.QrCode do
  @moduledoc """
  The QR code a printed or shown document carries: the authority's
  validation link, as an inline SVG the page embeds (Guideline §2.4.4).
  `EQRCode` encodes; the SVG carries no script or external resource.
  """

  @doc "An SVG of the QR code for `text`, `size` pixels wide, or `nil` for a blank text."
  @spec svg(String.t() | nil, pos_integer()) :: String.t() | nil
  def svg(text, size \\ 160)
  def svg(nil, _size), do: nil
  def svg("", _size), do: nil

  def svg(text, size) when is_binary(text) and is_integer(size) and size > 0 do
    text
    |> EQRCode.encode()
    |> EQRCode.svg(width: size, viewbox: true, background_color: "#ffffff", color: "#000000")
  end
end
