import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).parents[1]
DEPLOY_SCRIPT = REPOSITORY_ROOT / "bin" / "ippontipp-deploy"
SYSTEMD_DIRECTORY = REPOSITORY_ROOT / "runtime" / "systemd"


def script_without_main(path: Path) -> str:
    script = path.read_text()
    main_call = 'main "$@"'
    if not script.rstrip().endswith(main_call):
        raise AssertionError(f"Unexpected script entry point in {path}")
    return script.rstrip()[: -len(main_call)]


class ReleaseBuildTestCase(unittest.TestCase):
    def test_runtime_units_do_not_execute_relocated_console_scripts(self):
        expected_modules = {
            "ippontipp-web.service": "gunicorn",
            "ippontipp-worker.service": "celery",
            "ippontipp-beat.service": "celery",
        }

        for filename, module in expected_modules.items():
            with self.subTest(service=filename):
                unit = (SYSTEMD_DIRECTORY / filename).read_text()
                self.assertIn(
                    f"ExecStart=/opt/ippontipp/current/.venv/bin/python -m {module}",
                    unit,
                )

    def test_uv_environment_is_created_as_relocatable(self):
        self.assertIn("UV_VENV_RELOCATABLE=1", DEPLOY_SCRIPT.read_text())

    def test_build_uses_the_system_python_interpreter(self):
        script = DEPLOY_SCRIPT.read_text()
        self.assertIn("--python /usr/bin/python3", script)
        self.assertIn("--no-managed-python", script)
        self.assertIn("--no-python-downloads", script)

    def test_runtime_python_is_validated_as_the_service_user(self):
        script = DEPLOY_SCRIPT.read_text()
        self.assertIn("require_command runuser", script)
        self.assertIn(
            'runuser --user ippontipp -- "$release_path/.venv/bin/python"',
            script,
        )
        self.assertIn('validate_release_runtime "$staging"', script)

    def test_deployer_uses_a_deterministic_system_path(self):
        self.assertIn(
            'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"',
            DEPLOY_SCRIPT.read_text(),
        )

    def test_cleanup_removes_active_staging_directory(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            app_root = Path(temporary_directory) / "app"
            temporary_downloads = Path(temporary_directory) / "downloads"
            staging = app_root / "releases" / ".staging-release-123"
            temporary_downloads.mkdir(parents=True)
            staging.mkdir(parents=True)

            harness = rf'''
TEMP_DIR={temporary_downloads}
ACTIVE_STAGING_DIR={staging}
cleanup_temporary_files
[[ ! -e "$TEMP_DIR" ]]
[[ ! -e "$ACTIVE_STAGING_DIR" ]]
'''
            result = subprocess.run(
                ["bash", "-s"],
                input=script_without_main(DEPLOY_SCRIPT) + harness,
                capture_output=True,
                env={**os.environ, "IPPONTIPP_APP_ROOT": str(app_root)},
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_cached_release_is_rebuilt(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            app_root = Path(temporary_directory) / "app"
            cached_release = app_root / "releases" / "cached"
            cached_release.mkdir(parents=True)

            harness = r'''
RELEASE_SHA=cached

validate_release_runtime() {
  return 1
}

build_release() {
  [[ ! -e "$APP_ROOT/releases/$RELEASE_SHA" ]] || return 1
  mkdir -p "$APP_ROOT/releases/$RELEASE_SHA"
  touch "$APP_ROOT/releases/$RELEASE_SHA/rebuilt"
}

ensure_release_available
[[ -f "$APP_ROOT/releases/$RELEASE_SHA/rebuilt" ]]
'''
            result = subprocess.run(
                ["bash", "-s"],
                input=script_without_main(DEPLOY_SCRIPT) + harness,
                capture_output=True,
                env={**os.environ, "IPPONTIPP_APP_ROOT": str(app_root)},
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)

    def test_curl_configuration_does_not_change_the_callers_umask(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            harness = rf'''
TEMP_DIR={temporary_directory}
GITHUB_TOKEN=test_token
original_umask="$(umask)"
create_curl_config
[[ "$(umask)" == "$original_umask" ]]
'''
            result = subprocess.run(
                ["bash", "-s"],
                input=script_without_main(DEPLOY_SCRIPT) + harness,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)


class ReleaseActivationTestCase(unittest.TestCase):
    def create_release_fixture(self, temporary_directory):
        app_root = Path(temporary_directory) / "app"
        previous_release = app_root / "releases" / "previous"
        new_release = app_root / "releases" / "new"
        python_binary = new_release / ".venv" / "bin" / "python"
        previous_release.mkdir(parents=True)
        python_binary.parent.mkdir(parents=True)
        python_binary.write_text("#!/usr/bin/env bash\nexit 0\n")
        python_binary.chmod(0o755)
        (new_release / "manage.py").touch()
        (app_root / "current").symlink_to(previous_release)
        return app_root, previous_release

    def test_failed_service_restart_restores_previous_release(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            app_root, previous_release = self.create_release_fixture(
                temporary_directory
            )

            harness = r'''
RELEASE_SHA=new
RELEASE_TAG=releases/1.0.0
RELEASE_VERSION=1.0.0

systemctl() {
  if [[ "$1" == "restart" && "$2" == "ippontipp-web.service" ]] &&
     [[ "$(readlink -f "$APP_ROOT/current")" == "$APP_ROOT/releases/new" ]]; then
    return 1
  fi
  return 0
}

journalctl() {
  return 0
}

curl() {
  return 0
}

report_current_release() {
  printf 'CURRENT=%s\n' "$(readlink -f "$APP_ROOT/current" 2>/dev/null || true)"
}
trap report_current_release EXIT

activate_release
'''
            environment = {
                **os.environ,
                "IPPONTIPP_APP_ROOT": str(app_root),
            }
            result = subprocess.run(
                ["bash", "-s"],
                input=script_without_main(DEPLOY_SCRIPT) + harness,
                capture_output=True,
                env=environment,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"CURRENT={previous_release}", result.stdout)

    def test_inactive_worker_fails_runtime_check_and_restores_previous_release(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            app_root, previous_release = self.create_release_fixture(
                temporary_directory
            )

            harness = r'''
RELEASE_SHA=new
RELEASE_TAG=releases/1.0.0
RELEASE_VERSION=1.0.0

systemctl() {
  if [[ "$1" == "is-active" && "$3" == "ippontipp-worker.service" ]] &&
     [[ "$(readlink -f "$APP_ROOT/current")" == "$APP_ROOT/releases/new" ]]; then
    return 1
  fi
  if [[ "$1" == "--no-pager" ]]; then
    printf 'STATUS=%s\n' "${@: -1}" >&2
  fi
  return 0
}

journalctl() {
  printf 'JOURNAL=%s\n' "$3" >&2
  return 0
}

curl() {
  return 0
}

sleep() {
  return 0
}

report_current_release() {
  printf 'CURRENT=%s\n' "$(readlink -f "$APP_ROOT/current" 2>/dev/null || true)"
}
trap report_current_release EXIT

activate_release
'''
            result = subprocess.run(
                ["bash", "-s"],
                input=script_without_main(DEPLOY_SCRIPT) + harness,
                capture_output=True,
                env={**os.environ, "IPPONTIPP_APP_ROOT": str(app_root)},
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"CURRENT={previous_release}", result.stdout)
            self.assertIn("STATUS=ippontipp-worker.service", result.stderr)
            self.assertIn("JOURNAL=ippontipp-worker.service", result.stderr)

    def test_failed_first_activation_leaves_no_current_release(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            app_root = Path(temporary_directory) / "app"
            new_release = app_root / "releases" / "new"
            python_binary = new_release / ".venv" / "bin" / "python"
            python_binary.parent.mkdir(parents=True)
            python_binary.write_text("#!/usr/bin/env bash\nexit 0\n")
            python_binary.chmod(0o755)
            (new_release / "manage.py").touch()

            harness = r'''
RELEASE_SHA=new
RELEASE_TAG=releases/1.0.0
RELEASE_VERSION=1.0.0

systemctl() {
  if [[ "$1" == "restart" && "$2" == "ippontipp-web.service" ]] &&
     [[ -L "$APP_ROOT/current" ]]; then
    return 1
  fi
  return 0
}

journalctl() {
  return 0
}

report_current_release() {
  if [[ -e "$APP_ROOT/current" || -L "$APP_ROOT/current" ]]; then
    printf 'CURRENT=present\n'
  else
    printf 'CURRENT=missing\n'
  fi
}
trap report_current_release EXIT

activate_release
'''
            result = subprocess.run(
                ["bash", "-s"],
                input=script_without_main(DEPLOY_SCRIPT) + harness,
                capture_output=True,
                env={**os.environ, "IPPONTIPP_APP_ROOT": str(app_root)},
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("CURRENT=missing", result.stdout)
            self.assertIn("no release remains active", result.stderr)


if __name__ == "__main__":
    unittest.main()
