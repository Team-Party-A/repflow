import io
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from registry_guard import PACKAGE_URL, require_private


class RegistryGuardTests(unittest.TestCase):
    @patch.dict("os.environ", GH_TOKEN="unit-test-only")
    @patch("registry_guard.urlopen")
    def test_only_private_metadata_is_accepted(self, open_request):
        for visibility in ("private", "public", "internal", None):
            with self.subTest(visibility=visibility):
                open_request.return_value = io.BytesIO(
                    json.dumps({"visibility": visibility}).encode()
                )
                if visibility == "private":
                    require_private()
                else:
                    with self.assertRaises(RuntimeError):
                        require_private()

    @patch.dict("os.environ", GH_TOKEN="unit-test-only")
    @patch("registry_guard.urlopen")
    def test_missing_is_allowed_only_before_first_publish(self, open_request):
        open_request.side_effect = HTTPError(PACKAGE_URL, 404, "missing", {}, None)
        require_private(allow_missing=True)
        with self.assertRaises(RuntimeError):
            require_private()

    @patch.dict("os.environ", GH_TOKEN="unit-test-only")
    @patch("registry_guard.urlopen")
    def test_permission_and_network_errors_never_allow_publish(self, open_request):
        for failure in (
            HTTPError(PACKAGE_URL, 403, "denied", {}, None),
            URLError("unavailable"),
        ):
            with self.subTest(failure=type(failure).__name__):
                open_request.side_effect = failure
                with self.assertRaises(RuntimeError):
                    require_private(allow_missing=True)

    @patch.dict("os.environ", GH_TOKEN="unit-test-only")
    @patch("registry_guard.urlopen")
    def test_invalid_metadata_is_rejected(self, open_request):
        open_request.return_value = io.BytesIO(b"invalid-json")
        with self.assertRaises(RuntimeError):
            require_private(allow_missing=True)
