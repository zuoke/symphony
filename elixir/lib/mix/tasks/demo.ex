defmodule Mix.Tasks.Demo do
  use Mix.Task

  alias SymphonyElixir.Demo

  @moduledoc """
  Runs Symphony's fully local demo flow.

  Usage:

      mix demo
      mix demo --demo-root tmp/local_demo
  """
  @shortdoc "Run the fully local Symphony demo"
  @switches [demo_root: :string]

  @spec run([String.t()]) :: :ok
  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    run_opts =
      case opts[:demo_root] do
        nil -> []
        demo_root -> [demo_root: demo_root]
      end

    if invalid != [] do
      Mix.raise("Invalid option(s): #{inspect(invalid)}")
    end

    case Demo.run(run_opts) do
      {:ok, result} ->
        Mix.shell().info("demo_root=#{result.demo_root}")
        Mix.shell().info("observability_url=#{result.observability_url}")
        Mix.shell().info("result_manifest=#{Path.join(result.demo_root, "result.json")}")
        Mix.shell().info("preserved_proof=#{result.proof.preserved_path}")
        :ok

      {:error, reason} ->
        Mix.raise("demo failed: #{inspect(reason)}")
    end
  end
end
