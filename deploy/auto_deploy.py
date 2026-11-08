"""swe 定时拉取 dev 的已发布镜像，并在外网验收失败时恢复旧版本。"""

import argparse
import fcntl
import hashlib
import http.client
import json
import logging
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

import github_poll
from github_poll import PollDeferred
from https_probe import TLSCheckError, probe
from image_cache import image_cached
from release_metrics import network_delta, snapshot_network, utc_now
from release_probe import COMMIT, DIGEST, status_of

REPOSITORY = "Team-Party-A/repflow"
IMAGE = "ghcr.io/team-party-a/repflow-api@"
WORKFLOW = ".github/workflows/backend.yml"
VERIFY_JOB = re.compile(r"Verify swe HTTPS \((sha256:[0-9a-f]{64})\)")
COMPOSE_FILES = (
    "compose.yaml",
    "compose.ghcr.yaml",
    "compose.tls.yaml",
    "compose.tls.ghcr.yaml",
)
logger = logging.getLogger(__name__)


class DeployError(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise DeployError(reason)


def atomic_write(path, content, mode=0o600):
    with tempfile.NamedTemporaryFile(
        dir=path.parent, mode="w", encoding="utf-8", delete=False
    ) as target:
        temporary = Path(target.name)
        try:
            os.fchmod(target.fileno(), mode)
            target.write(content)
            target.flush()
            os.fsync(target.fileno())
            temporary.replace(path)
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            temporary.unlink(missing_ok=True)


def api(path):
    state = Path.home() / ".local/state/repflow/auto-deploy/github-poll.json"
    return github_poll.get(path, state, atomic_write)


def record_metric(directory, request, event, **values):
    path = directory / f"metrics-{request['run_id']}-{request['attempt']}.json"
    try:
        data = json.loads(path.read_text()) if path.exists() else {}
        data[event] = {"timestamp": utc_now(), **values}
        atomic_write(path, json.dumps(data) + "\n")
    except (OSError, ValueError) as error:
        logger.warning("Release metrics unavailable: kind=%s", type(error).__name__)


def status_identity(request):
    return {key: request[key] for key in ("run_id", "attempt", "commit", "digest")}


def discover(after):
    # runs 和 jobs 各自做条件请求，runs 未变化不代表 jobs 也未变化。
    runs = api(
        "workflows/backend.yml/runs?branch=dev&event=push&status=in_progress&per_page=2"
    )
    for run in runs["workflow_runs"]:
        order = [run["run_number"], run["run_attempt"]]
        if order <= after or not (
            run["event"] == "push"
            and run["head_branch"] == "dev"
            and run["path"] == WORKFLOW
            and run["repository"]["full_name"] == REPOSITORY
            and run["head_repository"]["full_name"] == REPOSITORY
            and COMMIT.fullmatch(run["head_sha"])
        ):
            continue
        run_id, attempt = int(run["id"]), int(run["run_attempt"])
        for job in api(f"runs/{run_id}/attempts/{attempt}/jobs?per_page=100")["jobs"]:
            match = VERIFY_JOB.fullmatch(job["name"])
            if (
                match
                and job["status"] == "in_progress"
                and job["head_sha"] == run["head_sha"]
            ):
                return {
                    "order": order,
                    "run_id": run_id,
                    "attempt": attempt,
                    "job_id": int(job["id"]),
                    "commit": run["head_sha"],
                    "digest": match[1],
                }
    return None


def verification_result(request):
    job = api(f"jobs/{request['job_id']}")
    require(
        job["run_id"] == request["run_id"]
        and job["head_sha"] == request["commit"]
        and job["name"] == f"Verify swe HTTPS ({request['digest']})",
        "unexpected GitHub verification job",
    )
    if job["status"] == "in_progress":
        return None
    return job.get("conclusion") or job["status"]


class Stack:
    def __init__(self, repo, state, tls_state, tls_env):
        self.repo, self.state, self.tls_state = repo, state, tls_state
        self.docker = ["docker", "--context", "rootless"]
        self.compose = [
            *self.docker,
            "compose",
            "--env-file",
            "deploy/.env",
            "--env-file",
            str(tls_env),
            "-p",
            "repflow",
        ]
        for name in COMPOSE_FILES:
            self.compose.extend(["-f", f"deploy/{name}"])
        self.address = os.environ["PUBLIC_IP"]
        self.port = int(os.environ.get("HTTPS_PORT", "8080"))

    def run(
        self, arguments, *, image=None, input_file=None, output_file=None, timeout=90
    ):
        environment = dict(
            os.environ, TLS_NGINX_CONFIG=str(self.repo / "deploy/nginx.tls.conf")
        )
        if image is not None:
            environment["API_IMAGE"] = image
        with (self.state / "last-command.log").open("ab") as log:
            result = subprocess.run(
                arguments,
                cwd=self.repo,
                env=environment,
                stdin=input_file or subprocess.DEVNULL,
                stdout=output_file or subprocess.PIPE,
                stderr=log,
                timeout=timeout,
                check=True,
            )
        return result.stdout.decode().strip() if output_file is None else None

    def git(self, *args):
        return self.run(["git", *args])

    def compose_run(self, *args, **options):
        return self.run([*self.compose, *args], **options)

    def running(self):
        container = self.compose_run("ps", "-q", "api")
        fmt = '{{.Config.Image}} {{index .Config.Labels "org.opencontainers.image.revision"}} {{.State.Health.Status}}'
        image, revision, health = self.run(
            [*self.docker, "inspect", "-f", fmt, container]
        ).split()
        require(
            image.startswith(IMAGE) and DIGEST.fullmatch(image.removeprefix(IMAGE)),
            "running API is not digest-pinned",
        )
        require(
            COMMIT.fullmatch(revision) and health == "healthy",
            "running API identity or health is invalid",
        )
        return {
            "image": image,
            "commit": revision,
            "config": self.git("rev-parse", "HEAD"),
        }

    def verify(self, release):
        require(
            self.running() == release,
            "running API or configuration differs from the release",
        )
        for attempt in range(12):
            try:
                probe(self.address, self.port, connect_host="127.0.0.1")
                return
            except (OSError, ValueError, TLSCheckError, http.client.HTTPException):
                if attempt == 11:
                    raise DeployError("local HTTPS verification failed") from None
                time.sleep(1)

    def prepare(self, current, candidate, request):
        require(
            not self.git("status", "--porcelain", "--untracked-files=no"),
            "server checkout has tracked changes",
        )
        self.verify(current)
        self.git(
            "fetch",
            "--no-tags",
            f"https://github.com/{REPOSITORY}.git",
            "refs/heads/dev",
        )
        self.git("merge-base", "--is-ancestor", candidate["commit"], "FETCH_HEAD")
        self.git("merge-base", "--is-ancestor", current["commit"], candidate["commit"])
        self.git("merge-base", "--is-ancestor", current["config"], candidate["config"])
        require(
            not self.git(
                "diff",
                "--name-only",
                current["config"],
                candidate["config"],
                "--",
                *[f"deploy/{name}" for name in COMPOSE_FILES],
            ),
            "Compose changes require a reviewed manual deployment",
        )
        self.run([*self.docker, "image", "inspect", "-f", "{{.Id}}", current["image"]])
        started = time.monotonic()
        started_at = utc_now()
        before = snapshot_network()
        cached = False
        downloaded = False
        pull_attempted = False
        try:
            cached = image_cached(candidate["image"], candidate["commit"])
            if not cached:
                pull_attempted = True
                self.run([*self.docker, "pull", candidate["image"]], timeout=240)
            downloaded = True
        finally:
            after = snapshot_network()
            record_metric(
                self.state,
                request,
                "download",
                started_at=started_at,
                elapsed_seconds=round(time.monotonic() - started, 3),
                cache_hit=cached,
                pull_attempted=pull_attempted,
                completed=downloaded,
                network=network_delta(before, after),
            )
        revision = self.run(
            [
                *self.docker,
                "image",
                "inspect",
                "-f",
                '{{index .Config.Labels "org.opencontainers.image.revision"}}',
                candidate["image"],
            ]
        )
        require(
            revision == candidate["commit"],
            "published image revision differs from the GitHub release",
        )
        live_schema = self.compose_run(
            "exec",
            "-T",
            "db",
            "sh",
            "-ceu",
            'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT version_num FROM public.alembic_version"',
        )
        image_schema = self.compose_run(
            "run",
            "--rm",
            "--no-deps",
            "--pull",
            "never",
            "-T",
            "api",
            "alembic",
            "heads",
            image=candidate["image"],
        )
        require(
            re.fullmatch(r"[0-9A-Za-z_]+", live_schema)
            and image_schema == f"{live_schema} (head)",
            "schema change requires a reviewed manual migration",
        )
        backup = self.state / f"backup-{request['run_id']}-{request['attempt']}.dump"
        with backup.open("xb") as dump:
            self.compose_run(
                "exec",
                "-T",
                "db",
                "sh",
                "-ceu",
                'exec pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"',
                output_file=dump,
                timeout=180,
            )
            dump.flush()
            os.fsync(dump.fileno())
        with backup.open("rb") as dump:
            self.compose_run(
                "exec",
                "-T",
                "db",
                "pg_restore",
                "--exit-on-error",
                "--file=/dev/null",
                input_file=dump,
                timeout=180,
            )
            dump.seek(0)
            checksum = hashlib.file_digest(dump, "sha256").hexdigest()
        atomic_write(backup.with_suffix(".sha256"), f"{checksum}  {backup.name}\n")

    def activate(self, release, *, rollback=False):
        image = {"image": release["image"]}
        with (self.tls_state / "operation.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            changed = self.git(
                "diff",
                "--name-only",
                release["config"],
                "HEAD",
                "--",
                "deploy/nginx.tls.conf",
            )
            self.git("checkout", "--no-overwrite-ignore", "--detach", release["config"])
            self.compose_run("config", "--quiet", **image)
            validate = (
                "run",
                "--rm",
                "--no-deps",
                "--pull",
                "never",
                "-T",
                "nginx",
                "nginx",
                "-t",
            )
            if changed and not rollback:
                self.compose_run(*validate, **image)
            up = (
                "up",
                "-d",
                "--no-deps",
                "--no-build",
                "--pull",
                "never",
                "--wait",
                "--wait-timeout",
                "60",
            )
            self.compose_run(*up, "api", **image)
            if rollback:
                self.compose_run(*validate, **image)
            if changed or rollback:
                self.compose_run(*up, "--force-recreate", "nginx", **image)
            self.verify(release)
            atomic_write(self.state / "image.env", f"API_IMAGE={release['image']}\n")


class Deployment:
    def __init__(self, stack):
        self.stack = stack
        self.path = stack.state / "releases.json"
        self.state = json.loads(self.path.read_text()) if self.path.exists() else None

    def save(self):
        atomic_write(self.path, json.dumps(self.state) + "\n")

    def write_status(self, status):
        filename = f"deploy-{status['run_id']}-{status['attempt']}.json"
        path = self.stack.tls_state / "status" / filename
        content = json.dumps(status) + "\n"
        if not path.exists() or path.read_text() != content:
            atomic_write(path, content, mode=0o644)

    def publish(self, request, state):
        self.state["status"] = dict(status_identity(request), state=state)
        self.save()
        self.write_status(self.state["status"])
        record_metric(self.stack.state, request, state)
        logger.info(
            "Release %s attempt %s: %s", request["run_id"], request["attempt"], state
        )

    def initialize(self):
        require(self.state is None, "release state already exists")
        require(
            not self.stack.git("status", "--porcelain", "--untracked-files=no"),
            "server checkout has tracked changes",
        )
        current = self.stack.running()
        self.stack.verify(current)
        identity = {
            "run_id": 0,
            "attempt": 0,
            "commit": current["commit"],
            "digest": current["image"].removeprefix(IMAGE),
        }
        self.write_status(dict(identity, state="deployed"))
        require(
            status_of(
                self.stack.address, self.stack.port, identity, connect_host="127.0.0.1"
            )
            == "deployed",
            "install the reviewed deployment status route first",
        )
        atomic_write(self.stack.state / "image.env", f"API_IMAGE={current['image']}\n")
        self.state = {
            "current": current,
            "previous": None,
            "last": [0, 0],
            "pending": None,
            "status": None,
        }
        self.save()

    def finish(self, request, state):
        self.state["pending"] = None
        self.state["poll_after"] = time.time() + 120
        self.publish(request, state)

    def rollback(self, pending):
        if self.state["current"] == pending["release"]:
            self.finish(pending["request"], "failed")
            return
        pending["phase"] = "rollback"
        try:
            self.save()
        except OSError:
            logger.warning(
                "Could not save rollback progress; restoring the recorded release"
            )
        try:
            self.stack.activate(self.state["current"], rollback=True)
        except Exception:
            self.publish(pending["request"], "rollback_failed")
            raise DeployError(
                "rollback failed; will retry on the next timer run"
            ) from None
        self.finish(pending["request"], "rolled_back")

    def reconcile(self, pending):
        request = pending["request"]
        if pending["phase"] == "prepare":
            self.finish(request, "failed")
        elif pending["phase"] != "candidate" or time.time() >= pending["deadline"]:
            self.rollback(pending)
        else:
            result = verification_result(request)
            if result == "success":
                try:
                    self.stack.verify(pending["release"])
                except Exception:
                    self.rollback(pending)
                    raise
                if self.state["current"] != pending["release"]:
                    self.state["previous"] = self.state["current"]
                    self.state["current"] = pending["release"]
                self.finish(request, "deployed")
            elif result is not None:
                self.rollback(pending)

    def tick(self):
        try:
            self.poll()
        except PollDeferred as error:
            self.state["poll_after"] = error.until
            self.save()
            logger.info("GitHub polling deferred until %d", error.until)

    def poll(self):
        require(
            self.state is not None,
            "initialize deployment state before enabling the timer",
        )
        pending = self.state["pending"]
        if pending is not None:
            # 恢复和到期回退先执行，不依赖网络额度或下一次查询时间。
            recovery = (
                pending["phase"] != "candidate" or time.time() >= pending["deadline"]
            )
            if not recovery and time.time() < self.state.get("poll_after", 0):
                return
            self.reconcile(pending)
            if self.state["pending"] is not None and self.state["status"] is not None:
                pending["fast_polls"] = pending.get("fast_polls", 0) + 1
                interval = 30 if pending["fast_polls"] < 4 else 120
                self.state["poll_after"] = time.time() + interval
                self.save()
                self.write_status(self.state["status"])
            return
        if self.state["status"] is not None:
            self.write_status(self.state["status"])
        if time.time() < self.state.get("poll_after", 0):
            return
        self.state["poll_after"] = time.time() + 120
        self.save()
        request = discover(self.state["last"])
        if request is None:
            return
        record_metric(self.stack.state, request, "discovered")
        current = self.state["current"]
        candidate = {
            "commit": request["commit"],
            "config": request["commit"],
            "image": IMAGE + request["digest"],
        }
        pending = {
            "request": request,
            "release": candidate,
            "phase": "prepare",
            "deadline": time.time() + 22 * 60,
        }
        self.state.update(last=request["order"], pending=pending)
        self.save()
        if candidate == current:
            self.stack.verify(current)
            pending["phase"] = "candidate"
            self.state["poll_after"] = time.time() + 30
            self.publish(request, "candidate")
            return
        try:
            self.stack.prepare(current, candidate, request)
            require(
                verification_result(request) is None,
                "external verification ended before the switch",
            )
        except PollDeferred:
            self.finish(request, "failed")
            raise DeployError(
                "GitHub verification unavailable before cutover"
            ) from None
        except Exception:
            self.finish(request, "failed")
            raise
        pending["phase"] = "apply"
        self.save()
        try:
            self.stack.activate(candidate)
        except Exception:
            self.rollback(pending)
            raise
        pending["phase"] = "candidate"
        self.state["poll_after"] = time.time() + 30
        self.publish(request, "candidate")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initialize", action="store_true")
    arguments = parser.parse_args()
    os.umask(0o077)
    home = Path.home()
    state = home / ".local/state/repflow/auto-deploy"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    repo = home / "repflow"
    tls_state = Path(os.environ["TLS_STATE_DIR"]).expanduser().resolve()
    require(
        not tls_state.is_relative_to(repo.resolve()),
        "TLS state must be outside the checkout",
    )
    stack = Stack(repo, state, tls_state, home / ".config/repflow/tls.env")
    with (state / "deploy.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        deployment = Deployment(stack)
        if arguments.initialize:
            deployment.initialize()
        else:
            deployment.tick()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        main()
    except DeployError as error:
        logger.error("Deployment failed: %s", error)
        raise SystemExit(1) from None
    except Exception as error:
        logger.error(
            "Deployment failed: kind=%s; see the private command log",
            type(error).__name__,
        )
        raise SystemExit(1) from None
