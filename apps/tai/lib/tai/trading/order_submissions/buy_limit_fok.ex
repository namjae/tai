defmodule Tai.Trading.OrderSubmissions.BuyLimitFok do
  @type venue_id :: Tai.Venue.id()
  @type account_id :: Tai.Venue.account_id()
  @type product_symbol :: Tai.Venues.Product.symbol()
  @type product_type :: Tai.Venues.Product.type()
  @type callback :: Tai.Trading.Order.callback()
  @type t :: %Tai.Trading.OrderSubmissions.BuyLimitFok{
          venue_id: venue_id,
          account_id: account_id,
          product_symbol: product_symbol,
          product_type: product_type,
          price: Decimal.t(),
          qty: Decimal.t(),
          close: boolean | nil,
          order_updated_callback: callback
        }

  @enforce_keys ~w(
    venue_id
    account_id
    product_symbol
    product_type
    price
    qty
  )a
  defstruct ~w(
    venue_id
    account_id
    product_symbol
    product_type
    price
    qty
    close
    order_updated_callback
  )a
end
