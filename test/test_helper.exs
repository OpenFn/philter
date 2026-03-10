ExUnit.start()

# Start a Finch pool for all tests
{:ok, _} = Finch.start_link(name: Philter.TestFinch)
Application.put_env(:philter, :finch_name, Philter.TestFinch)
