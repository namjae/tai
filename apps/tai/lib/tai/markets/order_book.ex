defmodule Tai.Markets.OrderBook do
  @moduledoc """
  Manage price points for a venue's order book
  """

  use GenServer
  alias __MODULE__

  defmodule ChangeSet do
    @type venue_id :: Tai.Venue.id()
    @type product_symbol :: Tai.Venues.Product.symbol()
    @type side :: :bid | :ask
    @type price :: number
    @type size :: number
    @type upsert :: {:upsert, side, price, size}
    @type delete :: {:delete, side, price}
    @type change :: upsert | delete
    @type t :: %ChangeSet{
            venue: venue_id,
            symbol: product_symbol,
            changes: [change],
            last_received_at: DateTime.t(),
            last_venue_timestamp: DateTime.t() | nil
          }

    @enforce_keys ~w(venue symbol changes last_received_at)a
    defstruct ~w(venue symbol changes last_received_at last_venue_timestamp)a
  end

  @type venue_id :: Tai.Venue.id()
  @type product :: Tai.Venues.Product.t()
  @type product_symbol :: Tai.Venues.Product.symbol()
  @type price :: number
  @type qty :: number
  @type t :: %OrderBook{
          broadcast_change_set: boolean,
          venue_id: venue_id,
          product_symbol: product_symbol,
          bids: %{optional(price) => qty},
          asks: %{optional(price) => qty},
          last_change_set: ChangeSet.t(),
          last_received_at: DateTime.t(),
          last_venue_timestamp: DateTime.t() | nil
        }

  @enforce_keys ~w(
    venue_id
    product_symbol
    bids
    asks
  )a
  defstruct ~w(
    broadcast_change_set
    venue_id
    product_symbol
    bids
    asks
    last_change_set
    last_received_at
    last_venue_timestamp
  )a

  @spec child_spec(product, boolean) :: Supervisor.child_spec()
  def child_spec(product, broadcast_change_set) do
    %{
      id: to_name(product.venue_id, product.symbol),
      start:
        {__MODULE__, :start_link,
         [[product: product, broadcast_change_set: broadcast_change_set]]}
    }
  end

  @spec start_link(product: product, broadcast_change_set: boolean) :: GenServer.on_start()
  def start_link(product: product, broadcast_change_set: broadcast_change_set) do
    name = to_name(product.venue_id, product.symbol)

    state = %OrderBook{
      venue_id: product.venue_id,
      product_symbol: product.symbol,
      bids: %{},
      asks: %{},
      broadcast_change_set: broadcast_change_set
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  @spec to_name(venue_id, product_symbol) :: atom
  def to_name(venue, symbol), do: :"#{__MODULE__}_#{venue}_#{symbol}"

  @spec replace(ChangeSet.t()) :: :ok
  def replace(%OrderBook.ChangeSet{} = change_set) do
    change_set.venue
    |> OrderBook.to_name(change_set.symbol)
    |> GenServer.cast({:replace, change_set})
  end

  @spec apply(ChangeSet.t()) :: term
  def apply(%ChangeSet{} = change_set) do
    change_set.venue
    |> OrderBook.to_name(change_set.symbol)
    |> GenServer.cast({:apply, change_set})
  end

  def init(state), do: {:ok, state}

  def handle_cast({:replace, %OrderBook.ChangeSet{} = change_set}, state) do
    new_state =
      %{
        state
        | bids: %{},
          asks: %{},
          last_change_set: change_set,
          last_received_at: change_set.last_received_at,
          last_venue_timestamp: change_set.last_venue_timestamp
      }
      |> apply_changes(change_set.changes)

    change_set.venue
    |> Tai.Markets.ProcessQuote.to_name(change_set.symbol)
    |> GenServer.cast({:order_book_snapshot, new_state, change_set})

    if new_state.broadcast_change_set do
      {:noreply, new_state, {:continue, :broadcast_change_set}}
    else
      {:noreply, new_state}
    end
  end

  def handle_cast({:apply, change_set}, state) do
    new_state =
      %{
        state
        | last_change_set: change_set,
          last_received_at: change_set.last_received_at,
          last_venue_timestamp: change_set.last_venue_timestamp
      }
      |> apply_changes(change_set.changes)

    change_set.venue
    |> Tai.Markets.ProcessQuote.to_name(change_set.symbol)
    |> GenServer.cast({:order_book_apply, new_state, change_set})

    if new_state.broadcast_change_set do
      {:noreply, new_state, {:continue, :broadcast_change_set}}
    else
      {:noreply, new_state}
    end
  end

  def handle_continue(:broadcast_change_set, state) do
    msg = {:change_set, state.last_change_set}

    {:change_set, state.venue_id, state.product_symbol}
    |> Tai.PubSub.broadcast(msg)

    :change_set
    |> Tai.PubSub.broadcast(msg)

    {:noreply, state}
  end

  defp apply_changes(book, changes) do
    changes
    |> Enum.reduce(
      book,
      fn
        {:upsert, :bid, price, size}, acc ->
          new_bids = acc.bids |> Map.put(price, size)
          Map.put(acc, :bids, new_bids)

        {:upsert, :ask, price, size}, acc ->
          new_bids = acc.asks |> Map.put(price, size)
          Map.put(acc, :asks, new_bids)

        {:delete, :bid, price}, acc ->
          new_bids = acc.bids |> Map.delete(price)
          Map.put(acc, :bids, new_bids)

        {:delete, :ask, price}, acc ->
          new_asks = acc.asks |> Map.delete(price)
          Map.put(acc, :asks, new_asks)
      end
    )
  end
end
