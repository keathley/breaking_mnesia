defmodule Mix.Tasks.Setup do
  use Mix.Task

  @shortdoc "Builds mnesia schema"
  def run(_) do
    BreakMnesia.DB.create_schema()
  end
end
