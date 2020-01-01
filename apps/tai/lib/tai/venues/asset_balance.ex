defmodule Tai.Venues.AssetBalance do
  @type venue_id :: Tai.Venue.id()
  @type account_id :: Tai.Venue.account_id()
  @type asset :: atom
  @type t :: %Tai.Venues.AssetBalance{
          venue_id: venue_id,
          account_id: account_id,
          asset: asset,
          type: String.t(),
          free: Decimal.t(),
          locked: Decimal.t()
        }

  @enforce_keys ~w(
    venue_id
    account_id
    asset
    type
    free
    locked
  )a
  defstruct ~w(
    venue_id
    account_id
    asset
    type
    free
    locked
  )a

  @spec total(balance :: t) :: Decimal.t()
  def total(%Tai.Venues.AssetBalance{free: free, locked: locked}) do
    Decimal.add(free, locked)
  end
end
