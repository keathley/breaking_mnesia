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

  # First things first, lets see what happens when we split away one of the
  # nodes from the rest of the cluster.
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
    :rpc.multicall(nodes, :mnesia, :wait_for_tables, [[:vals], 5_000])

    # Make sure we're connected and sending data.
    {:atomic, :ok} = DB.put(:vals, 1, 1)
    assert {[1, 1, 1, 1], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])

    # Split n3 from everyone else
    Schism.partition([n3])

    # issue an insert on a remote node that can't talk to n3
    {:atomic, :ok} = :rpc.call(n1, DB, :put, [:vals, 1, 2])

    # n2 should be able to see this
    assert :rpc.call(n2, DB, :get, [:vals, 1]) == 2

    # n3 can't see the update. It also returns a read still, which, while
    # wrong, isn't that unexpected. This does mean that any disconnected nodes
    # can issue stale reads though and is worth being aware of.
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 1

    # *Now* we have a problem. n3 just allowed us to overwrite the previous
    # data even though it can't communicate with the rest of the cluster.
    # When the cluster heals, we have to figure out whos' going to win.
    {:atomic, :ok} = :rpc.call(n3, DB, :put, [:vals, 1, 3])

    # The cluster is now in an inconsistent state. Mnesia will tell us this
    # and start throwing events. The only way to solve this now is to subscribe
    # to those events and solve this ourselves (a fairly non-trivial task).
    Schism.heal([n1, n2, n3])

    # n3 is still showing the old data (since Mnesia has no concept of who is "correct" at this point).
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 3

    :rpc.multicall(nodes, DB, :get, [:vals, 1])
    |> IO.inspect(label: "Results")

    eventually(fn ->
      assert :rpc.call(n2, DB, :get, [:vals, 1]) == 3
    end)
  end

  # Ok, so that didn't work. But we used a pretty naive setup. In order to
  # make our tables more robust we can use the "majority" option which will
  # force writes to only succeed if there is a majority of nodes available.
  # The node list is more or less determined by the nodes given to
  # disc_copies. Unfortunately, this doesn't really solve the problem either...
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

    # Make sure everything is connected
    {:atomic, :ok} = DB.put(:vals, 1, 1)
    assert {[1, 1, 1, 1], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])

    # Split n3 from everyone else
    Schism.partition([n3])

    # issue an insert on a remote node that can't talk to n3,
    {:atomic, :ok} = :rpc.call(n1, DB, :put, [:vals, 1, 2])

    # n2 should be able to see this
    assert :rpc.call(n2, DB, :get, [:vals, 1]) == 2

    # n3 can't see the update. Its also still issuing stale reads even though
    # it can't talk to a majority. Again, not that surprising. But it still
    # means that clients can see stale data and won't know that they're seeing
    # stale data. Its something to be aware.
    assert :rpc.call(n3, DB, :get, [:vals, 1]) == 1

    # This write to n3 will fail since it doesn't have a majority. This is now
    # working correctly. Serving stale reads isn't great, but its also not that
    # bad. Acting like we stored some state only to drop it in the future would
    # be *really* bad.
    {:aborted, _} = :rpc.call(n3, DB, :put, [:vals, 1, 3])
    Schism.heal([n1, n2, n3])

    # After a partition heals you might expect to see mnesia sync data. But,
    # alas, it does not. You'll still need to fix this manually, which means
    # figuring out which side of the split the node was on, figuring out which
    # keys may have been tainted, grabbing data from a "healthy" node, and
    # synchronizing it across the cluster. This is doable (I'm literally describing
    # how to do it). But its probably not something many people expect to have
    # to do.
    eventually(fn ->
      assert :rpc.call(n3, DB, :get, [:vals, 1]) == 2
    end)
  end

  # Ok, majority seems to have fixed things, lets see what happens if we mark
  # specific nodes as "leaders" (master in erlang terms). The idea being, if
  # there is an inconsistency somewhere, nodes can be brought up using the
  # leaders version of the table. As long as the leaders table is correct,
  # loading their table should be "safe". Lets see how it works...
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

    # Declare that n1 is the leader node.
    :rpc.multicall(nodes, :mnesia, :set_master_nodes, [:vals, [n1]])

    # Standard initialization to ensure everything is working.
    {:atomic, :ok} = DB.put(:vals, 1, 1)
    assert {[1, 1, 1, 1], []} = :rpc.multicall(nodes, DB, :get, [:vals, 1])

    # Lets see what happens if we split the leader away from the rest of the cluster.
    Schism.partition([n1])

    # New writes will fail since its no longer in a majority. Reads will still
    # suceed but we know that already.
    assert {:aborted, _} = :rpc.call(n1, DB, :put, [:vals, 1, 4])

    # While n1 is split away, lets issue some new writes to n2. Since n2 is still
    # part of the majority, the writes will succeed and be replicated to the
    # other nodes.
    assert {:atomic, :ok} = :rpc.call(n2, DB, :put, [:vals, 1, 5])
    eventually(fn ->
      assert :rpc.call(n3, DB, :get, [:vals, 1]) == 5
    end)

    # Now lets heal.
    Schism.heal([n1, n2, n3])

    # As before, n1 is now out of sync and has to be reconciled. But, lets see
    # what happens if we don't go through that process.
    # eventually(fn ->
    #   assert :rpc.call(n1, DB, :get, [:vals, 1]) == 5
    # end)

    # To simulate "reconciliation" with a leader we just need to stop and start
    # mnesia on one of the good nodes. Because we've marked another node as a
    # leader, it'll load from the leaders table.
    :rpc.call(n3, Application, :stop, [:mnesia])
    :rpc.call(n3, Application, :start, [:mnesia])
    :rpc.call(n3, :mnesia, :wait_for_tables, [[:vals], 5_000])

    # And...now we've dropped the writes from another node as well. Mnesia doesn't
    # know, nor care, that the write occured with a majority. We've told it that
    # n1 is the leader and the assumption is that the leader always has the
    # correct view of the world. Unfortunately, the only way to actually guarantee
    # that invariant is to redirect all writes to n1, thus creating a single
    # point of failure across the cluster, or by implementing concensus. I've
    # built concensus algorithms before. Thinking of making that work reliably
    # with mnesia makes my head spin a bit. Someone could do it, but its non-trivial.
    # Forcing a single point of failure isn't *that* bad in the big scheme of
    # things. After all, your single postgres instance is a single point of failure.
    # Keep in mind you'll need to figure out how you're going to deploy and scale
    # your application with this single writer pattern as well.
    #
    # My larger point isn't to say that Mnesia is bad or wrong or to say that
    # solving these problems is impossible. The point is that Mnesia isn't going
    # to solve these for you. *You* are going to have to figure out how to solve
    # them. They're non-trivial issues and will absolutely need to be considered.
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
