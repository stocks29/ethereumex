defmodule Ethereumex.WsClient do
  @moduledoc false

  require Logger

  use Ethereumex.Client.BaseClient
  alias Ethereumex.WsServer

  @timeout 60_000
  @spec post_request(binary(), []) :: {:ok | :error, any()}
  def post_request(payload, opts) do
    sub_pid = Keyword.get(opts, :subscriber)
    with {:ok, response} <- call_ws(payload, sub_pid),
         {:ok, decoded_body} <- Jason.decode(response) do
      case decoded_body do
        %{"error" => error} -> {:error, error}
        result = [%{} | _] -> {:ok, format_batch(result)}
        result -> {:ok, Map.get(result, "result")}
      end
    else
      {:error, %Jason.DecodeError{data: ""}} -> {:error, :empty_response}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, error}}
      {:error, error} -> {:error, error}
    end
  end

  # defp call_ws(payload) do
  #   :poolboy.transaction(:ws_worker, fn pid -> WsServer.post(pid, payload) end, @timeout)
  # end

  defp call_ws(payload, sub_pid) do
    # TODO: do we need to pool this? might cause issues with unsubscribe if not sticky
    :poolboy.transaction(:ws_worker, fn pid -> WsServer.post(pid, payload, sub_pid) end, @timeout)
  end

  def eth_subscribe(params, sub_pid, opts \\ []) when is_list(params) do
    # TODO: change params?
    opts = Keyword.put(opts, :subscriber, sub_pid)
    request("eth_subscribe", params, opts)
  end

  def eth_unsubscribe(sub_id, opts \\ []) do
    params = [sub_id]
    request("eth_unsubscribe", params, opts)
  end
end
