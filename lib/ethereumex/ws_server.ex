defmodule Ethereumex.WsServer do
  require Logger
  @moduledoc false

  use GenServer

  @timeout 60_000

  defmodule Socket do
    use WebSockex

    # TODO: handle disconnects - reconnect to socket and notify parent so subscriptions can be re-activated

    def start_link(url, parent) do
      Logger.debug("websocket server starting with url: #{url}")
      WebSockex.start_link(url, __MODULE__, parent, handle_initial_conn_failure: true)
    end

    def send_request(socket, request) do
      WebSockex.send_frame(socket, {:text, request})
    end

    def handle_frame({:text, msg}, parent) do
      Logger.debug("received message from socket: #{msg}")
      send(parent, {:response, msg})
      {:ok, parent}
    end

    def handle_connect(_conn, parent) do
      send(parent, :socket_connected)
      {:ok, parent}
    end

    def handle_disconnect(%{reason: {_, :normal}}, state) do
      Logger.debug("socket closing normally")
      {:ok, state}
    end
    def handle_disconnect(%{attempt_number: attempts}, state) do
      # attempt to reconnect
      if attempts > 3 do
        # still failing after 3 attempts. backoff a little
        # TODO: propertize these params
        :timer.sleep(max(100 * attempts, 1_000))
      end
      Logger.debug("socket disconnected. attempting to reconnect")
      {:reconnect, state}
    end
  end

  defmodule State do
    defstruct socket: nil,
              replies: %{},
              subs: %{},
              pending_subs: %{},
              sub_params: %{}

    def new(socket), do: %__MODULE__{socket: socket}

    def pop_reply(state = %__MODULE__{replies: replies}, id) do
      {addr, replies} = Map.pop(replies, id)
      {addr, %{state | replies: replies}}
    end

    def push_reply(state = %__MODULE__{replies: replies}, id, recipient) do
      replies = Map.put(replies, id, recipient)
      %{state | replies: replies}
    end

    def add_pending_sub(state = %__MODULE__{}, _req_id, nil, _params), do: state
    def add_pending_sub(state = %__MODULE__{pending_subs: pending_subs, sub_params: sub_params}, req_id, sub_pid, params) do
      %{state |
        pending_subs: Map.put(pending_subs, req_id, sub_pid),
        sub_params: Map.put(sub_params, req_id, params)
      }
    end

    def convert_pending_to_sub(state = %__MODULE__{pending_subs: p_subs, subs: subs, sub_params: sub_params}, req_id, sub_id) when is_binary(sub_id) do
      case Map.get(p_subs, req_id) do
        nil -> state
        sub_pid ->
          params = Map.get(sub_params, req_id)
          sub_params = Map.delete(sub_params, req_id)
          %{state |
            subs: Map.put(subs, sub_id, sub_pid),
            pending_subs: Map.delete(p_subs, req_id),
            sub_params: Map.put(sub_params, sub_id, params)
          }
      end
    end
    def convert_pending_to_sub(state = %__MODULE__{}, _req_id, _sub_id), do: state

    def get_sub(%__MODULE__{subs: subs}, sub_id), do: Map.get(subs, sub_id)

    # TODO: when the connection goes down, delete the process
    # TODO: store subscription ids by pid and remove them on disconnect?
    def remove_sub(state = %__MODULE__{subs: subs, sub_params: sub_params}, sub_id) do
      %{state | subs: Map.delete(subs, sub_id), sub_params: Map.delete(sub_params, sub_id)}
    end
  end

  def start_link(opts) do
    url = Keyword.get(opts, :url)
    GenServer.start_link(__MODULE__, [url])
  end

  def init([url]) do
    {:ok, socket} = Socket.start_link(url, self())
    {:ok, State.new(socket)}
  end

  def post(pid, request, sub_pid) do
    Logger.debug("sending request #{inspect(request)}")
    GenServer.call(pid, {:request, request, sub_pid}, @timeout)
  end

  def handle_call({:request, request, sub_pid}, from, state) do
    decoded = %{"id" => id} = Jason.decode!(request)
    :ok = Socket.send_request(state.socket, request)
    state = State.push_reply(state, id, from)

    state = case decoded do
      %{"method" => "eth_subscribe", "params" => params} ->
        # TODO: cleanup pending subs if they don't get processed in some amount of time to avoid potential memory leak
        # TODO: monitor the sub_pid and remove it's subscriptions if the process stops
        State.add_pending_sub(state, id, sub_pid, params)
      %{"method" => "eth_unsubscribe", "params" => [sub_id]} ->
        State.remove_sub(state, sub_id)
      _ -> state
    end

    Process.send_after(self(), {:timeout_reply, id}, @timeout)

    {:noreply, state}
  end

  def handle_info({:response, json_response}, state) do
    # TODO: error handling - if we let this crash we'll potentially lose a lot of responses...
    {:ok, response} = Jason.decode(json_response)
    case response do
      %{"method" => "eth_subscription"} ->
        # relay subscription message to subscribing process
        sub_id = State.get_sub(state, get_in(response, ["params", "subscription"]))
        Logger.debug("relaying subscription message to subscriber: #{inspect(sub_id)} #{json_response}")
        send(sub_id, {:eth_subscription, response})
        {:noreply, state}
      %{"id" => id, "result" => maybe_sub_id} ->
        # just a standard response or maybe an eth_subscribe response
        {addr, state} = State.pop_reply(state, id)
        if addr != nil do
          GenServer.reply(addr, {:ok, json_response})
        else
          # resub
          addr = Map.get(state.pending_subs, id)
          if addr != nil do
            # notify the subscriber about the resubscribe
            send(addr, {:resubscribe, response})
          end
        end
        {:noreply, State.convert_pending_to_sub(state, id, maybe_sub_id)}
    end
  end

  # if somehow reply addresses are accumulating, clear them out
  def handle_info({:timeout_reply, id}, state) do
    {addr, state} = State.pop_reply(state, id)

    if addr != nil do
      Logger.warn("timeout exceeded. giving up on reply for #{id} to #{inspect(addr)}")
    end

    {:noreply, state}
  end

  def handle_info(:socket_connected, state = %State{}) do
    # resubscribe all the existing subscriptions
    state = Enum.reduce(state.subs, state, fn {sub_id, sub_pid}, state ->
      params = Map.get(state.sub_params, sub_id)
      # TODO: finish implementing this

      req_id = "resub-#{sub_id}"
      request = %{"id" => req_id, "method" => "eth_subscribe", "params" => params}
      |> Jason.encode!()

      Socket.send_request(state.socket, request)

      state
        |> State.remove_sub(sub_id)
        |> State.add_pending_sub(req_id, sub_pid, params)
    end)

    {:noreply, state}
  end
end
