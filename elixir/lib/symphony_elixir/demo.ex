defmodule SymphonyElixir.Demo do
  @moduledoc """
  Runs a deterministic local Symphony demo against the in-memory tracker.
  """

  require Logger
  alias SymphonyElixir.{HttpServer, LogFile, Orchestrator, Tracker, Workflow}
  alias SymphonyElixir.Linear.Issue

  @artifact_proof_name "DEMO_PROOF.md"
  @completion_comment "Symphony local demo completed.\nproof=DEMO_PROOF.md"
  @default_demo_root "tmp/local_demo"
  @default_issue_id "demo-issue-1"
  @default_issue_identifier "DEMO-1"
  @default_observability_host "127.0.0.1"
  @default_port 0
  @default_timeout_ms 20_000
  @poll_interval_ms 50
  @proof_body """
  # Symphony Demo Proof

  issue=DEMO-1
  status=completed
  source=fake-codex-app-server
  """

  @type result :: map()

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    previous = capture_runtime_state()
    context = build_context(opts)

    stop_symphony()

    try do
      prepare_demo_root!(context)
      apply_demo_runtime!(context)

      with {:ok, _apps} <- Application.ensure_all_started(:symphony_elixir),
           {:ok, observability_url} <- wait_for_observability_url(context.deadline_ms),
           :ok <- log_demo_step("observability available at #{observability_url}"),
           {:ok, _refresh} <- request_refresh(),
           {:ok, running_snapshot} <-
             wait_for_snapshot(
               observability_url,
               context.deadline_ms,
               &running_snapshot_for_issue(&1, context.issue.identifier)
             ),
           :ok <- log_demo_step("observed running snapshot"),
           {:ok, workspace_path} <- workspace_path_from_snapshot(running_snapshot, context.issue.identifier),
           :ok <- wait_for_file(Path.join(workspace_path, @artifact_proof_name), context.deadline_ms),
           :ok <- log_demo_step("observed workspace proof at #{workspace_path}"),
           {:ok, retry_snapshot} <-
             wait_for_snapshot(
               observability_url,
               context.deadline_ms,
               &retry_snapshot_for_issue(&1, context.issue.id, context.issue.identifier)
             ),
           :ok <- log_demo_step("observed retry snapshot"),
           :ok <- Tracker.create_comment(context.issue.id, @completion_comment),
           {:ok, comment_event} <-
             wait_for_tracker_event(
               {:memory_tracker_comment, context.issue.id, @completion_comment},
               context.deadline_ms
             ),
           :ok <- log_demo_step("recorded tracker comment"),
           :ok <- Tracker.update_issue_state(context.issue.id, "Done"),
           {:ok, state_event} <-
             wait_for_tracker_event(
               {:memory_tracker_state_update, context.issue.id, "Done"},
               context.deadline_ms
             ),
           :ok <- log_demo_step("recorded tracker terminal state"),
           {:ok, _refresh} <- request_refresh(),
           {:ok, idle_snapshot} <-
             wait_for_snapshot(observability_url, context.deadline_ms, &idle_snapshot?/1),
           :ok <- wait_for_file(context.artifact_proof_path, context.deadline_ms) do
        log_demo_step("observed clean idle snapshot and preserved proof")

        result =
          build_result(
            context,
            observability_url,
            workspace_path,
            running_snapshot,
            retry_snapshot,
            idle_snapshot,
            [event_to_map(comment_event), event_to_map(state_event)]
          )

        File.write!(context.result_path, Jason.encode!(result, pretty: true) <> "\n")
        {:ok, result}
      end
    after
      stop_symphony()
      restore_runtime_state(previous)
    end
  end

  @spec default_demo_root() :: String.t()
  def default_demo_root do
    Path.expand(@default_demo_root, File.cwd!())
  end

  defp capture_runtime_state do
    %{
      app_running?: symphony_running?(),
      workflow_file_path: Application.get_env(:symphony_elixir, :workflow_file_path),
      log_file: Application.get_env(:symphony_elixir, :log_file),
      server_port_override: Application.get_env(:symphony_elixir, :server_port_override),
      memory_tracker_issues: Application.get_env(:symphony_elixir, :memory_tracker_issues),
      memory_tracker_recipient: Application.get_env(:symphony_elixir, :memory_tracker_recipient),
      memory_tracker_comments: Application.get_env(:symphony_elixir, :memory_tracker_comments),
      demo_trace_file: System.get_env("SYMPHONY_DEMO_TRACE_FILE"),
      demo_artifact_dir: System.get_env("SYMPHONY_DEMO_ARTIFACT_DIR"),
      demo_proof_text: System.get_env("SYMPHONY_DEMO_PROOF_TEXT"),
      demo_sleep_secs: System.get_env("SYMPHONY_DEMO_SLEEP_SECS")
    }
  end

  defp build_context(opts) do
    demo_root =
      opts
      |> Keyword.get(:demo_root)
      |> Kernel.||(default_demo_root())
      |> Path.expand()

    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    %{
      demo_root: demo_root,
      artifact_dir: Path.join(demo_root, "artifacts"),
      artifact_proof_path: Path.join(demo_root, "artifacts/#{@artifact_proof_name}"),
      fake_codex_path: Path.expand("../../priv/demo/fake_codex_app_server.sh", __DIR__),
      issue: demo_issue(),
      log_root: demo_root,
      result_path: Path.join(demo_root, "result.json"),
      trace_path: Path.join(demo_root, "artifacts/fake_codex.trace"),
      workflow_file: Path.join(demo_root, "WORKFLOW.demo.md"),
      workspace_root: Path.join(demo_root, "workspaces"),
      deadline_ms: System.monotonic_time(:millisecond) + timeout_ms
    }
  end

  defp demo_issue do
    %Issue{
      id: @default_issue_id,
      identifier: @default_issue_identifier,
      title: "Symphony local demo issue",
      description: "Drive one deterministic local orchestration run without external auth.",
      state: "Todo",
      url: "https://example.test/issues/#{@default_issue_identifier}",
      labels: ["demo"]
    }
  end

  defp prepare_demo_root!(context) do
    File.rm_rf!(context.demo_root)
    File.mkdir_p!(context.artifact_dir)
    File.mkdir_p!(context.workspace_root)
    File.write!(context.workflow_file, demo_workflow(context))
  end

  defp apply_demo_runtime!(context) do
    Workflow.set_workflow_file_path(context.workflow_file)
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(context.log_root))
    Application.put_env(:symphony_elixir, :server_port_override, @default_port)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [context.issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
    System.put_env("SYMPHONY_DEMO_ARTIFACT_DIR", context.artifact_dir)
    System.put_env("SYMPHONY_DEMO_PROOF_TEXT", @proof_body)
    System.put_env("SYMPHONY_DEMO_SLEEP_SECS", "0.5")
    System.put_env("SYMPHONY_DEMO_TRACE_FILE", context.trace_path)
  end

  defp demo_workflow(context) do
    """
    ---
    tracker:
      kind: "memory"
      active_states: ["Todo", "In Progress"]
      terminal_states: ["Done"]
    polling:
      interval_ms: 100
    workspace:
      root: #{yaml_string(context.workspace_root)}
    agent:
      max_concurrent_agents: 1
      max_turns: 1
      max_retry_backoff_ms: 1000
    codex:
      command: #{yaml_string("#{context.fake_codex_path} app-server")}
      approval_policy: "never"
      thread_sandbox: "workspace-write"
      turn_timeout_ms: 10000
      read_timeout_ms: 5000
      stall_timeout_ms: 10000
    hooks:
      timeout_ms: 10000
      after_create: |
        printf '%s\\n' '# Symphony local demo workspace' > README.md
      before_remove: |
        if [ -f DEMO_PROOF.md ]; then
          mkdir -p "$SYMPHONY_DEMO_ARTIFACT_DIR"
          cp DEMO_PROOF.md "$SYMPHONY_DEMO_ARTIFACT_DIR/DEMO_PROOF.md"
        fi
    observability:
      dashboard_enabled: false
      refresh_ms: 100
      render_interval_ms: 16
    server:
      port: 0
      host: "#{@default_observability_host}"
    ---
    You are running the Symphony local demo.
    Write `DEMO_PROOF.md`, then conclude the turn cleanly.
    """
  end

  defp yaml_string(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp symphony_running? do
    symphony_running(&Application.started_applications/0)
  end

  defp symphony_running(app_reader) when is_function(app_reader, 0) do
    app_reader.()
    |> Enum.any?(fn {app, _description, _version} -> app == :symphony_elixir end)
  rescue
    _error -> Process.whereis(SymphonyElixir.Supervisor) != nil
  catch
    :exit, _reason -> Process.whereis(SymphonyElixir.Supervisor) != nil
  end

  defp stop_symphony do
    :symphony_elixir
    |> Application.stop()
    |> normalize_stop_result()
  end

  defp wait_for_observability_url(deadline_ms) do
    wait_until(deadline_ms, fn ->
      HttpServer.bound_port()
      |> observability_url_for_bound_port()
    end)
  end

  defp request_refresh do
    Orchestrator.request_refresh()
    |> normalize_refresh_result()
  end

  defp wait_for_snapshot(observability_url, deadline_ms, matcher) when is_function(matcher, 1) do
    wait_until(deadline_ms, fn ->
      with {:ok, payload} <- fetch_state_snapshot(observability_url),
           true <- matcher.(payload) do
        {:ok, payload}
      else
        _ -> :retry
      end
    end)
  end

  defp fetch_state_snapshot(observability_url) do
    observability_url
    |> then(&Req.get(url: "#{&1}/api/v1/state"))
    |> normalize_snapshot_response()
  end

  defp running_snapshot_for_issue(%{"running" => running}, issue_identifier) when is_list(running),
    do: Enum.any?(running, &running_entry_matches?(&1, issue_identifier))

  defp running_snapshot_for_issue(_payload, _issue_identifier), do: false

  defp retry_snapshot_for_issue(%{"retrying" => retrying}, issue_id, issue_identifier)
       when is_list(retrying),
       do: Enum.any?(retrying, &retry_entry_matches?(&1, issue_id, issue_identifier))

  defp retry_snapshot_for_issue(_payload, _issue_id, _issue_identifier), do: false

  defp idle_snapshot?(%{"running" => running, "retrying" => retrying})
       when is_list(running) and is_list(retrying),
       do: running == [] and retrying == []

  defp idle_snapshot?(_payload), do: false

  defp workspace_path_from_snapshot(%{"running" => running}, issue_identifier) when is_list(running) do
    running
    |> Enum.find(&workspace_entry_matches?(&1, issue_identifier))
    |> workspace_path_result()
  end

  defp workspace_path_from_snapshot(_payload, _issue_identifier), do: {:error, :workspace_path_unavailable}

  defp snapshot_issue_identifier(entry) when is_map(entry) do
    Map.get(entry, "issue_identifier") ||
      Map.get(entry, :issue_identifier) ||
      Map.get(entry, "identifier") ||
      Map.get(entry, :identifier)
  end

  defp present_workspace_path?(entry) when is_map(entry) do
    case Map.get(entry, "workspace_path") || Map.get(entry, :workspace_path) do
      workspace_path when is_binary(workspace_path) -> workspace_path != ""
      _ -> false
    end
  end

  defp present_session_id?(entry) when is_map(entry) do
    case Map.get(entry, "session_id") || Map.get(entry, :session_id) do
      session_id when is_binary(session_id) -> session_id != ""
      _ -> false
    end
  end

  defp wait_for_file(path, deadline_ms) when is_binary(path) do
    wait_until(deadline_ms, fn ->
      if File.exists?(path), do: :ok, else: :retry
    end)
  end

  defp wait_for_tracker_event(expected, deadline_ms) do
    wait_until(deadline_ms, fn ->
      receive do
        ^expected -> {:ok, expected}
        _other -> :retry
      after
        0 -> :retry
      end
    end)
  end

  defp build_result(
         context,
         observability_url,
         workspace_path,
         running_snapshot,
         retry_snapshot,
         idle_snapshot,
         tracker_events
       ) do
    final_issue = memory_issue(context.issue.id)
    comments = memory_comments_for_issue(context.issue.id)

    %{
      demo_root: context.demo_root,
      workflow_file: context.workflow_file,
      issue: %{
        id: context.issue.id,
        identifier: context.issue.identifier,
        title: context.issue.title,
        final_state: final_issue && final_issue.state
      },
      observability_url: observability_url,
      running_snapshot: running_snapshot,
      retry_snapshot: retry_snapshot,
      final_snapshot: idle_snapshot,
      workspace: %{
        observed_path: workspace_path,
        removed_after_completion: not File.exists?(workspace_path)
      },
      proof: %{
        file_name: @artifact_proof_name,
        preserved_path: context.artifact_proof_path,
        preserved_contents: File.read!(context.artifact_proof_path)
      },
      tracker: %{
        comment_bodies: comments,
        events: tracker_events
      },
      trace_path: context.trace_path,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp memory_issue(issue_id) do
    :symphony_elixir
    |> Application.get_env(:memory_tracker_issues, [])
    |> Enum.find(&match?(%Issue{id: ^issue_id}, &1))
  end

  defp memory_comments_for_issue(issue_id) do
    :symphony_elixir
    |> Application.get_env(:memory_tracker_comments, %{})
    |> Map.get(issue_id, [])
  end

  defp event_to_map({:memory_tracker_comment, issue_id, body}) do
    %{type: "comment", issue_id: issue_id, body: body}
  end

  defp event_to_map({:memory_tracker_state_update, issue_id, state_name}) do
    %{type: "state_update", issue_id: issue_id, state_name: state_name}
  end

  defp wait_until(deadline_ms, fun) when is_integer(deadline_ms) and is_function(fun, 0) do
    result = fun.()

    cond do
      result == :retry and System.monotonic_time(:millisecond) < deadline_ms ->
        Process.sleep(@poll_interval_ms)
        wait_until(deadline_ms, fun)

      result == :retry ->
        {:error, :timeout}

      true ->
        result
    end
  end

  defp restore_runtime_state(previous) do
    restore_application_env(:workflow_file_path, previous.workflow_file_path)
    restore_application_env(:log_file, previous.log_file)
    restore_application_env(:server_port_override, previous.server_port_override)
    restore_application_env(:memory_tracker_issues, previous.memory_tracker_issues)
    restore_application_env(:memory_tracker_recipient, previous.memory_tracker_recipient)
    restore_application_env(:memory_tracker_comments, previous.memory_tracker_comments)
    restore_system_env("SYMPHONY_DEMO_TRACE_FILE", previous.demo_trace_file)
    restore_system_env("SYMPHONY_DEMO_ARTIFACT_DIR", previous.demo_artifact_dir)
    restore_system_env("SYMPHONY_DEMO_PROOF_TEXT", previous.demo_proof_text)
    restore_system_env("SYMPHONY_DEMO_SLEEP_SECS", previous.demo_sleep_secs)

    if previous.app_running? do
      Application.ensure_all_started(:symphony_elixir)

      if is_binary(previous.workflow_file_path) do
        Workflow.set_workflow_file_path(previous.workflow_file_path)
      end
    end
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp log_demo_step(message) when is_binary(message) do
    Logger.info("Local demo: #{message}")
    :ok
  end

  defp normalize_stop_result(:ok), do: :ok
  defp normalize_stop_result({:error, {:not_started, _app}}), do: :ok
  defp normalize_stop_result({:error, reason}), do: {:error, reason}

  defp observability_url_for_bound_port(port) when is_integer(port) and port > 0 do
    {:ok, "http://#{@default_observability_host}:#{port}"}
  end

  defp observability_url_for_bound_port(_port), do: :retry

  defp normalize_refresh_result(:unavailable), do: {:error, :orchestrator_unavailable}
  defp normalize_refresh_result(payload), do: {:ok, payload}

  defp normalize_snapshot_response({:ok, %{status: 200, body: %{} = body}}), do: {:ok, body}

  defp normalize_snapshot_response({:ok, %{status: status, body: body}}),
    do: {:error, {:unexpected_snapshot_status, status, body}}

  defp normalize_snapshot_response({:error, reason}), do: {:error, reason}

  defp running_entry_matches?(entry, issue_identifier) when is_map(entry),
    do: snapshot_issue_identifier(entry) == issue_identifier and present_session_id?(entry)

  defp running_entry_matches?(_entry, _issue_identifier), do: false

  defp retry_entry_matches?(entry, issue_id, issue_identifier) when is_map(entry),
    do: snapshot_issue_id(entry) == issue_id or snapshot_issue_identifier(entry) == issue_identifier

  defp retry_entry_matches?(_entry, _issue_id, _issue_identifier), do: false

  defp workspace_entry_matches?(entry, issue_identifier) when is_map(entry),
    do: snapshot_issue_identifier(entry) == issue_identifier and present_workspace_path?(entry)

  defp workspace_entry_matches?(_entry, _issue_identifier), do: false

  defp workspace_path_result(entry) when is_map(entry) do
    case Map.get(entry, "workspace_path") || Map.get(entry, :workspace_path) do
      workspace_path when is_binary(workspace_path) -> {:ok, workspace_path}
      _ -> {:error, :workspace_path_unavailable}
    end
  end

  defp workspace_path_result(_entry), do: {:error, :workspace_path_unavailable}

  defp snapshot_issue_id(entry) when is_map(entry) do
    Map.get(entry, "issue_id") || Map.get(entry, :issue_id)
  end
end
