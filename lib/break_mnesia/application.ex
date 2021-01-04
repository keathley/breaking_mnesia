defmodule BreakMnesia.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  alias BreakMnesia.DB

  use Application

  @impl true
  def start(_type, _args) do
    children = [
    ]

    opts = [strategy: :one_for_one, name: BreakMnesia.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
