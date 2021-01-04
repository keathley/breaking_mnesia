defmodule BreakMnesia do
  alias __MODULE__.DB

  def insert(id) do
    DB.insert(id, id)
  end
  def insert(id, val) do
    DB.insert(id, val)
  end
end
