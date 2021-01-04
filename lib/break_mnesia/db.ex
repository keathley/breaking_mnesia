defmodule BreakMnesia.DB do
  require Logger

  def get(tab, id) do
    tx = fn ->
      :mnesia.read({tab, id})
    end

    case :mnesia.transaction(tx) do
      {:atomic, [{_tab, ^id, val}]} -> val
      {:atomic, []} -> nil
      error ->
        Logger.error("Error in get: #{inspect(error)}")
        error
    end
  end

  def put(tab, id, val) do
    t = fn ->
      :mnesia.write({tab, id, val})
    end

    :mnesia.transaction(t)
  end
end
