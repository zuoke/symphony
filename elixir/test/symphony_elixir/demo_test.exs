defmodule SymphonyElixir.DemoTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Demo, as: DemoTask
  alias SymphonyElixir.Demo

  test "run/1 completes the local demo flow deterministically" do
    demo_root = Path.join(System.tmp_dir!(), "symphony-demo-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(demo_root) end)

    assert {:ok, result} = Demo.run(demo_root: demo_root)

    assert result.demo_root == demo_root

    assert result.issue == %{
             id: "demo-issue-1",
             identifier: "DEMO-1",
             title: "Symphony local demo issue",
             final_state: "Done"
           }

    assert result.workspace.removed_after_completion
    refute File.exists?(result.workspace.observed_path)

    assert result.proof.file_name == "DEMO_PROOF.md"
    assert result.proof.preserved_path == Path.join(demo_root, "artifacts/DEMO_PROOF.md")
    assert result.proof.preserved_contents =~ "# Symphony Demo Proof"
    assert result.proof.preserved_contents =~ "issue=DEMO-1"
    assert File.read!(result.proof.preserved_path) == result.proof.preserved_contents

    assert result.tracker.comment_bodies == ["Symphony local demo completed.\nproof=DEMO_PROOF.md"]

    assert [
             %{type: "comment", issue_id: "demo-issue-1", body: "Symphony local demo completed.\nproof=DEMO_PROOF.md"},
             %{type: "state_update", issue_id: "demo-issue-1", state_name: "Done"}
           ] = result.tracker.events

    assert %{"counts" => %{"running" => 1}, "running" => [running_entry]} = result.running_snapshot
    assert running_entry["issue_identifier"] == "DEMO-1"
    assert running_entry["workspace_path"] == result.workspace.observed_path
    assert is_binary(running_entry["session_id"])
    assert running_entry["session_id"] != ""

    assert %{"counts" => %{"retrying" => 1}, "retrying" => [retry_entry]} = result.retry_snapshot
    assert retry_entry["issue_id"] == "demo-issue-1"

    assert %{"counts" => %{"running" => 0, "retrying" => 0}} = result.final_snapshot

    assert File.exists?(result.trace_path)
    trace = File.read!(result.trace_path)
    assert trace =~ "OUT:{\"method\":\"turn/completed\""
    assert trace =~ "OUT:{\"method\":\"turn/status\""

    assert File.exists?(Path.join(demo_root, "result.json"))
  end

  test "mix task uses the default demo root when no option is passed" do
    default_demo_root = Demo.default_demo_root()
    File.rm_rf(default_demo_root)

    on_exit(fn -> File.rm_rf(default_demo_root) end)

    output =
      capture_io(fn ->
        assert :ok = DemoTask.run([])
      end)

    assert output =~ "demo_root=#{default_demo_root}"
    assert output =~ "result_manifest=#{Path.join(default_demo_root, "result.json")}"
    assert File.exists?(Path.join(default_demo_root, "result.json"))
    assert File.exists?(Path.join(default_demo_root, "artifacts/DEMO_PROOF.md"))
  end
end
