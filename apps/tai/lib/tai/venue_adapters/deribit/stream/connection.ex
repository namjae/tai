defmodule Tai.VenueAdapters.Deribit.Stream.Connection do
  use WebSockex
  alias Tai.{Events, VenueAdapters.Deribit.Stream}

  defmodule State do
    @type product :: Tai.Venues.Product.t()
    @type venue :: Tai.Venue.id()
    @type credential_id :: Tai.Venue.credential_id()
    @type channel_name :: atom
    @type route :: :order_books
    @type jsonrpc_id :: integer
    @type t :: %State{
            venue: venue,
            routes: %{required(route) => atom},
            channels: [channel_name],
            credential: {credential_id, map} | nil,
            products: [product],
            quote_depth: pos_integer,
            opts: map,
            last_heartbeat: pos_integer,
            jsonrpc_id: jsonrpc_id,
            jsonrpc_requests: %{
              optional(jsonrpc_id) => pos_integer
            }
          }

    @enforce_keys ~w(
      venue
      routes
      channels
      products
      quote_depth
      opts
      jsonrpc_id
      jsonrpc_requests
    )a
    defstruct ~w(
      venue routes
      channels
      credential
      products
      quote_depth
      opts
      last_heartbeat
      jsonrpc_id
      jsonrpc_requests
    )a
  end

  @type product :: Tai.Venues.Product.t()
  @type venue :: Tai.Venue.id()
  @type credential_id :: Tai.Venue.credential_id()
  @type credential :: Tai.Venue.credential()
  @type venue_msg :: map

  @spec start_link(
          url: String.t(),
          venue: venue,
          credential: {credential_id, credential} | nil,
          products: [product],
          quote_depth: pos_integer,
          opts: map
        ) :: {:ok, pid} | {:error, term}
  def start_link(
        url: url,
        venue: venue,
        channels: channels,
        credential: credential,
        products: products,
        quote_depth: quote_depth,
        opts: opts
      ) do
    routes = %{
      order_books: venue |> Stream.RouteOrderBooks.to_name()
    }

    state = %State{
      venue: venue,
      routes: routes,
      channels: channels,
      credential: credential,
      products: products,
      quote_depth: quote_depth,
      opts: opts,
      jsonrpc_id: 1,
      jsonrpc_requests: %{}
    }

    name = venue |> to_name
    headers = []
    WebSockex.start_link(url, __MODULE__, state, name: name, extra_headers: headers)
  end

  @spec to_name(venue) :: atom
  def to_name(venue), do: :"#{__MODULE__}_#{venue}"

  def handle_connect(_conn, state) do
    Events.info(%Events.StreamConnect{venue: state.venue})
    send(self(), :init_subscriptions)
    {:ok, state}
  end

  def handle_disconnect(conn_status, state) do
    Events.info(%Events.StreamDisconnect{
      venue: state.venue,
      reason: conn_status.reason
    })

    {:ok, state}
  end

  def handle_info(:init_subscriptions, state) do
    send(self(), {:subscribe, :heartbeat})
    send(self(), {:subscribe, :depth})
    if state.credential, do: send(self(), {:subscribe, :authenticate})
    {:ok, state}
  end

  @heartbeat_interval_s 10
  def handle_info({:subscribe, :heartbeat}, state) do
    msg =
      %{
        method: "public/set_heartbeat",
        id: state.jsonrpc_id,
        params: %{
          interval: @heartbeat_interval_s
        }
      }
      |> Jason.encode!()

    state =
      state
      |> add_jsonrpc_request()
      |> Map.put(:last_heartbeat, :os.system_time(:millisecond))

    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :depth}, state) do
    channels = state.products |> Enum.map(&"book.#{&1.venue_symbol}.none.20.100ms")

    msg =
      %{
        method: "public/subscribe",
        id: state.jsonrpc_id,
        params: %{
          channels: channels
        }
      }
      |> Jason.encode!()

    state = state |> add_jsonrpc_request()

    {:reply, {:text, msg}, state}
  end

  def handle_info({:subscribe, :authenticate}, state) do
    data = ""
    timestamp = ExDeribit.Auth.timestamp()
    nonce = ExDeribit.Auth.nonce()
    {_, credential} = state.credential
    signature = ExDeribit.Auth.sign(credential.client_secret, timestamp, nonce, data)

    msg =
      %{
        method: "public/auth",
        id: state.jsonrpc_id,
        params: %{
          grant_type: "client_signature",
          client_id: credential.client_id,
          timestamp: timestamp,
          signature: signature,
          nonce: nonce,
          data: data
        }
      }
      |> Jason.encode!()

    state = state |> add_jsonrpc_request()

    {:reply, {:text, msg}, state}
  end

  def handle_frame({:text, msg}, state) do
    msg
    |> Jason.decode!()
    |> handle_msg(state)
  end

  def handle_frame(_frame, state), do: {:ok, state}

  defp handle_msg(
         %{"id" => id, "result" => %{"access_token" => access_token}},
         state
       ) do
    # TODO: These assets need to come from accounts
    # channels = state.products |> Enum.map(&"user.portfolio.#{&1.venue_symbol}")
    channels = ["btc", "eth"] |> Enum.map(&"user.portfolio.#{&1}")

    msg =
      %{
        method: "private/subscribe",
        id: state.jsonrpc_id,
        params: %{
          access_token: access_token,
          channels: channels
        }
      }
      |> Jason.encode!()

    state =
      state
      |> delete_jsonrpc_request(id)
      |> add_jsonrpc_request()

    require Logger
    Logger.info("&&&&&&&&&&&&&&&&& public auth response. private/subscribe msg: #{inspect(msg)}")

    {:reply, {:text, msg}, state}
  end

  defp handle_msg(%{"id" => id, "result" => _} = msg, state) do
    require Logger
    Logger.info("*********** result msg: #{inspect(msg)}")

    state = delete_jsonrpc_request(state, id)
    {:ok, state}
  end

  defp handle_msg(
         %{
           "method" => "subscription",
           "params" => %{"channel" => "book." <> _channel}
         } = msg,
         state
       ) do
    msg |> forward(:order_books, state)
    {:ok, state}
  end

  @heartbeat_interval_timeout_ms 15000
  defp handle_msg(
         %{
           "method" => "heartbeat",
           "params" => %{"type" => "heartbeat"}
         },
         state
       ) do
    now = :os.system_time(:millisecond)
    diff = now - state.last_heartbeat
    state = Map.put(state, :last_heartbeat, now)

    if diff > @heartbeat_interval_timeout_ms do
      {:close, state}
    else
      {:ok, state}
    end
  end

  defp handle_msg(
         %{
           "method" => "heartbeat",
           "params" => %{"type" => "test_request"}
         },
         state
       ) do
    msg =
      %{method: "public/test", id: state.jsonrpc_id}
      |> Jason.encode!()

    state = state |> add_jsonrpc_request()

    {:reply, {:text, msg}, state}
  end

  defp handle_msg(
         %{
           "params" => %{
             "data" => _data,
             "channel" => "user.portfolio." <> _venue_asset
           },
           "method" => "subscription"
         } = msg,
         state
       ) do
    require Logger
    Logger.info("----------------- User portfolio - msg: #{inspect(msg)}")

    {:ok, state}
  end

  defp handle_msg(msg, state) do
    require Logger
    Logger.info("================= CATCH ALL - msg: #{inspect(msg)}")

    {:ok, state}
  end

  defp forward(msg, to, state) do
    state.routes
    |> Map.fetch!(to)
    |> GenServer.cast({msg, Timex.now()})
  end

  defp add_jsonrpc_request(state) do
    jsonrpc_requests =
      state.jsonrpc_requests
      |> Map.put(state.jsonrpc_id, :os.system_time(:millisecond))

    state
    |> Map.put(:jsonrpc_id, state.jsonrpc_id + 1)
    |> Map.put(:jsonrpc_requests, jsonrpc_requests)
  end

  defp delete_jsonrpc_request(state, id) do
    jsonrpc_requests = Map.delete(state.jsonrpc_requests, id)
    Map.put(state, :jsonrpc_requests, jsonrpc_requests)
  end
end
