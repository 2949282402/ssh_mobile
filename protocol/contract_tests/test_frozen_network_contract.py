"""Phase 0 characterization and final-gate checks for the frozen network v2 plan.

This suite deliberately stays outside Rust, Go, and Dart ownership packages. It
checks the committed wire fixtures and the evidence inventory, while the strict
runner delegates executable behavior to the owning Rust, Go, and Dart test
selectors.
"""

from __future__ import annotations

import unittest

try:
    from .frozen_contract_acceptance import FrozenContractAcceptanceMixin
    from .frozen_contract_compatibility import FrozenContractCompatibilityMixin
    from .frozen_contract_inventory import FrozenContractInventoryMixin
    from .frozen_contract_transport import FrozenContractTransportMixin
except ImportError:
    from frozen_contract_acceptance import FrozenContractAcceptanceMixin
    from frozen_contract_compatibility import FrozenContractCompatibilityMixin
    from frozen_contract_inventory import FrozenContractInventoryMixin
    from frozen_contract_transport import FrozenContractTransportMixin


class FrozenNetworkContractTest(
    FrozenContractInventoryMixin,
    FrozenContractTransportMixin,
    FrozenContractAcceptanceMixin,
    FrozenContractCompatibilityMixin,
    unittest.TestCase,
):
    pass


if __name__ == "__main__":
    unittest.main()
