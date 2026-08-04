# Copyright 2017-2018 Amazon.com, Inc. and its affiliates. All Rights Reserved.
#
# Licensed under the MIT License. See the LICENSE accompanying this file
# for the specific language governing permissions and limitations under
# the License.
from unittest.mock import MagicMock

import efs_utils_common.proxy as proxy
from efs_utils_common.constants import (
    WATCHDOG_SERVICE,
    WATCHDOG_SERVICE_LEGACY_PLIST_PATH,
    WATCHDOG_SERVICE_PLIST_PATH,
)

from .. import utils

FS_ID = "fs-deadbeef"


def test_upstart_system(mocker):
    process_mock = MagicMock()
    process_mock.communicate.return_value = (
        "stop",
        "",
    )
    process_mock.returncode = 0
    popen_mock = mocker.patch("subprocess.Popen", return_value=process_mock)

    proxy.start_watchdog("init")

    assert 2 == popen_mock.call_count
    assert "/sbin/start" in popen_mock.call_args[0][0]


def test_systemd_system(mocker):
    call_mock = mocker.patch("subprocess.call", return_value=1)
    popen_mock = mocker.patch("subprocess.Popen")

    proxy.start_watchdog("systemd")

    utils.assert_called_once(call_mock)
    assert "systemctl" in call_mock.call_args[0][0]
    assert "is-active" in call_mock.call_args[0][0]
    utils.assert_called_once(popen_mock)
    assert "systemctl" in popen_mock.call_args[0][0]
    assert "start" in popen_mock.call_args[0][0]


def test_launchd_watchdog_already_running(mocker):
    """pgrep finds the watchdog running — no start attempted."""
    call_mock = mocker.patch("subprocess.call", return_value=0)
    popen_mock = mocker.patch("subprocess.Popen")

    proxy.start_watchdog("launchd")

    utils.assert_called_once(call_mock)
    assert "pgrep" in call_mock.call_args[0][0]
    assert "-f" in call_mock.call_args[0][0]
    assert WATCHDOG_SERVICE in call_mock.call_args[0][0]
    utils.assert_not_called(popen_mock)


def test_launchd_watchdog_not_running_plist_in_launchdaemons(mocker):
    """pgrep returns non-zero; plist exists in /Library/LaunchDaemons/."""
    call_mock = mocker.patch("subprocess.call", return_value=1)
    popen_mock = mocker.patch("subprocess.Popen")
    mocker.patch("os.path.exists", return_value=True)

    proxy.start_watchdog("launchd")

    utils.assert_called_once(call_mock)
    utils.assert_called_once(popen_mock)
    load_cmd = popen_mock.call_args[0][0]
    assert "sudo" in load_cmd
    assert "launchctl" in load_cmd
    assert "load" in load_cmd
    assert WATCHDOG_SERVICE_PLIST_PATH in load_cmd


def test_launchd_watchdog_not_running_fallback_to_legacy_path(mocker):
    """pgrep returns non-zero; plist missing from LaunchDaemons but present in LaunchAgents."""
    call_mock = mocker.patch("subprocess.call", return_value=1)
    popen_mock = mocker.patch("subprocess.Popen")

    def exists_side_effect(path):
        if path == WATCHDOG_SERVICE_PLIST_PATH:
            return False
        if path == WATCHDOG_SERVICE_LEGACY_PLIST_PATH:
            return True
        return False

    mocker.patch("os.path.exists", side_effect=exists_side_effect)

    proxy.start_watchdog("launchd")

    utils.assert_called_once(call_mock)
    utils.assert_called_once(popen_mock)
    load_cmd = popen_mock.call_args[0][0]
    assert "sudo" in load_cmd
    assert "launchctl" in load_cmd
    assert "load" in load_cmd
    assert WATCHDOG_SERVICE_LEGACY_PLIST_PATH in load_cmd


def test_launchd_watchdog_not_running_plist_missing_both_paths(mocker):
    """pgrep returns non-zero; plist missing from both paths — fatal error."""
    mocker.patch("subprocess.call", return_value=1)
    mocker.patch("subprocess.Popen")
    mocker.patch("os.path.exists", return_value=False)
    fatal_mock = mocker.patch("efs_utils_common.proxy.fatal_error")

    proxy.start_watchdog("launchd")

    utils.assert_called_once(fatal_mock)
    assert "plist" in fatal_mock.call_args[0][0].lower()
    assert "LaunchDaemons" in fatal_mock.call_args[0][0]


def test_unknown_system(mocker):
    popen_mock = mocker.patch("subprocess.Popen")

    proxy.start_watchdog("unknown")

    utils.assert_not_called(popen_mock)
