import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).parents[1]
HOST_INSTALLER = REPOSITORY_ROOT / "ct" / "ippontipp.sh"
CONTAINER_INSTALLER = REPOSITORY_ROOT / "install" / "ippontipp-install.sh"


def script_without_main(path: Path) -> str:
    script = path.read_text()
    main_call = 'main "$@"'
    if not script.rstrip().endswith(main_call):
        raise AssertionError(f"Unexpected installer entry point in {path}")
    return script.rstrip()[: -len(main_call)]


class HostInstallerTestCase(unittest.TestCase):
    def test_container_enables_nesting_for_systemd_services(self):
        harness = r'''
CTID=108
TEMPLATE_REF=local:vztmpl/debian-13.tar.zst
CORES=2
HOSTNAME=ippontipp-rc
MEMORY=3072
BRIDGE=vmbr0
IP_CONFIG=dhcp
GATEWAY=
ROOT_STORAGE=local-lvm
DISK=16

pct() {
  if [[ "$1" == "create" ]]; then
    printf 'CREATE_ARG=%s\n' "$@"
  else
    printf '192.0.2.10\n'
  fi
}

create_container
'''
        result = subprocess.run(
            ["bash", "-s"],
            input=script_without_main(HOST_INSTALLER) + harness,
            check=True,
            capture_output=True,
            text=True,
        )

        create_arguments = [
            line.removeprefix("CREATE_ARG=")
            for line in result.stdout.splitlines()
            if line.startswith("CREATE_ARG=")
        ]
        feature_index = create_arguments.index("--features")
        self.assertEqual(create_arguments[feature_index + 1], "nesting=1")


class ContainerInstallerTestCase(unittest.TestCase):
    def test_uses_locale_available_in_minimal_debian_template(self):
        script = CONTAINER_INSTALLER.read_text()

        self.assertIn("export LANG=C.UTF-8", script)
        self.assertIn("export LC_ALL=C.UTF-8", script)

    def test_required_service_failure_prints_diagnostics(self):
        script = CONTAINER_INSTALLER.read_text()

        self.assertIn('systemctl --no-pager --full status "$service"', script)
        self.assertIn('journalctl --no-pager -u "$service" -n 50', script)

    def test_initial_deployment_does_not_depend_on_sbin_path(self):
        script = CONTAINER_INSTALLER.read_text()

        self.assertIn('UPDATER_BIN="/usr/local/sbin/ippontipp-deploy"', script)
        self.assertIn('"$UPDATER_BIN" update', script)
        self.assertNotIn("\n  ippontipp-deploy update\n", script)

    def test_installs_headers_for_the_system_python_runtime(self):
        script = CONTAINER_INSTALLER.read_text()

        self.assertRegex(script, r"(?m)^    python3 \\$")
        self.assertRegex(script, r"(?m)^    python3-dev \\$")


if __name__ == "__main__":
    unittest.main()
