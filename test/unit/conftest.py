# Copyright 2022 The Sigstore Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import base64
import os
from collections import defaultdict
from io import BytesIO
from pathlib import Path
from typing import Iterator, Tuple

import pytest
from tuf.api.exceptions import DownloadHTTPError
from tuf.ngclient import FetcherInterface

from sigstore._internal import tuf
from sigstore._internal.rekor.client import RekorBundle
from sigstore.oidc import (
    AmbientCredentialError,
    GitHubOidcPermissionCredentialError,
    detect_credential,
)
from sigstore.verify import VerificationMaterials
from sigstore.verify.policy import VerificationSuccess

_ASSETS = (Path(__file__).parent / "assets").resolve()
assert _ASSETS.is_dir()

_TUF_ASSETS = (_ASSETS / "staging-tuf").resolve()
assert _TUF_ASSETS.is_dir()


def _is_ambient_env():
    try:
        token = detect_credential()
        if token is None:
            return False
    except GitHubOidcPermissionCredentialError:
        # On GitHub Actions, forks do not have access to OIDC identities.
        # We differentiate this case from other GitHub credential errors,
        # since it's a case where we want to skip (i.e. return False).
        if os.getenv("GITHUB_EVENT_NAME") == "pull_request":
            return False
        return True
    except AmbientCredentialError:
        # If ambient credential detection raises, then we *are* in an ambient
        # environment but one that's been configured incorrectly. We
        # pass this through, so that the CI fails appropriately rather than
        # silently skipping the faulty tests.
        return True

    return True


def pytest_addoption(parser):
    parser.addoption(
        "--skip-online",
        action="store_true",
        help="skip tests that require network connectivity",
    )


def pytest_runtest_setup(item):
    if "online" in item.keywords and item.config.getoption("--skip-online"):
        pytest.skip(
            "skipping test that requires network connectivity due to `--skip-online` flag"
        )
    elif "ambient_oidc" in item.keywords and not _is_ambient_env():
        pytest.skip("skipping test that requires an ambient OIDC credential")


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "online: mark test as requiring network connectivity"
    )
    config.addinivalue_line(
        "markers", "ambient_oidc: mark test as requiring an ambient OIDC identity"
    )


@pytest.fixture
def asset():
    def _asset(name: str) -> Path:
        return _ASSETS / name

    return _asset


@pytest.fixture
def tuf_asset():
    def _tuf_asset(name: str) -> Path:
        return _TUF_ASSETS / name

    return _tuf_asset


@pytest.fixture
def signing_materials():
    def _signing_materials(name: str) -> Tuple[bytes, bytes, bytes]:
        file = _ASSETS / name
        cert = _ASSETS / f"{name}.crt"
        sig = _ASSETS / f"{name}.sig"
        bundle = _ASSETS / f"{name}.rekor"

        entry = None
        if bundle.is_file():
            bundle = RekorBundle.parse_file(bundle)
            entry = bundle.to_entry()

        with file.open(mode="rb", buffering=0) as io:
            materials = VerificationMaterials(
                input_=io,
                cert_pem=cert.read_text(),
                signature=base64.b64decode(sig.read_text()),
                offline_rekor_entry=entry,
            )

        return materials

    return _signing_materials


@pytest.fixture
def null_policy():
    class NullPolicy:
        def verify(self, cert):
            return VerificationSuccess()

    return NullPolicy()


@pytest.fixture
def mock_staging_tuf(monkeypatch, tuf_dirs):
    """Mock that prevents tuf module from making requests: it returns staging
    assets from a local directory instead

    Return a tuple of dicts with the requested files and counts"""

    success = defaultdict(int)
    failure = defaultdict(int)

    class MockFetcher(FetcherInterface):
        def _fetch(self, url: str) -> Iterator[bytes]:
            filename = os.path.basename(url)
            filepath = _TUF_ASSETS / filename
            if filepath.is_file():
                success[filename] += 1
                return BytesIO(filepath.read_bytes())

            failure[filename] += 1
            raise DownloadHTTPError("File not found", 404)

    monkeypatch.setattr(tuf, "_get_fetcher", lambda: MockFetcher())

    return success, failure


@pytest.fixture
def tuf_dirs(monkeypatch, tmp_path):
    # Patch _get_dirs as well, to avoid polluting the user's actual cache
    # with test assets.
    data_dir = tmp_path / "data" / "tuf"
    cache_dir = tmp_path / "cache" / "tuf"
    monkeypatch.setattr(tuf, "_get_dirs", lambda u: (data_dir, cache_dir))

    return (data_dir, cache_dir)
