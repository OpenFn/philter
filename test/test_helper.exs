ExUnit.start()

# Start a Finch pool for all tests
{:ok, _} = Finch.start_link(name: Weir.TestFinch)
Application.put_env(:weir, :finch_name, Weir.TestFinch)
