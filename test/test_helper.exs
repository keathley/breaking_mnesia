:ok = LocalCluster.start()

Application.ensure_all_started(:break_mnesia)

ExUnit.start()
