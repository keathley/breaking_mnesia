defmodule BreakMnesiaTest do
  use ExUnit.Case
  doctest BreakMnesia

  alias BreakMnesia.DB

  @dirs [
    "Mnesia.cluster1@127.0.0.1",
    "Mnesia.cluster2@127.0.0.1",
    "Mnesia.cluster3@127.0.0.1",
    "Mnesia.manager@127.0.0.1",
  ]

  setup do
    for dir <- @dirs do
      File.rm_rf(dir)
    end

    :ok
  end

  test "distributes data" do
    nodes = LocalCluster.start_nodes("cluster", 3)
    [n1, n2, n3] = nodes
    nodes = [Node.self() | nodes]

    assert Node.ping(n1) == :pong
    assert Node.ping(n2) == :pong
    assert Node.ping(n3) == :pong

    # Ensure mnesia is stopped before we create schemas everywhere
    :rpc.multicall(nodes, Application, :stop, [:mnesia])
    :mnesia.create_schema(nodes)
    :rpc.multicall(nodes, Application, :start, [:mnesia])
    :mnesia.create_table(:vals, [
      {:disc_copies, nodes},
      {:attributes, [
        :id,
        :val
      ]}
    ])
    :rpc.multicall(nodes, Application, :stop, [:mnesia])

    :rpc.multicall(nodes, Application, :start, [:mnesia])
    :rpc.multicall(nodes, :mnesia, :wait_for_tables, [[:vals], 5_000])
    {:atomic, :ok} = DB.put(:vals, 1, 1)
    assert {[1, 1, 1, 1], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])

    # Split n3 from everyone else
    Schism.partition([n3])

    # issue an insert on a remote node that can't talk to n3
    {:atomic, :ok} = :rpc.call(n1, DB, :put, [:vals, 1, 2])

    # n2 should be able to see this
    assert :rpc.call(n2, DB, :get, [:vals, 1]) == 2

    # n3 can't see the update
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 1

    {:atomic, :ok} = :rpc.call(n3, DB, :put, [:vals, 1, 3])
    Schism.heal([n1, n2, n3])
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 3

    :rpc.multicall(nodes, DB, :get, [:vals, 1])
    |> IO.inspect(label: "Results")

    # This doesn't actually work because mnesia hates you...
    eventually(fn ->
      assert :rpc.call(n2, DB, :get, [:vals, 1]) == 3
    end)
  end

  test "majority" do
    nodes = LocalCluster.start_nodes("cluster", 3)
    [n1, n2, n3] = nodes
    nodes = [Node.self() | nodes]

    assert Node.ping(n1) == :pong
    assert Node.ping(n2) == :pong
    assert Node.ping(n3) == :pong

    # Ensure mnesia is stopped before we create schemas everywhere
    :rpc.multicall(nodes, Application, :stop, [:mnesia])
    :mnesia.create_schema(nodes)
    :rpc.multicall(nodes, Application, :start, [:mnesia])
    :mnesia.create_table(:vals, [
      {:disc_copies, nodes},
      {:majority, true},
      {:attributes, [
        :id,
        :val
      ]}
    ])
    :rpc.multicall(nodes, :mnesia, :wait_for_tables, [[:vals], 5_000])
    {:atomic, :ok} = DB.put(:vals, 1, 1)
    assert {[1, 1, 1, 1], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])

    # Split n3 from everyone else
    Schism.partition([n3])

    # issue an insert on a remote node that can't talk to n3,
    {:atomic, :ok} = :rpc.call(n1, DB, :put, [:vals, 1, 2])

    # n2 should be able to see this
    assert :rpc.call(n2, DB, :get, [:vals, 1]) == 2

    # n3 can't see the update
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 1

    # This write to n3 will fail since it doesn't have a majority
    {:aborted, _} = :rpc.call(n3, DB, :put, [:vals, 1, 3])
    Schism.heal([n1, n2, n3])

    # After a partition heals we'd expect to see it sync...but it doesn't
    eventually(fn ->
      assert :rpc.call(n3, DB, :get, [:vals, 1]) == 2
    end)
  end

  test "majority with leader" do
    nodes = LocalCluster.start_nodes("cluster", 3)
    [n1, n2, n3] = nodes
    nodes = [Node.self() | nodes]

    assert Node.ping(n1) == :pong
    assert Node.ping(n2) == :pong
    assert Node.ping(n3) == :pong

    # Ensure mnesia is stopped before we create schemas everywhere
    :rpc.multicall(nodes, Application, :stop, [:mnesia])
    :mnesia.create_schema(nodes)
    :rpc.multicall(nodes, Application, :start, [:mnesia])
    :mnesia.create_table(:vals, [
      {:disc_copies, nodes},
      {:majority, true},
      {:attributes, [
        :id,
        :val
      ]}
    ])
    :rpc.multicall(nodes, :mnesia, :wait_for_tables, [[:vals], 5_000])

    # Declare that n1 is the master node.
    :rpc.multicall(nodes, :mnesia, :set_master_nodes, [:vals, [n1]])
    {:atomic, :ok} = DB.put(:vals, 1, 1)
    assert {[1, 1, 1, 1], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])

    # Split n3 from everyone else
    # Schism.partition([n3])

    # issue an insert on a remote node that can't talk to n3,
    # {:atomic, :ok} = :rpc.call(n1, DB, :put, [:vals, 1, 2])

    # # n2 should be able to see this
    # assert :rpc.call(n2, DB, :get, [:vals, 1]) == 2

    # # n3 can't see the update
    # assert :rpc.call(n3, DB, :get, [:vals, 1]) == 1

    # This write to n3 will fail since it doesn't have a majority
    # {:aborted, _} = :rpc.call(n3, DB, :put, [:vals, 1, 3])

    Schism.partition([n1])

    # This will fail because n1 is not in a majority
    assert {:aborted, _} = :rpc.call(n1, DB, :put, [:vals, 1, 4])

    # Allow n3 to rejoin majority
    # Schism.heal([n2, n3])
    # :pong = :rpc.call(n2, Node, :ping, [n3])
    :rpc.call(n2, Node, :list, [])
    |> IO.inspect(label: "Node list")

    # This will now succeed since n3 is in majority and will be distributed
    assert {:atomic, :ok} = :rpc.call(n2, DB, :put, [:vals, 1, 5])
    eventually(fn ->
      assert :rpc.call(n3, DB, :get, [:vals, 1]) == 5
    end)

    Schism.heal([n1, n2, n3])

    # After a partition heals we'd expect to see it sync...but it doesn't
    # eventually(fn ->
    #   assert :rpc.call(n1, DB, :get, [:vals, 1]) == 5
    # end)

    # What happens if we stop and start mnesia now?
    :rpc.call(n3, Application, :stop, [:mnesia])
    # :rpc.call(n3, :mnesia, :set_master_nodes, [:vals, [n1]])
    :rpc.call(n3, Application, :start, [:mnesia])
    :rpc.call(n3, :mnesia, :wait_for_tables, [[:vals], 5_000])

    assert {[5, 5, 5, 5], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 5
  end

  def setup_mnesia(nodes) do
    # Ensure mnesia is stopped before we create schemas everywhere
    :rpc.multicall(nodes, Application, :stop, [:mnesia])
    :mnesia.create_schema(nodes)
    :rpc.multicall(nodes, Application, :start, [:mnesia])
    :mnesia.create_table(:vals, [
      {:disc_copies, nodes},
      {:attributes, [
        :id,
        :val
      ]}
    ])
    :rpc.multicall(nodes, Application, :stop, [:mnesia])
  end

  defp eventually(f, attempts \\ 5)
  defp eventually(f, attempts) do
    f.()
  rescue
    e ->
      if attempts > 0 do
        :timer.sleep(20)
        eventually(f, attempts - 1)
      else
        reraise e, __STACKTRACE__
      end
  end
end
