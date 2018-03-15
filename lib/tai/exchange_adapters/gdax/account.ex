defmodule Tai.ExchangeAdapters.Gdax.Account do
  @moduledoc """
  Execute private exchange actions for the GDAX account
  """

  use GenServer

  alias Tai.Exchanges.Account
  alias Tai.ExchangeAdapters.Gdax.Account.{Balance, CancelOrder, Orders, OrderStatus}

  def start_link(exchange_id) do
    GenServer.start_link(__MODULE__, exchange_id, name: exchange_id |> Account.to_name)
  end

  def init(exchange_id) do
    {:ok, exchange_id}
  end

  def handle_call(:balance, _from, state) do
    {:reply, Balance.fetch, state}
  end

  def handle_call({:buy_limit, symbol, price, size}, _from, state) do
    response = Orders.buy_limit(symbol, price, size)
    {:reply, response, state}
  end

  def handle_call({:sell_limit, symbol, price, size}, _from, state) do
    response = Orders.sell_limit(symbol, price, size)
    {:reply, response, state}
  end

  def handle_call({:order_status, order_id}, _from, state) do
    response = OrderStatus.fetch(order_id)
    {:reply, response, state}
  end

  def handle_call({:cancel_order, order_id}, _from, state) do
    response = CancelOrder.execute(order_id)
    {:reply, response, state}
  end
end