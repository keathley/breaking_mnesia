# BreakMnesia

A lot of new elixir folks hear about this mnesia thing and wonder what its all
about. Its a database that's built directly into erlang. I mean, that sounds
dope as hell. How many runtimes come with a distributed database built into them?

Mnesia has a reputation. Depending on who you talk to its either completely unreliable,
completely weird, or completely fine. The truth, of course, is somewhere in the middle.
The main issue with Mnesia is how its marketed. People have certain expectations
when it comes to databases and unfortunately, mnesia tends to fail to meet those
expectations. If you treat Mnesia like its Postgres, you're going to have a bad time.

My general advice is to view Mnesia the same way you'd view single-instance Redis.
If you view it that way you won't be surprised when it does something "weird".

Where Mnesia starts to violate most people's expectations is when you start relying
multi-node tables. The purpose of this repo is to demonstrate the ways that Mnesia
will violate your expectations when using distribution.

## How I'm testing.

I'm using `local_cluster` to spin up multiple nodes. Once they're created, I create
the mnesia schema and tables and send commands across the cluster. In order to
induce failures I'm using [schism](https://github.com/keathley/schism) to simulate
partitions.

All of these tests are located in `test/break_mnesia_test.exs`. I've annotated
most of the tests with comments to try to explain each issue.

My tests aren't exhaustive. These are what I thought to try to see if
I could induce some failures or inconsistencies.

## What did we learn here?

Mnesia is really interesting and it certainly has its place. But if you're
going to rely on Mnesia to store any sort of critical data, you need to be
aware of the kinds of faults that you can see. If you don't work out how
you're going to handle these issues, you *will* lose data eventually. It's
better to solve that problem up front rather than wait to work out a
solution after its already happened.

Most importantly, Mnesia isn't really going to help you with any of this stuff.
*You* are going to need to figure out how to to handle each scenario.
