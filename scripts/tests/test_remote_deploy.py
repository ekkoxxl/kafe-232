"""Security and protocol checks for the remote deployment client (no server changes)."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile

spec = importlib.util.spec_from_file_location("remote_deploy", Path(__file__).parents[1] / "remote-deploy.py")
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
SHA = "a" * 40


def good_run():
    return {"head_sha": SHA, "status": "completed", "conclusion": "success", "event": "push",
            "head_branch": "main", "repository": {"id": client.REPOSITORY_ID},
            "head_repository": {"id": client.REPOSITORY_ID}, "path": ".github/workflows/ci.yml",
            "workflow_id": 123}


class RunValidationTests(unittest.TestCase):
    def test_rejects_pr_fork_failure_stale_and_other_workflow(self):
        workflow = {"id": 123, "path": ".github/workflows/ci.yml", "state": "active"}
        self.assertEqual(client.validate_run(good_run(), workflow, SHA), SHA)
        mutations = {"event": "pull_request", "conclusion": "failure", "head_branch": "feature",
                     "head_repository": {"id": 42}, "repository": {"id": 42},
                     "workflow_id": 124, "path": ".github/workflows/other.yml"}
        for key, value in mutations.items():
            with self.subTest(key=key), self.assertRaises(client.DeploymentError):
                run = good_run()
                run[key] = value
                client.validate_run(run, workflow, SHA)
        with self.assertRaises(client.DeploymentError):
            client.validate_run(good_run(), workflow, "b" * 40)

    def test_ids_reject_injection_nonpositive_and_overflow(self):
        self.assertEqual(client.positive_id("12345678900", "ID"), 12345678900)
        for value in ("1;whoami", "0", "-1", "1.2", "9223372036854775808", True):
            with self.subTest(value=value), self.assertRaises(client.DeploymentError):
                client.positive_id(value, "ID")

    def test_rejects_duplicate_expired_unhashed_or_wrong_origin_artifacts(self):
        run_id = 12345678900
        artifact = {"id": 456, "name": f"kafe-web-{SHA}", "expired": False,
                    "size_in_bytes": 7, "digest": "sha256:" + "c" * 64,
                    "workflow_run": {"id": run_id, "repository_id": client.REPOSITORY_ID,
                                     "head_repository_id": client.REPOSITORY_ID,
                                     "head_branch": "main", "head_sha": SHA}}
        class API:
            def __init__(self, artifacts):
                self.artifacts = artifacts
            def json(self, suffix):
                if suffix == f"actions/runs/{run_id}":
                    return dict(good_run(), id=run_id)
                if suffix == "actions/workflows/ci.yml":
                    return {"id": 123, "path": ".github/workflows/ci.yml", "state": "active"}
                if suffix == "git/ref/heads/main":
                    return {"object": {"sha": SHA}}
                return {"artifacts": self.artifacts}
        self.assertEqual(client.validated_artifact(API([artifact]), run_id), (SHA, artifact))
        cases = [[artifact, artifact], [dict(artifact, expired=True)], [dict(artifact, digest=None)],
                 [dict(artifact, workflow_run=dict(artifact["workflow_run"], id=42))],
                 [dict(artifact, size_in_bytes=client.MAX_ARCHIVE_BYTES + 1)]]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(client.DeploymentError):
                client.validated_artifact(API(case), run_id)


class ArchiveValidationTests(unittest.TestCase):
    def test_original_bytes_hash_and_clean_manifest_are_required(self):
        manifest = {"schemaVersion": 1, "repository": client.REPOSITORY, "commitSha": SHA,
                    "targetFramework": "net481", "sourceDirty": False, "validationOnly": False}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact.zip"
            def write(data):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr("deployment-manifest.json", json.dumps(data))
                return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
            digest = write(manifest)
            client.validate_archive(path, SHA, digest)
            with self.assertRaises(client.DeploymentError):
                client.validate_archive(path, SHA, "sha256:" + "0" * 64)
            for key, value in (("sourceDirty", True), ("validationOnly", True), ("commitSha", "b" * 40)):
                invalid = dict(manifest, **{key: value})
                with self.subTest(key=key), self.assertRaises(client.DeploymentError):
                    client.validate_archive(path, SHA, write(invalid))


class DownloadTests(unittest.TestCase):
    def test_signed_download_never_receives_api_authorization(self):
        class Response(io.BytesIO):
            status = 200
        class Opener:
            def __init__(self):
                self.requests = []
            def open(self, request, timeout):
                self.requests.append(request)
                if len(self.requests) == 1:
                    raise urllib.error.HTTPError(request.full_url, 302, "Found",
                                                 {"Location": "https://storage.example/archive.zip?signature=private"}, None)
                return Response(b"zipdata")
        github = client.GitHub("sensitive-token")
        github.opener = Opener()
        with tempfile.TemporaryDirectory() as directory:
            github.download(123, Path(directory) / "artifact.zip", 7)
        api_request, download_request = github.opener.requests
        self.assertEqual(api_request.get_header("Authorization"), "Bearer sensitive-token")
        self.assertIsNone(download_request.get_header("Authorization"))


class SerializationTests(unittest.TestCase):
    def test_typed_large_ids_and_data_never_become_script_text(self):
        from pypsrp.serializer import Serializer
        captured = {}
        class Pipeline:
            had_errors = False
            streams = type("Streams", (), {"error": []})()
            def add_cmdlet(self, command):
                captured["command"] = command
                return self
            def add_parameters(self, parameters):
                captured["parameters"] = parameters
                return self
            def invoke(self):
                return [{"ok": True}]
        with patch("pypsrp.powershell.PowerShell", return_value=Pipeline()):
            client.invoke(object(), "Start-KafeUpload", CiRunId=12345678900,
                          ArtifactId=8765432100, ArchiveBytes=7, CommitSha=SHA)
        for key in ("CiRunId", "ArtifactId", "ArchiveBytes"):
            element = Serializer().serialize(captured["parameters"][key])
            self.assertEqual(element.tag, "I64")
        self.assertEqual(captured["command"], "Start-KafeUpload")
        self.assertEqual(captured["parameters"]["CommitSha"], SHA)


class UploadTests(unittest.TestCase):
    def test_bad_chunk_ack_prevents_publish(self):
        artifact = {"id": 456, "digest": "sha256:" + "c" * 64, "size_in_bytes": 7}
        calls = []
        def invoke(pool, command, **parameters):
            calls.append((command, parameters))
            if command == "Get-KafeDeploymentState":
                return {"ModuleVersion": "1.0.0"}
            if command == "Start-KafeUpload":
                return {"UploadId": "f" * 32, "ChunkBytes": client.CHUNK_BYTES,
                        "ArchiveBytes": 7, "CommitSha": SHA}
            return {"UploadId": "f" * 32, "NextIndex": 99, "ReceivedBytes": 7}
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "artifact.zip"
            archive.write_bytes(b"zipdata")
            with patch.object(client, "validated_artifact", return_value=(SHA, artifact)), \
                 patch.object(client, "invoke", side_effect=invoke), self.assertRaises(client.DeploymentError):
                client.publish(object(), object(), 123, SHA, artifact, archive)
        self.assertNotIn("Publish-KafeUpload", [command for command, _ in calls])
        chunk = calls[-1][1]
        self.assertEqual(chunk["Index"], 0)
        self.assertEqual(chunk["Base64Data"], "emlwZGF0YQ==")

    def test_main_change_after_upload_prevents_publish(self):
        artifact = {"id": 456, "digest": "sha256:" + "c" * 64, "size_in_bytes": 7}
        calls = []
        def invoke(pool, command, **parameters):
            calls.append(command)
            return {"Get-KafeDeploymentState": {"ModuleVersion": "1.0.0"},
                    "Start-KafeUpload": {"UploadId": "f" * 32, "ChunkBytes": client.CHUNK_BYTES,
                                         "ArchiveBytes": 7, "CommitSha": SHA},
                    "Send-KafeChunk": {"UploadId": "f" * 32, "NextIndex": 1, "ReceivedBytes": 7}}[command]
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "artifact.zip"
            archive.write_bytes(b"zipdata")
            with patch.object(client, "validated_artifact", side_effect=[(SHA, artifact), ("b" * 40, artifact)]), \
                 patch.object(client, "invoke", side_effect=invoke), self.assertRaises(client.DeploymentError):
                client.publish(object(), object(), 123, SHA, artifact, archive)
        self.assertNotIn("Publish-KafeUpload", calls)


if __name__ == "__main__":
    unittest.main()
