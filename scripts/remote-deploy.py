"""Deploy an original GitHub CI artifact through the KafeDeploy JEA endpoint.

The trusted client never executes artifact content or constructs PowerShell code.
Only explicitly named JEA commands and serialized parameter values are sent.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "OrcunUcuncu/kafe-232"
REPOSITORY_ID = 1431509368
API_ROOT = "https://api.github.com"
HOST = "100.126.247.75"
PORT = 5986
MAX_ARCHIVE_BYTES = 50 * 1024 * 1024
CHUNK_BYTES = 196608
SHA40 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"sha256:([0-9a-f]{64})")
GUID_N = re.compile(r"[0-9a-fA-F]{32}")


class DeploymentError(Exception):
    """An error with a message safe for workflow logs."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise DeploymentError(message)


def positive_id(value: object, name: str) -> int:
    text = str(value)
    require(bool(re.fullmatch(r"[1-9][0-9]{0,18}", text)), f"Invalid {name}.")
    result = int(text)
    require(result <= 9223372036854775807, f"Invalid {name}.")
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, token: str):
        require(bool(token), "GH_TOKEN is required.")
        self.token = token
        # Explicitly isolate API Authorization from the signed archive request.
        self.opener = urllib.request.build_opener(NoRedirect())

    def _request(self, path: str) -> urllib.request.Request:
        require(path.startswith(f"/repos/{REPOSITORY}/"), "Unexpected GitHub API path.")
        return urllib.request.Request(
            API_ROOT + path,
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2026-03-10",
                "User-Agent": "kafe-demo-deployer",
            },
        )

    def json(self, suffix: str) -> dict:
        try:
            with self.opener.open(self._request(f"/repos/{REPOSITORY}/{suffix}"), timeout=45) as response:
                require(response.status == 200, "Unexpected GitHub API response.")
                return json.load(response)
        except (urllib.error.URLError, ValueError) as exc:
            raise DeploymentError("GitHub metadata request failed.") from exc

    def download(self, artifact_id: int, destination: Path, expected_bytes: int) -> None:
        request = self._request(f"/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip")
        try:
            self.opener.open(request, timeout=45).close()
            raise DeploymentError("GitHub archive endpoint did not redirect.")
        except urllib.error.HTTPError as response:
            require(response.code == 302, "GitHub archive request failed.")
            location = response.headers.get("Location", "")
            response.close()
        except urllib.error.URLError as exc:
            raise DeploymentError("GitHub archive request failed.") from exc
        parsed = urllib.parse.urlsplit(location)
        require(parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username
                and not parsed.password, "Unsafe archive redirect.")
        # No Authorization header, no redirects, and default public TLS validation.
        try:
            with self.opener.open(urllib.request.Request(location), timeout=60) as response, destination.open("xb") as output:
                require(response.status == 200, "Archive download failed.")
                received = 0
                while block := response.read(1024 * 1024):
                    received += len(block)
                    require(received <= MAX_ARCHIVE_BYTES and received <= expected_bytes,
                            "Archive exceeds the expected size.")
                    output.write(block)
                require(received == expected_bytes, "Archive size mismatch.")
        except urllib.error.URLError as exc:
            raise DeploymentError("Archive download failed.") from exc


def validate_run(run: dict, workflow: dict, main_sha: str) -> str:
    sha = run.get("head_sha", "")
    require(isinstance(sha, str) and SHA40.fullmatch(sha) is not None, "Invalid CI commit SHA.")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "CI run must have completed successfully.")
    require(run.get("event") == "push" and run.get("head_branch") == "main",
            "Only a main push CI run can deploy.")
    require(run.get("repository", {}).get("id") == REPOSITORY_ID
            and run.get("head_repository", {}).get("id") == REPOSITORY_ID,
            "CI repository identity mismatch.")
    require(run.get("path") == ".github/workflows/ci.yml"
            and workflow.get("path") == ".github/workflows/ci.yml"
            and workflow.get("id") == run.get("workflow_id")
            and workflow.get("state") == "active", "CI workflow identity mismatch.")
    require(sha == main_sha, "CI commit is stale; current main must pass CI before deployment.")
    return sha


def validated_artifact(github: GitHub, run_id: int) -> tuple[str, dict]:
    run = github.json(f"actions/runs/{run_id}")
    require(run.get("id") == run_id, "CI run identity mismatch.")
    workflow = github.json("actions/workflows/ci.yml")
    main = github.json("git/ref/heads/main")
    sha = validate_run(run, workflow, main.get("object", {}).get("sha", ""))
    matches = []
    for page in range(1, 11):
        response = github.json(f"actions/runs/{run_id}/artifacts?per_page=100&page={page}")
        artifacts = response.get("artifacts")
        require(isinstance(artifacts, list), "Invalid CI artifact response.")
        matches.extend(a for a in artifacts if a.get("name") == f"kafe-web-{sha}")
        if len(artifacts) < 100:
            break
    else:
        raise DeploymentError("Too many artifacts to validate safely.")
    require(len(matches) == 1, "Expected exactly one matching CI web artifact.")
    artifact = matches[0]
    positive_id(artifact.get("id"), "artifact ID")
    require(artifact.get("expired") is False, "CI artifact has expired.")
    size = artifact.get("size_in_bytes")
    require(type(size) is int and 0 < size <= MAX_ARCHIVE_BYTES, "Invalid CI archive size.")
    require(isinstance(artifact.get("digest"), str)
            and SHA256.fullmatch(artifact["digest"]) is not None, "CI artifact SHA256 digest is missing.")
    origin = artifact.get("workflow_run", {})
    require(origin.get("id") == run_id and origin.get("repository_id") == REPOSITORY_ID
            and origin.get("head_repository_id") == REPOSITORY_ID
            and origin.get("head_branch") == "main" and origin.get("head_sha") == sha,
            "Artifact provenance mismatch.")
    return sha, artifact


def validate_archive(path: Path, sha: str, digest: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    require("sha256:" + actual == digest, "Original CI ZIP SHA256 mismatch.")
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            require(names.count("deployment-manifest.json") == 1, "Missing or duplicate deployment manifest.")
            info = archive.getinfo("deployment-manifest.json")
            require(info.file_size <= 1024 * 1024, "Deployment manifest is too large.")
            manifest = json.loads(archive.read(info))
    except (zipfile.BadZipFile, ValueError, KeyError) as exc:
        raise DeploymentError("Invalid original CI ZIP or deployment manifest.") from exc
    require(manifest.get("schemaVersion") == 1 and manifest.get("repository") == REPOSITORY
            and manifest.get("commitSha") == sha and manifest.get("targetFramework") == "net481"
            and manifest.get("sourceDirty") is False and manifest.get("validationOnly") is False,
            "Package is not a deployable build of the expected commit.")


def object_properties(value: object) -> object:
    if isinstance(value, dict):
        return {key: object_properties(item) for key, item in value.items()}
    properties = {}
    for name in ("adapted_properties", "extended_properties"):
        properties.update(getattr(value, name, {}) or {})
    if properties:
        return {key: object_properties(item) for key, item in properties.items()}
    return value


def invoke(pool, command: str, **parameters) -> dict:
    from pypsrp.powershell import PowerShell
    from pypsrp.serializer import TaggedValue

    require(command in {"Get-KafeDeploymentState", "Start-KafeUpload", "Send-KafeChunk", "Publish-KafeUpload"},
            "Unexpected remote command.")
    # Python int is otherwise always serialized as PSRP Int32 by pypsrp.
    for name in ("CiRunId", "ArtifactId", "ArchiveBytes"):
        if name in parameters:
            parameters[name] = TaggedValue("I64", parameters[name])
    pipeline = PowerShell(pool)
    pipeline.add_cmdlet(command).add_parameters(parameters)
    result = pipeline.invoke()
    require(not pipeline.had_errors and not pipeline.streams.error, "Restricted deployment command failed.")
    require(len(result) == 1, "Unexpected restricted endpoint response.")
    data = object_properties(result[0])
    require(isinstance(data, dict), "Invalid restricted endpoint response.")
    return data


def publish(github: GitHub, pool, run_id: int, sha: str, artifact: dict, archive: Path) -> None:
    def recheck() -> None:
        current_sha, current_artifact = validated_artifact(github, run_id)
        require(current_sha == sha and current_artifact["id"] == artifact["id"]
                and current_artifact["digest"] == artifact["digest"]
                and current_artifact["size_in_bytes"] == artifact["size_in_bytes"],
                "Approved CI artifact changed before deployment.")

    state = invoke(pool, "Get-KafeDeploymentState")
    require(state.get("ModuleVersion") == "1.0.0", "Unsupported restricted endpoint version.")
    recheck()
    start = invoke(pool, "Start-KafeUpload", CommitSha=sha, CiRunId=run_id,
                   ArtifactId=artifact["id"], ArchiveSha256=artifact["digest"][7:],
                   ArchiveBytes=artifact["size_in_bytes"])
    upload_id = start.get("UploadId", "")
    require(isinstance(upload_id, str) and GUID_N.fullmatch(upload_id) is not None,
            "Invalid upload session identity.")
    require(start.get("ChunkBytes") == CHUNK_BYTES and start.get("CommitSha") == sha
            and start.get("ArchiveBytes") == artifact["size_in_bytes"], "Unexpected upload contract.")
    received = 0
    with archive.open("rb") as source:
        index = 0
        while block := source.read(CHUNK_BYTES):
            acknowledgment = invoke(pool, "Send-KafeChunk", UploadId=upload_id, Index=index,
                                    Base64Data=base64.b64encode(block).decode("ascii"))
            received += len(block)
            require(acknowledgment.get("UploadId") == upload_id
                    and acknowledgment.get("NextIndex") == index + 1
                    and acknowledgment.get("ReceivedBytes") == received, "Upload acknowledgment mismatch.")
            index += 1
    require(received == artifact["size_in_bytes"], "Upload size mismatch.")
    recheck()
    result = invoke(pool, "Publish-KafeUpload", UploadId=upload_id)
    require(result.get("Operation") == "Deploy" and result.get("CommitSha") == sha
            and result.get("Site") == "KafeDemo" and result.get("AuthenticatedHttp") == 200
            and result.get("AnonymousHttp") == 401 and result.get("DatabaseChanged") is False,
            "Deployment response did not confirm the required result.")
    print(f"Deployed {sha}; authenticated HTTP 200, anonymous HTTP 401; database unchanged.")


def main() -> None:
    from pypsrp.powershell import RunspacePool
    from pypsrp.wsman import WSMan

    require(os.environ.get("KAFE_DEPLOY_HOST") == HOST
            and os.environ.get("KAFE_DEPLOY_PORT") == str(PORT), "Unexpected deployment host or port.")
    username = os.environ.get("KAFE_DEPLOY_USER", "")
    password = os.environ.get("KAFE_DEPLOY_PASSWORD", "")
    require(bool(re.fullmatch(r"[^\\/\s]+\\kafepublisher", username, re.IGNORECASE))
            and bool(password), "Dedicated deployment credentials are required.")
    ca_pem = os.environ.get("KAFE_WINRM_CA_PEM", "")
    require("-----BEGIN CERTIFICATE-----" in ca_pem, "Trusted WinRM public certificate PEM is required.")
    run_id = positive_id(os.environ.get("CI_RUN_ID", ""), "CI run ID")
    github = GitHub(os.environ.get("GH_TOKEN", ""))
    sha, artifact = validated_artifact(github, run_id)
    with tempfile.TemporaryDirectory(prefix="kafe-deploy-") as directory:
        archive = Path(directory) / "original-ci-artifact.zip"
        ca_path = Path(directory) / "winrm-public-ca.pem"
        ca_path.write_text(ca_pem, encoding="ascii")
        ssl.create_default_context(cafile=str(ca_path))  # Fail before authentication for malformed trust material.
        github.download(artifact["id"], archive, artifact["size_in_bytes"])
        validate_archive(archive, sha, artifact["digest"])
        with WSMan(HOST, port=PORT, username=username, password=password, ssl=True,
                   auth="ntlm", cert_validation=str(ca_path), encryption="never", no_proxy=True,
                   connection_timeout=30, operation_timeout=60, read_timeout=90) as connection:
            with RunspacePool(connection, configuration_name="KafeDeploy") as pool:
                publish(github, pool, run_id, sha, artifact, archive)


if __name__ == "__main__":
    try:
        main()
    except DeploymentError as error:
        print(f"Deployment stopped: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Exceptions from TLS, NTLM or PSRP can contain request data. Keep logs sanitized.
        print("Deployment stopped: transport, TLS, authentication or endpoint failure. Check server audit logs.",
              file=sys.stderr)
        sys.exit(1)
